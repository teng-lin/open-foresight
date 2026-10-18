import 'package:foresight_core/src/secret_store.dart';
import 'package:test/test.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<bool> write(String key, String value) async {
    if (failWrite) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test('legacy Keychain item migrates only after protected readback', () async {
    final legacy = MemorySecrets()..values['profile'] = 'refresh';
    final protected = MemorySecrets();
    final store = MacKeychainSecretStore(protected, legacy);
    expect(await store.read('profile'), 'refresh');
    expect(protected.values['profile'], 'refresh');
    expect(legacy.values, isEmpty);
    await store.delete('profile');
    expect(protected.values, isEmpty);
  });
  test(
    'failed protected write throws instead of enabling plaintext fallback',
    () async {
      final legacy = MemorySecrets()..values['profile'] = 'refresh';
      final protected = MemorySecrets()..failWrite = true;
      final store = MacKeychainSecretStore(protected, legacy);
      await expectLater(store.write('profile', 'new'), throwsStateError);
      await expectLater(store.read('profile'), throwsStateError);
      expect(legacy.values['profile'], 'refresh');
    },
  );
}
