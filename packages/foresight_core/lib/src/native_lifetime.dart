import 'dart:async';
import 'dart:ffi';

/// Pins one actual native mapping. Validate ABI before resolving any dependent
/// symbol; optional diagnostic support is negotiated by its own consumer.
final class NativeLibrary {
  NativeLibrary(this._library);
  final DynamicLibrary _library;
  bool _verified = false;
  DynamicLibrary get library {
    if (!_verified) {
      if (!_library.providesSymbol('fs_abi_version') ||
          _library.lookupFunction<Int32 Function(), int Function()>(
                'fs_abi_version',
              )() !=
              1) {
        throw StateError('Incompatible native ABI');
      }
      _verified = true;
    }
    return _library;
  }

  static final _lifetimes = <DynamicLibrary, NativeLifetime>{};
  late final lifetime = _lifetimes.putIfAbsent(
    library,
    () => NativeLifetime._(library),
  );
}

/// Completion tokens own native work independently of Dart task/isolate
/// acknowledgements. Poll/release always use the original verified mapping.
final class NativeLifetime {
  NativeLifetime._(this._library) {
    if (!_library.providesSymbol('fs_lifetime_version') ||
        _library.lookupFunction<Int32 Function(), int Function()>(
              'fs_lifetime_version',
            )() !=
            2) {
      throw StateError('Native asynchronous lifetime support is unavailable');
    }
    // Resolve the capability as a complete suite before any handle is created.
    const ownedSymbols = [
      'fs_owner_release',
      'fs_owned_engine_create',
      'fs_owned_conversation_create',
      'fs_owned_speech_create',
      'fs_owned_capture_start',
      'fs_owned_engine_state',
      'fs_owned_event_poll',
      'fs_owned_generate_options',
      'fs_owned_generate_tools',
      'fs_owned_generation_tool_reply',
      'fs_owned_generation_cancel',
      'fs_owned_speech_push',
      'fs_owned_speech_finish',
      'fs_owned_speech_cancel',
      'fs_owned_capture_set_echo_cancellation',
    ];
    const requests = [
      'fs_engine_probe_async',
      'fs_engine_retire',
      'fs_conversation_retire',
      'fs_speech_retire',
      'fs_speech_join_async',
      'fs_capture_finish_async',
      'fs_capture_retire',
    ];
    if ([
      ...ownedSymbols,
      ...requests,
      'fs_operation_status',
      'fs_operation_release',
    ].any((name) => !_library.providesSymbol(name))) {
      throw StateError('Incomplete native asynchronous lifetime support');
    }
    for (final name in requests) {
      _requests[name] = _library
          .lookupFunction<Uint64 Function(Uint64), int Function(int)>(name);
    }
    _releaseOwner = _library
        .lookupFunction<Int32 Function(Uint64), int Function(int)>(
          'fs_owner_release',
        );
    _status = _library
        .lookupFunction<Int32 Function(Uint64), int Function(int)>(
          'fs_operation_status',
        );
    _release = _library
        .lookupFunction<Int32 Function(Uint64), int Function(int)>(
          'fs_operation_release',
        );
  }
  final DynamicLibrary _library;
  final _requests = <String, int Function(int)>{};
  final _pending = <int, Future<int>>{};
  late final int Function(int) _status, _release, _releaseOwner;

  bool _unconfirmed = false;

  /// A lost native completion cannot safely be transferred to another isolate.
  /// Retain the original mapping for cleanup, refuse new physical admissions,
  /// and make the required process restart visible to the owner.
  void ensureAdmission() {
    if (_unconfirmed) {
      throw StateError('Native ownership is unconfirmed; restart the service');
    }
  }

  StateError _unconfirmedError(String message) {
    _unconfirmed = true;
    return StateError('$message; restart the service');
  }

  Future<int> request(String name, int owner) {
    if (name == 'fs_engine_probe_async') ensureAdmission();
    final token = _requests[name]!(owner);
    if (token == 0) {
      return Future.error(StateError('Native operation was not admitted'));
    }
    return _pending.putIfAbsent(token, () {
      final future = _watch(token, name.endsWith('_retire') ? owner : null);
      // A synchronous close request must not produce an unhandled background
      // error before its owner reaches the awaitable completion. Keep the same
      // error visible to every caller joining this future.
      unawaited(
        future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      return future;
    });
  }

  Future<int> _watch(int token, int? retiringOwner) async {
    // Install the future in _pending before a previously completed native job
    // can synchronously reach the finally/removal path.
    await Future<void>.value();
    try {
      while (true) {
        final status = _status(token);
        if (status == 1 || status == 2) {
          if (retiringOwner != null) {
            if (status != 1 || _releaseOwner(retiringOwner) != 0) {
              throw _unconfirmedError(
                'Native retirement acknowledgement is unconfirmed',
              );
            }
          } else if (_release(token) != 0) {
            throw _unconfirmedError('Native completion could not be released');
          }
          return status;
        }
        if (status != 0) {
          throw _unconfirmedError('Native ownership completion is unconfirmed');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      _pending.remove(token)?.ignore();
    }
  }

  Future<void> retire(String name, int owner) async {
    if (await request(name, owner) != 1) {
      throw StateError('Native retirement did not complete successfully');
    }
  }
}
