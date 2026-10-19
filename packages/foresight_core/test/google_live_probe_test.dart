import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:test/test.dart';

import '../tool/verify_google_live.dart';

void main() {
  test(
    'missing CI credentials are blocked before any network request',
    () async {
      final result = await verifyGoogleLive({});
      expect(result['status'], 'blocked');
      expect(result['requires'], hasLength(5));
    },
  );

  for (final failure in ['none', 'identity', 'export', 'refresh', 'mime']) {
    test(
      'live Google probe validates $failure through production transport',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final base = Uri.parse('http://127.0.0.1:${server.port}/');
        final endpoints = GoogleEndpoints(
          token: base.resolve('token'),
          userinfo: base.resolve('userinfo'),
          drive: base.resolve('drive/'),
          revoke: base.resolve('revoke'),
        );
        final requests = <String>[];
        final subscription = server.listen((request) async {
          requests.add(request.uri.path);
          if (request.uri.path == '/token') {
            final form = Uri.splitQueryString(
              await utf8.decoder.bind(request).join(),
            );
            expect(form['grant_type'], 'refresh_token');
            expect(form['refresh_token'], 'private-ci-refresh');
            if (failure == 'refresh') {
              request.response.statusCode = 400;
              request.response.write('{"error":"private-ci-refresh"}');
            } else {
              request.response.write(
                jsonEncode({
                  'access_token': 'private-ci-access',
                  'expires_in': 3600,
                }),
              );
            }
          } else {
            expect(
              request.headers.value('authorization'),
              'Bearer private-ci-access',
            );
            switch (request.uri.path) {
              case '/userinfo':
                request.response.write(
                  jsonEncode({
                    'sub': failure == 'identity'
                        ? 'wrong-account'
                        : 'dedicated-ci-account',
                  }),
                );
              case '/drive/files/ci-document':
                request.response.write(
                  jsonEncode({
                    'id': 'ci-document',
                    'mimeType': failure == 'mime'
                        ? 'application/pdf'
                        : 'application/vnd.google-apps.document',
                    'capabilities': {'canDownload': true},
                  }),
                );
              case '/drive/files/ci-document/export':
                expect(request.uri.queryParameters['mimeType'], 'text/plain');
                request.response.write(
                  failure == 'export' ? 'unrelated' : 'public CI marker',
                );
              default:
                fail('Unexpected network operation: ${request.uri.path}');
            }
          }
          await request.response.close();
        });
        addTearDown(subscription.cancel);
        final result = await verifyGoogleLive({
          'FORESIGHT_CI_GOOGLE_CLIENT_JSON': jsonEncode({
            'installed': {
              'client_id': 'ci.apps.googleusercontent.com',
              'client_secret': 'private-ci-client',
            },
          }),
          'FORESIGHT_CI_GOOGLE_REFRESH_TOKEN': 'private-ci-refresh',
          'FORESIGHT_CI_GOOGLE_SUB': 'dedicated-ci-account',
          'FORESIGHT_CI_GOOGLE_FILE_ID': 'ci-document',
          'FORESIGHT_CI_GOOGLE_EXPECTED_TEXT': 'public CI marker',
        }, endpoints: endpoints);
        expect(
          result['status'],
          failure == 'none' ? 'passed' : 'failed',
          reason: '$result; requests: $requests',
        );
        final expectedRequests = [
          '/token',
          if (failure != 'refresh') '/userinfo',
          if (failure != 'refresh' && failure != 'identity')
            '/drive/files/ci-document',
          if (['none', 'export'].contains(failure))
            '/drive/files/ci-document/export',
          if (failure == 'none') '/userinfo',
        ];
        expect(requests, expectedRequests);
        if (failure == 'none') {
          expect(result['credential_reopen'], 'passed');
          expect(result['interactive_consent'], 'not_run');
        }
        expect(requests, isNot(contains('/revoke')));
        final report = jsonEncode(result);
        for (final secret in [
          'private-ci-refresh',
          'private-ci-access',
          'private-ci-client',
          'dedicated-ci-account',
          'public CI marker',
        ]) {
          expect(report, isNot(contains(secret)));
        }
      },
    );
  }

  test(
    'CLI failures exit nonzero without exposing supplied credentials',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'tool/verify_google_live.dart'],
        environment: {
          ...Platform.environment,
          'FORESIGHT_CI_GOOGLE_CLIENT_JSON': '{private-cli-client',
          'FORESIGHT_CI_GOOGLE_REFRESH_TOKEN': 'private-cli-refresh',
          'FORESIGHT_CI_GOOGLE_SUB': 'private-cli-account',
          'FORESIGHT_CI_GOOGLE_FILE_ID': 'private-cli-file',
          'FORESIGHT_CI_GOOGLE_EXPECTED_TEXT': 'private-cli-content',
        },
      );
      expect(result.exitCode, 1);
      expect(jsonDecode(result.stdout as String), {
        'status': 'failed',
        'error_type': 'FormatException',
      });
      expect(
        '${result.stdout}${result.stderr}',
        isNot(contains('private-cli-')),
      );
    },
  );
}
