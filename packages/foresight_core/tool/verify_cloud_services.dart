// Opt-in distribution acceptance. Uses only port-provided credentials and public
// synthetic inputs; never reads the original application or changes a profile.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/web_content.dart';
import 'package:foresight_core/src/web_search.dart';
import 'package:grpc/grpc.dart';

Future<void> main(List<String> args) async {
  if (args.any((arg) => arg != '--download-query')) {
    stderr.writeln(
      'Usage: dart run tool/verify_cloud_services.dart '
      '[--download-query]',
    );
    exitCode = 64;
    return;
  }
  try {
    final outcome = await verifyCloudServices(
      endpointMode: 'production',
      downloadQuery: args.contains('--download-query'),
      configuration: RuntimeConfiguration.resolve().environment,
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(outcome.report));
    exitCode = outcome.code;
  } catch (error) {
    // A malformed runtime.json or constructor failure must not print its source
    // text: that file may contain the distribution credentials.
    stdout.writeln(
      jsonEncode({
        'status': 'failed',
        'endpoint_mode': 'production',
        'error_type': error.runtimeType.toString(),
      }),
    );
    exitCode = 1;
  }
}

/// Factories let controlled acceptance exercise the same transport with loopback
/// peers. The command-line entry always uses the recovered production endpoints.
Future<({Map<String, Object?> report, int code})> verifyCloudServices({
  required String endpointMode,
  required bool downloadQuery,
  required Map<String, String> configuration,
  SearchService Function(String)? searchFactory,
  WebContentService Function(String)? webFactory,
  ModelConfigService Function(String)? configFactory,
  ModelBlobDownloader Function(String)? blobFactory,
}) async {
  final report = <String, Object?>{
    'endpoint_mode': endpointMode,
    'inputs': 'public synthetic search and https://example.com/',
    'installation_modified': false,
  };
  var failed = false;
  var blocked = false;
  Future<void> check(
    String name,
    Future<Map<String, Object?>> Function() run,
  ) async {
    try {
      report[name] = {'status': 'passed', ...await run()};
    } catch (error) {
      failed = true;
      // Exceptions and response bodies can contain authenticated URIs. Report
      // only stable classifications, never error.toString() or a stack trace.
      report[name] = {
        'status': 'failed',
        'error_type': error.runtimeType.toString(),
        if (error is GrpcError) 'grpc_code': error.code,
        if (error is SearchHttpException) 'http_status': error.statusCode,
      };
    }
  }

  final searchKey = configuration['FORESIGHT_SEARCH_API_KEY'] ?? '';
  final sharedKey = configuration['FORESIGHT_WEB_CONTENT_API_KEY'] ?? '';
  if (searchKey.isEmpty) {
    blocked = true;
    report['search'] = {
      'status': 'blocked',
      'requires': 'FORESIGHT_SEARCH_API_KEY',
    };
  } else {
    await check('search', () async {
      final search =
          searchFactory?.call(searchKey) ?? SearchService(apiKey: searchKey);
      final results = await search.search('IANA example domains');
      if (results == null || results.isEmpty) throw StateError('No results');
      return {'result_count': results.length};
    });
  }
  if (sharedKey.isEmpty) {
    blocked = true;
    for (final name in ['website_summary', 'model_metadata']) {
      report[name] = {
        'status': 'blocked',
        'requires': 'FORESIGHT_WEB_CONTENT_API_KEY',
      };
    }
    if (downloadQuery) {
      report['query_blob'] = {
        'status': 'blocked',
        'requires': 'model_metadata',
      };
    }
  } else {
    final web =
        webFactory?.call(sharedKey) ?? WebContentService(apiKey: sharedKey);
    await check('website_summary', () async {
      try {
        final result = await web
            .fetchWebContent('https://example.com/')
            .timeout(const Duration(seconds: 30));
        if (result == null || result.summary.isEmpty) {
          throw StateError('No summary');
        }
        return {'summary_nonempty': true};
      } finally {
        await web.close();
      }
    });
    final config =
        configFactory?.call(sharedKey) ?? ModelConfigService(apiKey: sharedKey);
    ModelDownloadPlan? plan;
    await check('model_metadata', () async {
      try {
        final result = await config
            .fetch(appVersion: '1.0.0')
            .timeout(const Duration(seconds: 30));
        final selected = referenceModelDownloadPlan(
          result.onDeviceModelMetadatas,
          referenceQueryDetectorModelType,
        );
        if (selected == null ||
            selected.blobName.isEmpty ||
            selected.blobName == '.' ||
            selected.blobName == '..' ||
            selected.metadata.size.toInt() != dedicatedQueryModelBytes) {
          throw StateError('Supported detector is not advertised');
        }
        plan = selected;
        return {'supported_detector_advertised': true};
      } finally {
        await config.close();
      }
    });
    if (downloadQuery) {
      if ((report['model_metadata'] as Map)['status'] != 'passed' ||
          plan == null ||
          plan!.metadata.size.toInt() != dedicatedQueryModelBytes) {
        blocked = true;
        report['query_blob'] = {
          'status': 'blocked',
          'requires': 'model_metadata',
        };
      } else {
        final downloader =
            blobFactory?.call(sharedKey) ??
            ModelBlobDownloader(apiKey: sharedKey);
        await check('query_blob', () async {
          try {
            final bytes = await downloader
                .download(
                  blobId: plan!.blobName,
                  size: dedicatedQueryModelBytes,
                )
                .timeout(const Duration(minutes: 10));
            if (bytes.length != dedicatedQueryModelBytes ||
                sha256.convert(bytes).toString() != dedicatedQueryModelDigest) {
              throw StateError('Authenticated model identity mismatch');
            }
            return {'bytes': bytes.length, 'fixed_sha256_matches': true};
          } finally {
            downloader.close();
          }
        });
      }
    } else {
      report['query_blob'] = {
        'status': 'not_requested',
        'flag': '--download-query',
      };
    }
  }
  report['status'] = failed
      ? 'failed'
      : blocked
      ? 'blocked'
      : 'passed';
  return (
    report: report,
    code: failed
        ? 1
        : blocked
        ? 2
        : 0,
  );
}
