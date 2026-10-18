import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Profile-scoped credential storage. False means no usable platform store;
/// callers may then use a private file. Secrets never appear in process argv.
abstract interface class SecretStore {
  Future<bool> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class UnavailableSecretStore implements SecretStore {
  const UnavailableSecretStore();
  @override
  Future<bool> write(String key, String value) async => false;
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> delete(String key) async {}
}

/// macOS Keychain via Apple's system security utility, or Secret Service via
/// libsecret's secret-tool. Absolute system paths avoid a PATH override.
class CommandSecretStore implements SecretStore {
  static const service = 'org.open-foresight.google-refresh';
  final String? executable;
  final bool macOS;
  CommandSecretStore()
    : macOS = Platform.isMacOS,
      executable = Platform.isMacOS
          ? '/usr/bin/security'
          : Platform.isLinux && File('/usr/bin/secret-tool').existsSync()
          ? '/usr/bin/secret-tool'
          : null;

  Future<ProcessResult> _run(List<String> args, {String? input}) async {
    if (executable == null) {
      throw StateError('Platform secret store unavailable');
    }
    final process = await Process.start(executable!, args);
    final output = utf8.decoder.bind(process.stdout).join();
    final error = utf8.decoder.bind(process.stderr).join();
    if (input != null) process.stdin.write(input);
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      return ProcessResult(process.pid, code, await output, await error);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw StateError('Platform secret store timed out');
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    if (executable == null) return false;
    // Encoding makes the interactive Keychain command a single safe word and
    // allows arbitrary credential bytes without command-language interpolation.
    final encoded = base64UrlEncode(utf8.encode(value));
    try {
      final result = macOS
          ? await _run(
              ['-i'],
              input:
                  'add-generic-password -U -a $key -s $service -w $encoded\n',
            )
          : await _run([
              'store',
              '--label=Open Foresight Google authorization',
              'service',
              service,
              'profile',
              key,
            ], input: encoded);
      if (result.exitCode != 0) return false;
      // security -i may return success even if an interactive command failed.
      return await read(key) == value;
    } on ProcessException {
      return false;
    } on StateError {
      return false;
    }
  }

  @override
  Future<String?> read(String key) async {
    if (executable == null) return null;
    final result = await _run(
      macOS
          ? ['find-generic-password', '-a', key, '-s', service, '-w']
          : ['lookup', 'service', service, 'profile', key],
    );
    if (result.exitCode != 0) return null;
    final encoded = result.stdout.toString().trim();
    return utf8.decode(base64Url.decode(encoded));
  }

  @override
  Future<void> delete(String key) async {
    if (executable == null) return;
    final result = await _run(
      macOS
          ? ['delete-generic-password', '-a', key, '-s', service]
          : ['clear', 'service', service, 'profile', key],
    );
    // Keychain 44 and secret-tool 1 mean the entry is already absent.
    if (result.exitCode != 0 && result.exitCode != (macOS ? 44 : 1)) {
      throw StateError('Could not remove platform authorization');
    }
  }
}

/// macOS credentials belong to the service executable's Keychain principal,
/// never to the generally callable security command. Failures must not trigger
/// GoogleAuth's legacy plaintext fallback.
class PlatformSecretStore implements SecretStore {
  late final SecretStore _delegate = Platform.isMacOS
      ? MacKeychainSecretStore(NativeMacSecretStore(), CommandSecretStore())
      : CommandSecretStore();
  @override
  Future<bool> write(String key, String value) => _delegate.write(key, value);
  @override
  Future<String?> read(String key) => _delegate.read(key);
  @override
  Future<void> delete(String key) => _delegate.delete(key);
}

class MacKeychainSecretStore implements SecretStore {
  final SecretStore protected, legacy;
  MacKeychainSecretStore(this.protected, this.legacy);
  @override
  Future<bool> write(String key, String value) async {
    if (!await protected.write(key, value) ||
        await protected.read(key) != value) {
      throw StateError(
        'Cannot protect macOS authorization in the service Keychain',
      );
    }
    await legacy.delete(key);
    return true;
  }

  @override
  Future<String?> read(String key) async {
    final current = await protected.read(key);
    if (current != null) {
      await legacy.delete(key);
      return current;
    }
    final old = await legacy.read(key);
    if (old == null) return null;
    await write(key, old);
    return old;
  }

  @override
  Future<void> delete(String key) async {
    await protected.delete(key);
    await legacy.delete(key);
  }
}

class NativeMacSecretStore implements SecretStore {
  static const service = 'org.open-foresight.google-refresh.protected.v1';
  late final _library = DynamicLibrary.open(runtimeConfiguration.nativeLibrary);
  late final _read = _library
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>),
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>)
      >('fs_keychain_read');
  late final _write = _library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
      >('fs_keychain_write');
  late final _delete = _library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('fs_keychain_delete');
  late final _free = _library
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('fs_string_free');
  T _withIdentity<T>(
    String key,
    T Function(Pointer<Utf8>, Pointer<Utf8>) operation,
  ) {
    final label = service.toNativeUtf8(), account = key.toNativeUtf8();
    try {
      return operation(label, account);
    } finally {
      calloc.free(label);
      calloc.free(account);
    }
  }

  @override
  Future<bool> write(String key, String value) async =>
      _withIdentity(key, (label, account) {
        final encoded = base64UrlEncode(utf8.encode(value)).toNativeUtf8();
        try {
          final status = _write(label, account, encoded);
          if (status != 0) {
            throw StateError('Protected Keychain write failed ($status)');
          }
          return true;
        } finally {
          calloc.free(encoded);
        }
      });
  @override
  Future<String?> read(String key) async => _withIdentity(key, (
    label,
    account,
  ) {
    final status = calloc<Int32>();
    Pointer<Utf8> value = nullptr;
    try {
      value = _read(label, account, status);
      if (status.value == -25300) return null;
      if (status.value != 0 || value == nullptr) {
        throw StateError('Protected Keychain read failed (${status.value})');
      }
      return utf8.decode(base64Url.decode(value.toDartString()));
    } finally {
      if (value != nullptr) _free(value);
      calloc.free(status);
    }
  });
  @override
  Future<void> delete(String key) async => _withIdentity(key, (label, account) {
    final status = _delete(label, account);
    if (status != 0 && status != -25300) {
      throw StateError('Protected Keychain deletion failed ($status)');
    }
  });
}
