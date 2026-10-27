import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../native_lifetime.dart';
import '../platform_services.dart';
import '../read_models.dart';
import '../rpc_error.dart';
import '../runtime_execution_policy.dart';
import 'audio_recognition_scheduler.dart';
import 'native_audio_recognition.dart';

/// A service-owned reference keeps the shared native Whisper engine alive
/// between saved-audio jobs. close() must acknowledge native retirement.
abstract interface class AudioSpeechCacheOwner {
  Future<void> close();
}

typedef CreateAudioSpeechCache =
    Future<AudioSpeechCacheOwner> Function(
      String runtime,
      String path,
      bool Function() current,
    );

/// Verifies the exact frozen weights before first use and retains one native
/// engine reference across jobs. Configuration/clear first suspend the ASR
/// scheduler, then suspend this owner; only then may they replace model files.
/// A timed-out or lost job lease cannot silently permit model replacement.
final class AudioSpeechModels {
  AudioSpeechModels({
    required ModelRegistration? Function() registration,
    required CreateAudioSpeechCache createCache,
    RuntimeConfiguration? configuration,
  }) : _registration = registration,
       _createCache = createCache,
       _configuration = configuration?.snapshot();

  factory AudioSpeechModels.native({
    required ModelRegistration? Function() registration,
    required NativeLibrary bindings,
    RuntimeConfiguration? configuration,
  }) => AudioSpeechModels(
    registration: registration,
    createCache: (runtime, path, current) =>
        _NativeSpeechCache.open(bindings, runtime, path, current),
    configuration: configuration,
  );

  final ModelRegistration? Function() _registration;
  final CreateAudioSpeechCache _createCache;
  final RuntimeConfiguration? _configuration;
  _VerifiedSpeechCache? _cache;
  Future<_VerifiedSpeechCache>? _opening;
  Future<void>? _suspending;
  Completer<void>? _drained;
  var _leases = 0, _epoch = 0;
  bool _suspended = false, _closed = false, _unconfirmed = false;
  bool get suspended => _suspended;
  bool get restartRequired => _unconfirmed;
  int get activeLeases => _leases;

  static String _identity(ModelRegistration value) => jsonEncode([
    value.digest,
    value.path,
    value.runtime,
    value.backend,
    value.modelType,
  ]);

  void _check(int epoch, String identity, bool Function() current) {
    if (_closed ||
        _suspended ||
        _unconfirmed ||
        epoch != _epoch ||
        !current()) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Speech model admission cancelled',
      );
    }
    final value = _registration();
    if (value == null || _identity(value) != identity) {
      throw const AudioRecognitionBlocked('frozen_model_unavailable');
    }
  }

  Future<AudioSpeechModelLease> acquire(
    String revision,
    bool Function() current,
  ) async {
    final value = _registration();
    if (value == null || value.digest != revision) {
      throw const AudioRecognitionBlocked('frozen_model_unavailable');
    }
    final epoch = _epoch, identity = _identity(value);
    _check(epoch, identity, current);
    final existing = _cache;
    if (existing != null && existing.identity != identity) {
      throw const AudioRecognitionBlocked('speech_configuration_needs_barrier');
    }
    late final _VerifiedSpeechCache cache;
    if (existing != null) {
      cache = existing;
    } else {
      // One opener owns file verification and physical native admission. A
      // cancelled waiter cannot cancel another caller's valid admission.
      final opening = _opening ??= _open(value, epoch, identity);
      try {
        cache = await opening;
      } finally {
        if (identical(_opening, opening)) _opening = null;
      }
    }
    _check(epoch, identity, current);
    if (cache.identity != identity) {
      throw const AudioRecognitionBlocked('speech_configuration_needs_barrier');
    }
    _leases++;
    return AudioSpeechModelLease(
      revision: revision,
      runtime: cache.runtime,
      path: cache.path,
      release: () async {
        _leases--;
        if (_leases == 0) {
          _drained?.complete();
          _drained = null;
        }
      },
    );
  }

  Future<_VerifiedSpeechCache> _open(
    ModelRegistration value,
    int epoch,
    String identity,
  ) async {
    void check() => _check(epoch, identity, () => true);
    check();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value.digest)) {
      throw const AudioRecognitionBlocked('frozen_model_unavailable');
    }
    final runtime = requireInstalledRuntime(
      value.runtime,
      configuration: _configuration,
    );
    late final String path;
    try {
      path = await File(value.path).resolveSymbolicLinks();
      final file = File(path), before = await File(path).stat();
      if (before.type != FileSystemEntityType.file) {
        throw const AudioRecognitionBlocked('frozen_model_unavailable');
      }
      // Read asynchronously and hash bounded chunks, checking cancellation
      // between reads. Never hold an entire model in memory.
      final digest = await sha256
          .bind(
            file.openRead().map((bytes) {
              check();
              return bytes;
            }),
          )
          .first;
      final after = await file.stat();
      check();
      if (digest.toString() != value.digest ||
          before.size != after.size ||
          before.modified != after.modified ||
          before.changed != after.changed ||
          await File(value.path).resolveSymbolicLinks() != path) {
        throw const AudioRecognitionBlocked('frozen_model_unavailable');
      }
    } on FileSystemException {
      throw const AudioRecognitionBlocked('frozen_model_unavailable');
    }
    check();
    final owner = await _createCache(runtime, path, () {
      try {
        check();
        return true;
      } catch (_) {
        return false;
      }
    });
    try {
      check();
    } catch (_) {
      try {
        await owner.close();
      } catch (_) {
        _unconfirmed = true;
      }
      rethrow;
    }
    return _cache = _VerifiedSpeechCache(identity, runtime, path, owner);
  }

  /// Stops new leases immediately, waits all admitted readers, and retires the
  /// shared model keeper. Callers must cancel/join the scheduler first.
  Future<void> suspend() {
    _suspended = true;
    _epoch++;
    return _suspending ??= _suspend().whenComplete(() => _suspending = null);
  }

  Future<void> _suspend() async {
    try {
      await _opening;
    } catch (_) {
      // A cancelled opener still owns its cleanup before settling.
    }
    if (_leases != 0) await (_drained ??= Completer<void>()).future;
    final cache = _cache;
    if (cache != null) {
      try {
        await cache.owner.close();
        _cache = null;
      } catch (_) {
        _unconfirmed = true;
        rethrow;
      }
    }
    if (_unconfirmed) {
      throw StateError(
        'Speech model ownership is unconfirmed; restart the service',
      );
    }
  }

  void resume() {
    if (_closed || _unconfirmed || _suspending != null) {
      throw StateError('Speech model cache is unavailable');
    }
    _suspended = false;
  }

  Future<void> close() {
    _closed = true;
    return suspend();
  }
}

final class _VerifiedSpeechCache {
  _VerifiedSpeechCache(this.identity, this.runtime, this.path, this.owner);
  final String identity, runtime, path;
  final AudioSpeechCacheOwner owner;
}

final class _NativeSpeechCache implements AudioSpeechCacheOwner {
  _NativeSpeechCache(this.bindings, this.handle);
  final NativeLibrary bindings;
  final int handle;
  Future<void>? _closing;

  static Future<_NativeSpeechCache> open(
    NativeLibrary bindings,
    String runtime,
    String path,
    bool Function() current,
  ) async {
    await bindings.prepareAdmission();
    if (!current()) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Speech model admission cancelled',
      );
    }
    bindings.lifetime.ensureAdmission();
    final runtimeText = runtime.toNativeUtf8(), pathText = path.toNativeUtf8();
    try {
      final create = bindings.library
          .lookupFunction<
            Uint64 Function(Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>)
          >('fs_owned_speech_create');
      final handle = create(runtimeText, pathText);
      if (handle == 0) {
        throw const AudioRecognitionBlocked('speech_runtime_unavailable');
      }
      return _NativeSpeechCache(bindings, handle);
    } finally {
      calloc.free(runtimeText);
      calloc.free(pathText);
    }
  }

  @override
  Future<void> close() =>
      _closing ??= bindings.lifetime.retire('fs_speech_retire', handle);
}
