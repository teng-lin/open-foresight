import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'audio_models.dart';
import 'native_lifetime.dart';
import 'persistence/recording_media.dart';
import 'recording_capture.dart';
import 'rpc_error.dart';

/// Reconciles only DB-preallocated identities, after RecordingMedia acquired the
/// inherited-reader lock and verified independent database/generation binding.
/// Native recovery opens no devices and never scans/adopts arbitrary filenames.
final class RecordingRecovery {
  static Future<List<AudioChunk>> reconcileBatch({
    required NativeLibrary bindings,
    required RecordingMedia media,
    required List<AudioChunkPublication> publications,
    required bool Function() current,
  }) async {
    if (publications.isEmpty || publications.length > 64) {
      throw ArgumentError('Recovery batch must contain 1..64 authorities');
    }
    final first = publications.first;
    final ids = {for (final row in publications) row.id: row};
    final spans = {
      for (final row in publications)
        if (media.audio.span(row.spanId) case final span?) span.id: span,
    };
    if (ids.length != publications.length ||
        publications.any(
          (row) =>
              row.sessionId != first.sessionId ||
              row.source != first.source ||
              row.storageGeneration != first.storageGeneration ||
              media.audio.publication(row.id)?.publicationToken !=
                  row.publicationToken ||
              spans[row.spanId]?.sessionId != first.sessionId,
        )) {
      throw ArgumentError('Recovery authority changed or mixes owners');
    }
    final library = bindings.library;
    const symbols = [
      'fs_owned_recording_recover_start',
      'fs_owned_recording_recover_join_async',
      'fs_owned_capture_recording_poll',
    ];
    if (symbols.any((symbol) => !library.providesSymbol(symbol))) {
      throw StateError(
        'Recording recovery is unavailable in this installation',
      );
    }
    await bindings.prepareAdmission();
    if (!current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Recording recovery cancelled');
    }
    bindings.lifetime.ensureAdmission();
    final options = jsonEncode({
      'directory': media.sessionDirectory(first.sessionId),
      'session_id': first.sessionId,
      'generation': first.storageGeneration,
      'chunk_ids': [
        for (final row in publications)
          {'id': row.id, 'sequence': row.sequence},
      ],
    }).toNativeUtf8();
    int owner;
    try {
      final start = library
          .lookupFunction<
            Uint64 Function(Int32, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>)
          >('fs_owned_recording_recover_start');
      owner = start(first.source.index, options);
      if (owner == 0) {
        throw StateError('Recording recovery admission was refused');
      }
    } finally {
      calloc.free(options);
    }
    var acknowledged = false;
    Timer? cancellation;
    Future<int>? cancelling;
    try {
      final join = library
          .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
            'fs_owned_recording_recover_join_async',
          );
      final joined = bindings.lifetime.observeOperation(join(owner));
      cancellation = Timer.periodic(const Duration(milliseconds: 20), (_) {
        if (!current() && cancelling == null) {
          // The finish ABI cancels an existing recovery join; both paths
          // coalesce the same completion token in NativeLifetime.
          cancelling = bindings.lifetime.request(
            'fs_capture_finish_async',
            owner,
          );
          cancelling!.ignore();
        }
      });
      if (await joined != 1) throw StateError('Recording recovery join failed');
      acknowledged = true;
      cancellation.cancel();
      cancellation = null;
      await cancelling;
      final poll = library
          .lookupFunction<
            Pointer<Utf8> Function(Uint64),
            Pointer<Utf8> Function(int)
          >('fs_owned_capture_recording_poll');
      final free = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('fs_string_free');
      final seen = <String>{}, recovered = <AudioChunk>[];
      for (var pass = 0; pass < 3; pass++) {
        final text = poll(owner);
        if (text == nullptr) {
          throw StateError('Recording recovery metadata unavailable');
        }
        late final Map<String, dynamic> snapshot;
        try {
          final encoded = text.toDartString();
          if (encoded.length > 65536) {
            throw const FormatException('Oversized recovery metadata');
          }
          snapshot = jsonDecode(encoded) as Map<String, dynamic>;
        } finally {
          free(text);
        }
        final raw = snapshot['chunks'];
        if (snapshot['version'] != 1 ||
            snapshot['session_id'] != first.sessionId ||
            snapshot['generation'] != first.storageGeneration ||
            snapshot['source'] != first.source.index ||
            snapshot['capture_active'] != false ||
            snapshot['state'] != 'sealed' ||
            snapshot['error'] != null ||
            raw is! List ||
            raw.length > 64 ||
            snapshot['ready_chunks'] is! int ||
            (snapshot['ready_chunks'] as int) < 0) {
          throw StateError('Recording recovery failed or changed ownership');
        }
        if (!current()) {
          throw RpcError(
            RpcErrorCode.cancelled,
            'Recording recovery cancelled',
          );
        }
        for (final item in raw) {
          final notice = RecordingChunkNotice.fromJson(
            item as Map<String, dynamic>,
          );
          final authority = ids[notice.chunkId];
          if (authority == null ||
              !seen.add(notice.chunkId) ||
              notice.sessionId != first.sessionId ||
              notice.generation != first.storageGeneration ||
              notice.source != first.source ||
              notice.sequence != authority.sequence ||
              notice.span != spans[authority.spanId]!.ordinal ||
              !notice.contentsSynced ||
              !notice.directorySynced) {
            throw const FormatException(
              'Recovered audio does not match durable authority',
            );
          }
          recovered.add(await media.publish(notice));
          if (!current()) {
            throw RpcError(
              RpcErrorCode.cancelled,
              'Recording recovery cancelled',
            );
          }
        }
        if (raw.isEmpty && snapshot['ready_chunks'] == 0) return recovered;
      }
      throw StateError('Recording recovery notices did not drain');
    } finally {
      cancellation?.cancel();
      try {
        if (!acknowledged) {
          await bindings.lifetime.request('fs_capture_finish_async', owner);
        }
      } finally {
        await bindings.lifetime.retire('fs_capture_retire', owner);
      }
    }
  }
}
