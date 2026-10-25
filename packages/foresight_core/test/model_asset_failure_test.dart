import 'dart:io';
import 'dart:convert';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/model_asset_failure.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_catalog.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'worker failure frames use only closed codes and bounded numeric fields',
    () async {
      final saved = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(saved),
      );
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      final root = createTestTempDirectorySync('public-failure-frame-');
      final script = File('${root.path}/service');
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = script.path;
      final model = GemmaModel(
        'fixture',
        'fixture/model',
        'revision',
        'fixture.bin',
        '0' * 64,
        4,
        0,
      );
      Future<void> frame(Map<String, Object?> value, Matcher expected) async {
        final json = jsonEncode(value);
        // All frame values below are fixed test data; no diagnostic is executed.
        script.writeAsStringSync(
          "#!/bin/sh\nwhile IFS= read -r line; do :; done\nprintf '%s\\n' '$json'\n",
        );
        final mode = await Process.run('/bin/chmod', [
          '700',
          script.path,
        ]).timeout(const Duration(seconds: 3));
        expect(mode.exitCode, 0);
        final downloader = PublicModelFileDownloader(
          retryPolicy: ModelDownloadRetryPolicy(
            maxAttempts: 1,
            delay: (_) => Duration.zero,
          ),
        );
        addTearDown(downloader.cancel);
        await expectLater(downloader.download(model, root), throwsA(expected));
      }

      for (final code in ModelAssetFailureCode.values) {
        await frame(
          {
            'ok': false,
            'kind': 'public_failure',
            'code': code.name,
            if (code == ModelAssetFailureCode.diskSpace)
              'required_bytes': 2000000000,
            'diagnostic': 'https://host/private?key=secret',
          },
          isA<ModelAssetFailure>()
              .having((e) => e.code, 'code', code)
              .having(
                (e) => e.message,
                'safe message',
                isNot(contains('secret')),
              ),
        );
      }
      for (final invalid in [
        {'code': 'private?key=secret'},
        {'code': 'diskSpace', 'required_bytes': -1},
        {'code': 'diskSpace', 'required_bytes': 1 << 60},
        {'code': 'diskSpace', 'required_bytes': 'private?key=secret'},
        {'code': 'hash', 'required_bytes': 1},
      ]) {
        await frame(
          {'ok': false, 'kind': 'public_failure', ...invalid},
          isA<ModelTransportException>().having(
            (e) => e.failureType,
            'type',
            'invalid_worker_frame',
          ),
        );
      }
    },
  );

  test('setup text accepts only closed safe model errors', () {
    for (final code in ModelAssetFailureCode.values) {
      final failure = ModelAssetFailure(
        code,
        requiredBytes: code == ModelAssetFailureCode.diskSpace
            ? 2000000000
            : null,
      );
      expect(
        modelSetupFailureMessage(RpcError.from(failure.toRpcError().toJson())),
        failure.message,
      );
    }
    for (final failure in [
      StateError('/private/path token=secret'),
      RpcError(RpcErrorCode.unavailable, 'https://host/model?key=secret'),
      ModelTransportException('credential=secret'),
    ]) {
      final message = modelSetupFailureMessage(failure);
      expect(message, isNot(contains('secret')));
      expect(message, ModelAssetFailure(ModelAssetFailureCode.invalid).message);
    }
    for (final message in [
      modelTermsRequiredMessage,
      modelDownloadBusyMessage,
      modelRuntimeUnavailableMessage,
      modelRuntimeNotReadyMessage,
      modelAcquisitionRestartMessage,
    ]) {
      expect(
        modelSetupFailureMessage(RpcError(RpcErrorCode.unavailable, message)),
        message,
      );
    }
  });

  test(
    'real public worker preserves HTTPS failure without diagnostic strings',
    () async {
      final root = createTestTempDirectorySync('public-error-');
      final downloader = PublicModelFileDownloader();
      addTearDown(downloader.cancel);
      final model = GemmaModel(
        'fixture',
        'fixture/model',
        'revision',
        'fixture.bin',
        '0' * 64,
        4,
        0,
      );
      await expectLater(
        downloader.download(
          model,
          root,
          sourceForTesting: Uri.parse('http://127.0.0.1:1/?key=secret'),
        ),
        throwsA(
          isA<ModelAssetFailure>().having(
            (e) => e.code,
            'code',
            ModelAssetFailureCode.https,
          ),
        ),
      );
    },
  );
}
