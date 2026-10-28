import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_lifetime.dart';
import 'rpc_error.dart';

/// Backend-consumed frames are a software playhead. This snapshot does not
/// establish audible hardware position or a physical latency bound.
final class PcmOutputSnapshot {
  PcmOutputSnapshot.fromJson(Map<String, dynamic> value)
    : generation = _integer(value, 'generation', 1, 0x7fffffffffffffff),
      queuedFrames = _integer(value, 'queued_frames', 0, 76800),
      renderedFrames = _integer(
        value,
        'rendered_frames',
        0,
        0x7fffffffffffffff,
      ),
      underruns = _integer(value, 'underruns', 0, 0x7fffffffffffffff),
      startToken = _integer(value, 'start_token', 1, 0x7fffffffffffffff),
      ready = _boolean(value, 'ready'),
      paused = _boolean(value, 'paused'),
      stopped = _boolean(value, 'stopped'),
      buffering = _boolean(value, 'buffering'),
      error = _error(value['error']) {
    if (value['version'] != 1) {
      throw const FormatException('Invalid audio output metadata');
    }
  }
  final int generation, queuedFrames, renderedFrames, underruns, startToken;
  final bool ready, paused, stopped, buffering;
  final String? error;
  static String? _error(Object? value) {
    if (value == null) return null;
    if (value is! String || value.length > 256) {
      throw const FormatException('Invalid audio output error');
    }
    return value;
  }

  static int _integer(
    Map<String, dynamic> value,
    String key,
    int min,
    int max,
  ) {
    final number = value[key];
    if (number is! int || number < min || number > max) {
      throw const FormatException('Invalid bounded audio output counter');
    }
    return number;
  }

  static bool _boolean(Map<String, dynamic> value, String key) {
    final flag = value[key];
    if (flag is! bool) {
      throw const FormatException('Invalid audio output state');
    }
    return flag;
  }
}

/// An owned canonical 48kHz stereo PCM16 sink. The service retains unaccepted
/// PCM and tags every delivery with its seek generation. No audio file paths
/// or codec work enter this output API.
abstract interface class PcmPlaybackOutput {
  int get generation;
  PcmOutputSnapshot snapshot();
  int push(Int16List stereo, {required int generation});
  Future<void> pauseFlush(int nextGeneration);
  Future<void> resume();
  Future<void> close();
}

final class NativePcmOutput implements PcmPlaybackOutput {
  NativePcmOutput._(this.bindings, this._owner, this._generation)
    : _requestedGeneration = _generation;
  final NativeLibrary bindings;
  int _owner, _generation, _requestedGeneration;
  @override
  int get generation => _generation;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  var _pendingControls = 0;

  static Future<NativePcmOutput> start({
    required NativeLibrary bindings,
    required bool Function() current,
    int generation = 1,
    String target = '',
  }) async {
    if (generation <= 0 ||
        generation > 0x7fffffffffffffff ||
        target.length > 1024 ||
        target.runes.any((code) => code < 32 || code == 127)) {
      throw ArgumentError('Invalid audio output admission');
    }
    final library = bindings.library;
    const suite = [
      'fs_pcm_output_version',
      'fs_owned_pcm_output_create_async',
      'fs_owned_pcm_output_push',
      'fs_owned_pcm_output_poll',
      'fs_owned_pcm_output_pause_flush_async',
      'fs_owned_pcm_output_resume_async',
      'fs_pcm_output_finish_async',
      'fs_pcm_output_retire',
    ];
    if (suite.any((symbol) => !library.providesSymbol(symbol)) ||
        library.lookupFunction<Int32 Function(), int Function()>(
              'fs_pcm_output_version',
            )() !=
            1) {
      throw StateError(
        'Saved audio playback is unavailable in this installation',
      );
    }
    await bindings.prepareAdmission();
    if (!current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Audio playback cancelled');
    }
    bindings.lifetime.ensureAdmission();
    final options = jsonEncode({
      'version': 1,
      'generation': generation,
      'target': target,
    }).toNativeUtf8();
    late final NativePcmOutput output;
    try {
      final create = library
          .lookupFunction<
            Uint64 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('fs_owned_pcm_output_create_async');
      final owner = create(options);
      if (owner == 0) throw StateError('Audio output admission was refused');
      output = NativePcmOutput._(bindings, owner, generation);
    } finally {
      calloc.free(options);
    }
    Timer? cancellation;
    try {
      final first = output.snapshot();
      cancellation = Timer.periodic(const Duration(milliseconds: 20), (_) {
        if (!current()) output.close().ignore();
      });
      final status = await bindings.lifetime.observeOperation(first.startToken);
      if (!current() || output._closing != null) {
        throw RpcError(RpcErrorCode.cancelled, 'Audio playback cancelled');
      }
      final ready = output.snapshot();
      if (status != 1 ||
          !ready.ready ||
          !ready.paused ||
          ready.stopped ||
          ready.generation != generation ||
          ready.error != null) {
        throw StateError('Audio output could not be prepared');
      }
      return output;
    } catch (_) {
      await output.close();
      rethrow;
    } finally {
      cancellation?.cancel();
    }
  }

  @override
  PcmOutputSnapshot snapshot() {
    if (_owner == 0) throw StateError('Audio output is closed');
    final poll = bindings.library
        .lookupFunction<
          Pointer<Utf8> Function(Uint64),
          Pointer<Utf8> Function(int)
        >('fs_owned_pcm_output_poll');
    final free = bindings.library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fs_string_free');
    final text = poll(_owner);
    if (text == nullptr) throw StateError('Audio output metadata unavailable');
    try {
      final encoded = text.toDartString();
      if (encoded.length > 4096) {
        throw const FormatException('Oversized audio output metadata');
      }
      return PcmOutputSnapshot.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
    } finally {
      free(text);
    }
  }

  /// Returns accepted frames,0 full, or-2 stale/blocked. A negative result admits
  /// no prefix. Caller retains the tail; a stale generation must be discarded.
  @override
  int push(Int16List stereo, {required int generation}) {
    if (stereo.isEmpty || stereo.length.isOdd || stereo.length > 9600) {
      throw ArgumentError('Output needs1..4800 stereo PCM frames');
    }
    if (_closing != null ||
        _pendingControls != 0 ||
        generation != _generation) {
      return -2;
    }
    final samples = calloc<Int16>(stereo.length);
    try {
      samples.asTypedList(stereo.length).setAll(0, stereo);
      final push = bindings.library
          .lookupFunction<
            Int32 Function(Uint64, Uint64, Pointer<Int16>, Size),
            int Function(int, int, Pointer<Int16>, int)
          >('fs_owned_pcm_output_push');
      final result = push(_owner, generation, samples, stereo.length ~/ 2);
      if (result < -2 || result == -1 || result > stereo.length ~/ 2) {
        throw StateError('Audio output refused PCM');
      }
      return result;
    } finally {
      calloc.free(samples);
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    if (_closing != null) {
      return Future.error(StateError('Audio output is closing'));
    }
    _pendingControls++;
    final operation = _tail
        .then((_) => action())
        .whenComplete(() => _pendingControls--);
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<void> pauseFlush(int nextGeneration) {
    if (nextGeneration <= _requestedGeneration ||
        nextGeneration > 0x7fffffffffffffff) {
      return Future.error(ArgumentError('Audio seek generation must increase'));
    }
    _requestedGeneration = nextGeneration;
    return _enqueue(() async {
      if (_closing != null) throw StateError('Audio output is closing');
      final flush = bindings.library
          .lookupFunction<
            Uint64 Function(Uint64, Uint64),
            int Function(int, int)
          >('fs_owned_pcm_output_pause_flush_async');
      if (await bindings.lifetime.observeOperation(
            flush(_owner, nextGeneration),
          ) !=
          1) {
        throw StateError('Audio output flush failed');
      }
      final state = snapshot();
      if (state.generation != nextGeneration ||
          !state.paused ||
          state.error != null) {
        throw StateError('Audio output flush acknowledgement changed');
      }
      _generation = nextGeneration;
    });
  }

  @override
  Future<void> resume() => _enqueue(() async {
    if (_closing != null) throw StateError('Audio output is closing');
    final resume = bindings.library
        .lookupFunction<
          Uint64 Function(Uint64, Uint64),
          int Function(int, int)
        >('fs_owned_pcm_output_resume_async');
    if (await bindings.lifetime.observeOperation(resume(_owner, _generation)) !=
        1) {
      throw StateError('Audio output resume failed');
    }
    final state = snapshot();
    if (state.generation != _generation ||
        state.paused ||
        state.stopped ||
        state.error != null) {
      throw StateError('Audio output resume acknowledgement changed');
    }
  });

  @override
  Future<void> close() => _closing ??= () async {
    final finish = bindings.library
        .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
          'fs_pcm_output_finish_async',
        );
    try {
      if (await bindings.lifetime.observeOperation(finish(_owner)) != 1) {
        throw StateError('Audio output stop failed');
      }
    } finally {
      final retire = bindings.library
          .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
            'fs_pcm_output_retire',
          );
      await bindings.lifetime.observeRetirement(retire(_owner), _owner);
      _owner = 0;
      await _tail;
    }
  }();
}
