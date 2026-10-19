// Dedicated CI account only. Never loads an existing application profile.
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/platform_services.dart';

Future<void> main() async {
  final result = await verifyGoogleLive(Platform.environment);
  stdout.writeln(jsonEncode(result));
  exitCode = result['status'] == 'passed' ? 0 : 1;
}

/// Endpoint injection is for offline transport tests; the CLI uses Google.
Future<Map<String, Object?>> verifyGoogleLive(
  Map<String, String> configuration, {
  GoogleEndpoints? endpoints,
}) async {
  const required = [
    'FORESIGHT_CI_GOOGLE_CLIENT_JSON',
    'FORESIGHT_CI_GOOGLE_REFRESH_TOKEN',
    'FORESIGHT_CI_GOOGLE_SUB',
    'FORESIGHT_CI_GOOGLE_FILE_ID',
    'FORESIGHT_CI_GOOGLE_EXPECTED_TEXT',
  ];
  final missing = required
      .where((key) => (configuration[key] ?? '').trim().isEmpty)
      .toList();
  if (missing.isNotEmpty) return {'status': 'blocked', 'requires': missing};
  Directory? directory;
  GoogleAuth? auth;
  try {
    final client = GoogleClient.parse(
      jsonDecode(configuration[required[0]]!) as Map<String, dynamic>,
    );
    directory = await createPrivateTempDirectory(
      Directory.systemTemp,
      'of-google-live-',
    );
    final tokenFile = File('${directory.path}/tokens.json');
    await tokenFile.writeAsString(
      jsonEncode({
        'access_token': 'expired-ci-bootstrap',
        'refresh_token': configuration[required[1]],
        'account_sub': configuration[required[2]],
        'expires_at': 0,
      }),
    );
    final protection = await Process.run('/bin/chmod', ['600', tokenFile.path]);
    if (protection.exitCode != 0) {
      throw StateError('Cannot protect CI credential');
    }
    auth = GoogleAuth(
      directory,
      secretStore: const UnavailableSecretStore(),
      endpoints: endpoints,
    )..client = client;
    await auth.accessToken(forceRefresh: true);
    final identity = await auth.apiJson(auth.endpoints.userinfo);
    if (identity['sub'] != configuration[required[2]]) {
      throw StateError('Unexpected CI account');
    }
    final file = configuration[required[3]]!;
    final path = 'files/${Uri.encodeComponent(file)}';
    final metadata = await auth.apiJson(
      auth.endpoints.drive
          .resolve(path)
          .replace(
            queryParameters: {
              'fields': 'id,mimeType,trashed,capabilities(canDownload)',
            },
          ),
    );
    if (metadata['id'] != file ||
        metadata['mimeType'] != 'application/vnd.google-apps.document' ||
        metadata['trashed'] == true ||
        (metadata['capabilities'] as Map?)?['canDownload'] == false) {
      throw StateError('Expected a downloadable CI Google document');
    }
    final response = await auth.api(
      auth.endpoints.drive
          .resolve('$path/export')
          .replace(queryParameters: {'mimeType': 'text/plain'}),
    );
    if (!utf8.decode(response.bytes).contains(configuration[required[4]]!)) {
      throw StateError('CI document did not contain its expected marker');
    }
    // Reopen the disposable profile to exercise persisted refreshed credentials.
    await auth.close();
    auth = GoogleAuth(
      directory,
      secretStore: const UnavailableSecretStore(),
      endpoints: endpoints,
    )..client = client;
    final restored = await auth.apiJson(auth.endpoints.userinfo);
    if (restored['sub'] != configuration[required[2]]) {
      throw StateError('CI authorization did not survive reopen');
    }
    return {
      'status': 'passed',
      'token_refresh': 'passed',
      'account_identity': 'passed',
      'drive_export': 'passed',
      'credential_reopen': 'passed',
      'interactive_consent': 'not_run',
      'remote_revocation': 'not_run',
      'semantic_indexing': 'not_run',
    };
  } catch (error) {
    // Exceptions may contain authenticated URLs, tokens or document content.
    return {'status': 'failed', 'error_type': error.runtimeType.toString()};
  } finally {
    await auth?.close();
    // Do not disconnect/forget: those operations revoke the reusable CI grant.
    if (directory != null) await directory.delete(recursive: true);
  }
}
