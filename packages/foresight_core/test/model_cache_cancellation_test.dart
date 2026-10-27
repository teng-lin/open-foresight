import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/model_cache.dart';
import 'package:foresight_core/src/model_download_contract.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cache verification observes retirement between streamed file chunks',
    () async {
      final root = createTestTempDirectorySync('cache-cancel-');
      final bytes = List<int>.filled(4 * 1024 * 1024, 3);
      final file = File('${root.path}/cache.bin')..writeAsBytesSync(bytes);
      var checks = 0;
      await expectLater(
        verifyModelFile(
          file,
          sha256.convert(bytes).toString(),
          bytes.length,
          current: () => ++checks < 3,
        ),
        throwsA(isA<ModelDownloadCancelled>()),
      );
      expect(checks, 3);
      expect(
        await verifyModelFile(
          file,
          sha256.convert(bytes).toString(),
          bytes.length,
        ),
        true,
      );
    },
  );
}
