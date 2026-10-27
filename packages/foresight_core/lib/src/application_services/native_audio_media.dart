import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_lifetime.dart';
import '../rpc_error.dart';

/// Internal installation identities, supplied by the service's verified,
/// post-signing receipt. This type never accepts RPC-selected executables.
final class AudioMediaExecutable {
  AudioMediaExecutable({
    required this.path,
    required this.sha256,
    required this.buildId,
    required this.macosCdHash,
  }) {
    if (!path.startsWith('/') ||
        path.contains('\u0000') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(buildId) ||
        (macosCdHash.isNotEmpty &&
            !RegExp(r'^[0-9a-f]{40,64}$').hasMatch(macosCdHash))) {
      throw ArgumentError('Invalid installed media worker identity');
    }
  }
  final String path, sha256, buildId, macosCdHash;
}

enum AudioMediaOperation {
  encodeOpus('encode-opus'),
  encodeRecordingWav('encode-recording-wav-v1'),
  decodePcm('decode-pcm'),
  mixExportMp3('mix-export-mp3'),
  assembleMp3('assemble-mp3-v1'),
  assembleOpus('assemble-opus-v1'),
  assemblePcm('assemble-pcm-v1');

  const AudioMediaOperation(this.wire);
  final String wire;
  bool get assembly => index >= 4;
  bool get pcm => this == decodePcm || this == assemblePcm;
}

final class AudioMediaRequest {
  AudioMediaRequest({
    required this.operation,
    required this.sessionId,
    required this.jobId,
    required this.epoch,
    required this.inputSha256,
    this.secondInputSha256 = '',
    required this.sourceFrames,
    this.startFrame = 0,
    this.frameCount = 0,
  }) {
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    final sha = RegExp(r'^[0-9a-f]{64}$');
    if (!uuid.hasMatch(sessionId) ||
        !uuid.hasMatch(jobId) ||
        epoch < 0 ||
        epoch > 0x7fffffffffffffff ||
        !sha.hasMatch(inputSha256) ||
        (operation == AudioMediaOperation.mixExportMp3
            ? !sha.hasMatch(secondInputSha256)
            : secondInputSha256.isNotEmpty) ||
        sourceFrames <= 0 ||
        sourceFrames >
            (operation == AudioMediaOperation.mixExportMp3 || operation.assembly
                ? 48000 * 86400
                : 240000) ||
        (operation.pcm
            ? startFrame < 0 ||
                  frameCount <= 0 ||
                  frameCount > 240000 ||
                  startFrame + frameCount > sourceFrames
            : startFrame != 0 || frameCount != 0)) {
      throw ArgumentError('Invalid fixed media request');
    }
  }
  final AudioMediaOperation operation;
  final String sessionId, jobId, inputSha256, secondInputSha256;
  final int epoch, sourceFrames, startFrame, frameCount;
}

final class AudioMediaResult {
  AudioMediaResult._(
    this.outputSha256,
    this.outputBytes,
    this.frames,
    this.preSkip,
    this.finalGranule,
  );
  final String outputSha256;
  final int outputBytes, frames, preSkip, finalGranule;
}

/// A worker may ask only for positions in its frozen manifest, never paths.
final class AudioMediaInputRequest {
  AudioMediaInputRequest.fromJson(Map<String, dynamic> value)
    : sequence = value['sequence'] as int,
      manifestSha256 = value['manifest_sha256'] as String,
      indices = List<int>.unmodifiable((value['indices'] as List).cast<int>()) {
    if (value.length != 4 ||
        value['version'] != 1 ||
        sequence < 1 ||
        sequence > 0xffffffff ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(manifestSha256) ||
        indices.isEmpty ||
        indices.length > 2 ||
        indices.toSet().length != indices.length ||
        indices.any((i) => i < 0 || i >= 131072)) {
      throw const FormatException('Invalid audio input page');
    }
  }
  final int sequence;
  final String manifestSha256;
  final List<int> indices;
}

/// Borrowed protected read-only descriptors, valid until [close] is called.
/// Reply duplicates them synchronously; the actual transform lease stays live
/// through native retirement even after these temporary copies close.
final class AudioMediaInputPage {
  AudioMediaInputPage(this.descriptors, this.close);
  final List<int> descriptors;
  final void Function() close;
}

typedef AudioMediaInputProvider =
    AudioMediaInputPage Function(AudioMediaInputRequest request);

/// stderr is retained for explicit local diagnostics, never automatically
/// logged or included in a client-visible message.
final class AudioMediaFailure implements Exception {
  AudioMediaFailure(this.status, this.reason, this.stderr);
  final String status, reason, stderr;
  @override
  String toString() => 'Audio media worker failed: $status';
}

/// A fixed native media task. result success does not authorize publication
/// until closed acknowledges actual native retirement. SQL/file reader leases
/// remain with the scheduler through that fence, including cancellation.
final class NativeAudioMediaTask {
  NativeAudioMediaTask._(
    this.bindings,
    this.request,
    this.executable,
    this._owner,
    this._inputs,
  ) {
    _result.future.ignore();
    _closed.future.ignore();
    _run().ignore();
  }
  final NativeLibrary bindings;
  final AudioMediaRequest request;
  final AudioMediaExecutable executable;
  int _owner;
  final AudioMediaInputProvider? _inputs;
  int _lastInputSequence = 0;
  final _result = Completer<AudioMediaResult>();
  final _closed = Completer<void>();
  Future<AudioMediaResult> get result => _result.future;
  Future<void> get closed => _closed.future;

  /// Borrowed descriptors must remain open until this factory settles. Native
  /// start duplicates them synchronously; after success callers may close their
  /// copies. No file paths or executable identity come from desktop arguments.
  static Future<NativeAudioMediaTask> start({
    required NativeLibrary bindings,
    required AudioMediaExecutable executable,
    required AudioMediaRequest request,
    required int inputDescriptor,
    int secondInputDescriptor = -1,
    required int outputDescriptor,
    required int ownerLockDescriptor,
    required bool Function() current,
    AudioMediaInputProvider? inputs,
    Duration total = const Duration(seconds: 30),
    Duration idle = const Duration(seconds: 15),
    Duration terminateGrace = const Duration(seconds: 1),
    Duration killGrace = const Duration(seconds: 1),
  }) async {
    if (request.operation.assembly != (inputs != null) ||
        (request.operation == AudioMediaOperation.mixExportMp3) !=
            (secondInputDescriptor >= 0) ||
        inputDescriptor < 0 ||
        outputDescriptor < 0 ||
        ownerLockDescriptor < 0 ||
        total.inMilliseconds < 10 ||
        total.inMilliseconds > 86400000 ||
        idle.inMilliseconds < 10 ||
        idle.inMilliseconds > total.inMilliseconds ||
        terminateGrace.inMilliseconds < 1 ||
        terminateGrace.inMilliseconds > 5000 ||
        killGrace.inMilliseconds <= 0 ||
        killGrace.inMilliseconds > 5000) {
      throw ArgumentError('Invalid media capabilities or execution limits');
    }
    const required = [
      'fs_owned_media_start',
      'fs_owned_media_poll',
      'fs_owned_media_cancel',
      'fs_owned_media_progress',
      'fs_media_join_async',
      'fs_media_retire',
    ];
    if (required.any((symbol) => !bindings.library.providesSymbol(symbol))) {
      throw StateError(
        'Saved audio processing is unavailable in this installation',
      );
    }
    if (inputs != null &&
        [
          'fs_owned_media_input_poll',
          'fs_owned_media_input_reply',
        ].any((symbol) => !bindings.library.providesSymbol(symbol))) {
      throw StateError(
        'Saved audio assembly is unavailable in this installation',
      );
    }
    await bindings.prepareAdmission();
    if (!current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Audio processing cancelled');
    }
    bindings.lifetime.ensureAdmission();
    final options = jsonEncode({
      'version': 1,
      'executable': executable.path,
      'executable_sha256': executable.sha256,
      'build_id': executable.buildId,
      'macos_cdhash': executable.macosCdHash,
      'session_id': request.sessionId,
      'job_id': request.jobId,
      'epoch': request.epoch,
      'input_sha256': request.inputSha256,
      'second_input_sha256': request.secondInputSha256,
      'source_frames': request.sourceFrames,
      'start_frame': request.startFrame,
      'frame_count': request.frameCount,
      'total_ms': total.inMilliseconds,
      'idle_ms': idle.inMilliseconds,
      'terminate_grace_ms': terminateGrace.inMilliseconds,
      'kill_grace_ms': killGrace.inMilliseconds,
    }).toNativeUtf8();
    try {
      final start = bindings.library
          .lookupFunction<
            Uint64 Function(Int32, Int32, Int32, Int32, Int32, Pointer<Utf8>),
            int Function(int, int, int, int, int, Pointer<Utf8>)
          >('fs_owned_media_start');
      final owner = start(
        request.operation.index,
        inputDescriptor,
        secondInputDescriptor,
        outputDescriptor,
        ownerLockDescriptor,
        options,
      );
      if (owner == 0) throw StateError('Native media admission was refused');
      return NativeAudioMediaTask._(
        bindings,
        request,
        executable,
        owner,
        inputs,
      );
    } finally {
      calloc.free(options);
    }
  }

  void cancel() => _control('fs_owned_media_cancel');
  void progress() => _control('fs_owned_media_progress');
  void _control(String symbol) {
    if (_owner == 0) return;
    final function = bindings.library
        .lookupFunction<Int32 Function(Uint64), int Function(int)>(symbol);
    if (function(_owner) != 0) throw StateError('Native media control refused');
  }

  Future<void> _run() async {
    await Future<void>.value();
    Object? failure;
    StackTrace? stack;
    var retired = false;
    try {
      final poll = bindings.library
          .lookupFunction<
            Pointer<Utf8> Function(Uint64),
            Pointer<Utf8> Function(int)
          >('fs_owned_media_poll');
      final free = bindings.library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('fs_string_free');
      late final Map<String, dynamic> snapshot;
      while (true) {
        _serveInputs();
        final text = poll(_owner);
        if (text == nullptr) {
          throw StateError('Native media status unavailable');
        }
        late final Map<String, dynamic> value;
        try {
          final json = text.toDartString();
          if (json.length > 32768) {
            throw const FormatException('Oversized media status');
          }
          value = jsonDecode(json) as Map<String, dynamic>;
        } finally {
          free(text);
        }
        if (value['version'] != 1 ||
            value['closed'] is! bool ||
            !const [
              'queued',
              'running',
              'finished',
              'unconfirmed',
            ].contains(value['state'])) {
          throw const FormatException('Invalid media status');
        }
        if (value['state'] == 'finished' || value['state'] == 'unconfirmed') {
          snapshot = value;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // The poll's closed bit is evidence, but the native operation token is
      // the authority for actual process/descriptor cleanup.
      final join = bindings.library
          .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
            'fs_media_join_async',
          );
      final joinToken = join(_owner);
      if (await bindings.lifetime.observeOperation(joinToken) != 1) {
        throw StateError('Native media join failed');
      }
      if (snapshot['status'] != 'success' || snapshot['closed'] != true) {
        throw AudioMediaFailure(
          snapshot['status'] as String? ?? 'protocol_failed',
          snapshot['reason'] as String? ?? '',
          snapshot['stderr'] as String? ?? '',
        );
      }
      final value = snapshot['worker_result'] as Map<String, dynamic>;
      final frames = request.operation.pcm
          ? request.frameCount
          : request.sourceFrames;
      final encoded =
          request.operation == AudioMediaOperation.encodeOpus ||
          request.operation == AudioMediaOperation.encodeRecordingWav ||
          request.operation == AudioMediaOperation.assembleOpus;
      if (value['protocol'] != 1 ||
          value['build_id'] != executable.buildId ||
          value['session'] != request.sessionId ||
          value['job'] != request.jobId ||
          value['epoch'] != request.epoch ||
          value['operation'] != request.operation.wire ||
          value['input_sha256'] != request.inputSha256 ||
          value['second_input_sha256'] != request.secondInputSha256 ||
          value['frames'] != frames ||
          value['source_frames'] != request.sourceFrames ||
          value['range_start'] != request.startFrame ||
          value['output_sha256'] is! String ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(value['output_sha256'] as String) ||
          value['output_bytes'] is! int ||
          (value['output_bytes'] as int) <= 0 ||
          value['pre_skip'] is! int ||
          value['final_granule'] is! int ||
          (encoded
              ? (value['pre_skip'] as int) < 0 ||
                    (value['pre_skip'] as int) > 65535 ||
                    value['final_granule'] !=
                        frames + (value['pre_skip'] as int)
              : value['pre_skip'] != 0 || value['final_granule'] != 0) ||
          (request.operation.pcm && value['output_bytes'] != frames * 2)) {
        throw const FormatException('Mismatched media artifact ownership');
      }
      _result.complete(
        AudioMediaResult._(
          value['output_sha256'] as String,
          value['output_bytes'] as int,
          frames,
          value['pre_skip'] as int,
          value['final_granule'] as int,
        ),
      );
    } catch (error, trace) {
      failure = error;
      stack = trace;
      try {
        cancel();
      } catch (_) {
        // Preserve the initiating failure; retirement remains the exit fence.
      }
      if (!_result.isCompleted) _result.completeError(error, trace);
    } finally {
      try {
        final retire = bindings.library
            .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
              'fs_media_retire',
            );
        await bindings.lifetime.observeRetirement(retire(_owner), _owner);
        _owner = 0;
        retired = true;
      } catch (error, trace) {
        failure = error;
        stack = trace;
      }
      if (retired) {
        _closed.complete();
      } else {
        _closed.completeError(failure!, stack);
      }
    }
  }

  void _serveInputs() {
    final provider = _inputs;
    if (provider == null) return;
    final library = bindings.library;
    final poll = library
        .lookupFunction<
          Pointer<Utf8> Function(Uint64),
          Pointer<Utf8> Function(int)
        >('fs_owned_media_input_poll');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fs_string_free');
    final text = poll(_owner);
    if (text == nullptr) return;
    late final AudioMediaInputRequest input;
    try {
      final encoded = text.toDartString();
      if (encoded.length > 1024) {
        throw const FormatException('Oversized audio input request');
      }
      input = AudioMediaInputRequest.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      if (input.manifestSha256 != request.inputSha256 ||
          input.sequence <= _lastInputSequence) {
        throw const FormatException('Audio input page authority changed');
      }
    } finally {
      free(text);
    }
    _lastInputSequence = input.sequence;
    final reply = library
        .lookupFunction<
          Int32 Function(Uint64, Uint64, Int32, Int32, Int32),
          int Function(int, int, int, int, int)
        >('fs_owned_media_input_reply');
    AudioMediaInputPage? page;
    try {
      page = provider(input);
      if (page.descriptors.length != input.indices.length ||
          page.descriptors.any((fd) => fd < 0)) {
        throw StateError('Audio input provider returned invalid descriptors');
      }
      if (reply(
            _owner,
            input.sequence,
            0,
            page.descriptors.first,
            page.descriptors.length == 2 ? page.descriptors[1] : -1,
          ) !=
          0) {
        throw StateError('Audio input page was refused');
      }
    } catch (_) {
      reply(_owner, input.sequence, 1, -1, -1);
      rethrow;
    } finally {
      page?.close();
    }
  }
}
