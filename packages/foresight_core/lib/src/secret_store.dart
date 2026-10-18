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
class PlatformSecretStore implements SecretStore {
  static const service = 'org.open-foresight.google-refresh';
  final String? executable;
  final bool macOS;
  PlatformSecretStore()
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
