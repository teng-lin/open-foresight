import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class GranolaFixture {
  late HttpServer server;
  Uri? authorization;
  String? expectedAuthContext;
  int refreshes = 0, exchanges = 0, calendarCalls = 0;
  bool rejectExchange = false, failCalendar = false, unauthorizedOnce = false;
  bool verification = false;
  bool malformedExchange = false;
  String subject = 'workos-user-1';
  Completer<void>? exchangeStarted, releaseExchange;
  final operations = <String>[];
  List<Map<String, dynamic>> events = [
    {
      'id': 'event-1',
      'calendarId': 'work',
      'summary': 'Work meeting',
      'start': {'dateTime': '2026-10-20T09:00:00-04:00'},
      'end': {'dateTime': '2026-10-20T10:00:00-04:00'},
    },
  ];
  GranolaEndpoints get endpoints =>
      GranolaEndpoints(base: Uri.parse('http://127.0.0.1:${server.port}/v1/'));
  Map<String, Object> tokens([int n = 1]) => {
    'access_token': 'app-access-$n',
    'refresh_token': 'app-refresh-$n',
    'expires_in': 3600,
    'token_type': 'Bearer',
  };
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final operation = request.uri.path.split('/').last;
      operations.add(operation);
      expect(request.method, 'POST');
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      Object result;
      switch (operation) {
        case 'workos-auth-complete':
          exchanges++;
          if (malformedExchange) {
            request.response.write('private-response-not-json');
            await request.response.close();
            return;
          }
          expect(body['code'], 'one-time-code');
          expect(body['isDev'], false);
          expect(body['platform'], 'macOS');
          expect(request.headers.value('X-Granola-Platform'), 'macOS');
          if (expectedAuthContext != null) {
            expect(body['authContext'], expectedAuthContext);
          }
          final challenge = base64UrlEncode(
            sha256.convert(utf8.encode(body['codeVerifier'] as String)).bytes,
          ).replaceAll('=', '');
          expect(challenge, authorization!.queryParameters['code_challenge']);
          expect(
            body['signInClickId'],
            authorization!.queryParameters['sign_in_click_id'],
          );
          expect(request.headers.value('authorization'), null);
          exchangeStarted?.complete();
          await releaseExchange?.future;
          if (rejectExchange) {
            request.response.statusCode = 400;
            result = {'error': 'opaque-secret-should-not-be-logged'};
          } else if (verification) {
            result = {
              'status': 'verification_required',
              'pending_authentication_token': 'private',
            };
          } else {
            result = {'tokens': tokens(), 'config': {}};
          }
        case 'get-user-info':
          expect(
            request.headers.value('authorization'),
            startsWith('Bearer app-access-'),
          );
          result = {
            'id': subject,
            'email': 'fixture@example.test',
            'first_name': 'Fixture',
            'last_name': 'User',
          };
        case 'refresh-access-token':
          refreshes++;
          expect(body['refresh_token'], 'app-refresh-$refreshes');
          result = tokens(refreshes + 1);
        case 'refresh-calendar-events':
          calendarCalls++;
          if (unauthorizedOnce) {
            unauthorizedOnce = false;
            request.response.statusCode = 401;
            result = {};
          } else {
            result = {
              'results': {
                'events': events,
                'calendars': [],
                'error': failCalendar ? {'code': 'missing_scope'} : null,
              },
            };
          }
        default:
          request.response.statusCode = 404;
          result = {};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
  }

  Uri callback(
    Uri uri, {
    String action = 'login-complete',
    bool twice = false,
  }) {
    final redirect = Uri.parse(uri.queryParameters['redirect']!);
    final inner = Uri(
      scheme: 'granola',
      host: action,
      queryParameters: {'code': 'one-time-code'},
    ).toString();
    return redirect.replace(
      queryParameters: {
        ...redirect.queryParameters,
        'open-url': twice ? Uri.encodeComponent(inner) : inner,
      },
    );
  }

  Future<void> consent(GoogleAuth auth, Uri uri, {bool twice = false}) async {
    authorization = uri;
    expect(uri.queryParameters['provider'], 'google');
    expect(uri.queryParameters['dev'], 'false');
    expect(uri.queryParameters['platform'], 'macOS');
    expect(uri.queryParameters['version'], '7.663.2');
    expect(uri.queryParameters['code_challenge']!.length, 43);
    expect(uri.queryParameters.containsKey('client_secret'), false);
    auth.completeGranolaSignIn(callback(uri, twice: twice));
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Directory directory;
  late GranolaFixture fixture;
  late GoogleAuth auth;
  setUp(() async {
    directory = createTestTempDirectorySync('granola-calendar-');
    fixture = GranolaFixture();
    await fixture.start();
    auth = GoogleAuth(
      Directory('${directory.path}/google'),
      granolaEndpoints: fixture.endpoints,
      secretStore: const UnavailableSecretStore(),
    );
    await auth.configureGranola();
  });
  tearDown(() async {
    await auth.close();
    await fixture.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'owns the challenge, persists an isolated app session, refreshes and blocks Drive',
    () async {
      await auth.signIn((uri) => fixture.consent(auth, uri, twice: true));
      expect(auth.connected, true);
      expect(auth.displayName, 'Fixture User');
      expect(auth.viaGranola, true);
      final saved =
          jsonDecode(
                File('${auth.directory.path}/tokens.json').readAsStringSync(),
              )
              as Map;
      expect(saved['provider'], 'granola');
      expect(
        (File('${auth.directory.path}/tokens.json').statSync().mode & 0x3f),
        0,
      );
      await auth.accessToken(forceRefresh: true);
      expect(fixture.refreshes, 1);
      final before = fixture.operations.length;
      await expectLater(
        auth.api(Uri.parse('https://www.googleapis.com/drive/v3/files')),
        throwsStateError,
      );
      expect(fixture.operations.length, before);
      await auth.close();
      auth = GoogleAuth(
        auth.directory,
        granolaEndpoints: fixture.endpoints,
        secretStore: const UnavailableSecretStore(),
      );
      expect(auth.connected, true);
      expect(auth.viaGranola, true);
      await auth.disconnect();
      expect(auth.connected, false);
      expect(fixture.operations, isNot(contains('revoke')));
      expect(File('${auth.directory.path}/tokens.json').existsSync(), false);
    },
  );

  test(
    'rejects foreign, stale and wrong-state returns without consuming the attempt',
    () async {
      final opened = Completer<Uri>();
      final signIn = auth.signIn((uri) async {
        fixture.authorization = uri;
        opened.complete(uri);
      });
      final uri = await opened.future;
      final valid = fixture.callback(uri);
      for (final invalid in [
        valid.replace(scheme: 'granola'),
        valid.replace(
          queryParameters: {
            ...valid.queryParameters,
            'foresight_state': 'wrong',
          },
        ),
        fixture.callback(uri, action: 'calendar-link-complete'),
      ]) {
        expect(() => auth.completeGranolaSignIn(invalid), throwsStateError);
      }
      expect(auth.signingIn, true);
      auth.completeGranolaSignIn(valid);
      await signIn;
      expect(() => auth.completeGranolaSignIn(valid), throwsStateError);
      expect(fixture.exchanges, 1);
    },
  );

  test(
    'raw Granola return requires an explicit paste and saves only the session',
    () async {
      await auth.signIn((uri) async {
        fixture.authorization = uri;
        final raw = Uri(
          scheme: 'granola',
          host: 'login-complete',
          queryParameters: {
            'code': 'one-time-code',
            'signInClickId': uri.queryParameters['sign_in_click_id']!,
          },
        );
        expect(() => auth.completeGranolaSignIn(raw), throwsStateError);
        for (final invalid in [
          raw.replace(scheme: 'https'),
          raw.replace(
            queryParameters: {
              ...raw.queryParameters,
              'signInClickId': 'other-attempt',
            },
          ),
          raw.replace(queryParameters: {...raw.queryParameters, 'sso': 'true'}),
          Uri.parse('granola://login-complete?code=one&code=two'),
        ]) {
          expect(
            () => auth.completeGranolaSignIn(invalid, manual: true),
            throwsStateError,
          );
        }
        expect(fixture.exchanges, 0);
        auth.completeGranolaSignIn(raw, manual: true);
        expect(
          () => auth.completeGranolaSignIn(raw, manual: true),
          throwsStateError,
        );
      });
      expect(auth.connected, true);
      final persisted = File(
        '${auth.directory.path}/tokens.json',
      ).readAsStringSync();
      expect(persisted, isNot(contains('one-time-code')));
      expect(persisted, isNot(contains('codeVerifier')));
      expect(persisted, isNot(contains('granola://')));
      expect(fixture.exchanges, 1);
    },
  );

  test(
    'manual return from a cancelled attempt cannot complete a new attempt',
    () async {
      final firstOpened = Completer<Uri>();
      final first = auth.signIn((uri) async {
        firstOpened.complete(uri);
      });
      final cancelled = expectLater(first, throwsA(anything));
      final old = await firstOpened.future;
      final stale = Uri(
        scheme: 'granola',
        host: 'login-complete',
        queryParameters: {
          'code': 'one-time-code',
          'signInClickId': old.queryParameters['sign_in_click_id']!,
        },
      );
      auth.cancelSignIn();
      await cancelled;
      expect(
        () => auth.completeGranolaSignIn(stale, manual: true),
        throwsStateError,
      );
      await auth.signIn((uri) async {
        fixture.authorization = uri;
        expect(
          () => auth.completeGranolaSignIn(stale, manual: true),
          throwsStateError,
        );
        auth.completeGranolaSignIn(
          stale.replace(
            queryParameters: {
              'code': 'one-time-code',
              'signInClickId': uri.queryParameters['sign_in_click_id']!,
            },
          ),
          manual: true,
        );
      });
      expect(fixture.exchanges, 1);
    },
  );

  test(
    'Granola HTTPS bridge preserves completion fields and rejects other origins',
    () async {
      fixture.expectedAuthContext = 'fixture-signed-context';
      await auth.signIn((uri) async {
        fixture.authorization = uri;
        final bridge = Uri.https('www.granola.ai', '/app-redirect', {
          'code': 'one-time-code',
          'isDev': 'false',
          'platform': 'macos',
          'sso': 'false',
          'inAppCalendarLinking': 'false',
          'authContext': fixture.expectedAuthContext!,
          'signInClickId': uri.queryParameters['sign_in_click_id']!,
        });
        for (final invalid in [
          bridge.replace(host: 'www.granola.ai.evil.test'),
          bridge.replace(host: 'other.granola.ai'),
          bridge.replace(userInfo: 'user'),
          bridge.replace(scheme: 'http'),
          bridge.replace(port: 8443),
          bridge.replace(path: '/other'),
          bridge.replace(
            queryParameters: {
              ...bridge.queryParameters,
              'authContext': ['first', 'second'],
            },
          ),
        ]) {
          expect(
            () => auth.completeGranolaSignIn(invalid, manual: true),
            throwsStateError,
          );
        }
        expect(() => auth.completeGranolaSignIn(bridge), throwsStateError);
        expect(fixture.exchanges, 0);
        auth.completeGranolaSignIn(bridge, manual: true);
      });
      expect(auth.connected, true);
      expect(fixture.exchanges, 1);
    },
  );

  for (final encoded in [false, true]) {
    test(
      'manual callback tolerates browser trailing slash (encoded=$encoded)',
      () async {
        await auth.signIn((uri) async {
          fixture.authorization = uri;
          var callback = Uri(
            scheme: 'granola',
            host: 'login-complete',
            path: '/',
            queryParameters: {'code': 'one-time-code'},
          );
          if (encoded) {
            callback = Uri.parse(Uri.encodeComponent(callback.toString()));
          }
          auth.completeGranolaSignIn(callback, manual: true);
        });
        expect(auth.connected, true);
      },
    );
  }

  test(
    'cancel invalidates a return and cancellation during exchange cannot save tokens',
    () async {
      final opened = Completer<Uri>();
      final pending = auth.signIn((uri) async {
        opened.complete(uri);
      });
      final failure = expectLater(pending, throwsA(anything));
      final uri = await opened.future;
      auth.cancelSignIn();
      await failure;
      expect(
        () => auth.completeGranolaSignIn(fixture.callback(uri)),
        throwsStateError,
      );
      fixture.exchangeStarted = Completer<void>();
      fixture.releaseExchange = Completer<void>();
      final second = auth.signIn((uri) => fixture.consent(auth, uri));
      final secondFailure = expectLater(second, throwsA(anything));
      await fixture.exchangeStarted!.future;
      auth.cancelSignIn();
      fixture.releaseExchange!.complete();
      await secondFailure;
      expect(auth.connected, false);
      expect(File('${auth.directory.path}/tokens.json').existsSync(), false);
    },
  );

  test(
    'account changes cancel pending sign-in without invalidating themselves',
    () async {
      await auth.signIn((uri) => fixture.consent(auth, uri));
      fixture.subject = 'workos-user-2';
      await auth.addAccount((uri) => fixture.consent(auth, uri));
      expect(auth.account, 'workos-user-2');

      final switching = Completer<void>();
      final pendingSwitch = auth.addAccount(
        (uri) async => switching.complete(),
      );
      final switchCancelled = expectLater(pendingSwitch, throwsA(anything));
      await switching.future;
      await auth.switchAccount('workos-user-1');
      await switchCancelled;
      expect(auth.account, 'workos-user-1');

      final signingOut = Completer<void>();
      final pendingSignOut = auth.addAccount(
        (uri) async => signingOut.complete(),
      );
      final signOutCancelled = expectLater(pendingSignOut, throwsA(anything));
      await signingOut.future;
      await auth.signOutAccount('workos-user-1');
      await signOutCancelled;
      expect(auth.account, 'workos-user-2');
      expect(auth.accounts, hasLength(1));
      expect(fixture.operations, isNot(contains('revoke')));
    },
  );

  test(
    'failed exchanges and verification challenges do not persist credentials or leak bodies',
    () async {
      fixture.rejectExchange = true;
      await expectLater(
        auth.signIn((uri) => fixture.consent(auth, uri)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Granola calendar service failed (HTTP 400).',
          ),
        ),
      );
      fixture.rejectExchange = false;
      fixture.malformedExchange = true;
      await expectLater(
        auth.signIn((uri) => fixture.consent(auth, uri)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Invalid Granola calendar response.',
          ),
        ),
      );
      fixture.malformedExchange = false;
      fixture.verification = true;
      await expectLater(
        auth.signIn((uri) => fixture.consent(auth, uri)),
        throwsStateError,
      );
      expect(auth.connected, false);
      expect(auth.signingIn, false);
    },
  );

  test(
    'calendar snapshot uses app bearer, retries 401, preserves meetings and rejects partial failure',
    () async {
      await auth.signIn((uri) => fixture.consent(auth, uri));
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      );
      final connection = GoogleConnections(AdapterDomain(store, helper), auth);
      try {
        fixture.unauthorizedOnce = true;
        await connection.refresh();
        expect(fixture.refreshes, 1);
        expect(fixture.calendarCalls, 2);
        final first = store.rows('SELECT * FROM calendar_events').single;
        expect(first['calendar_id'], 'work');
        fixture.events[0]['summary'] = 'Changed title';
        await connection.refresh();
        expect(
          store.rows('SELECT * FROM calendar_events').single['meeting_id'],
          first['meeting_id'],
        );
        fixture.failCalendar = true;
        fixture.events.clear();
        await expectLater(connection.refresh(), throwsStateError);
        expect(
          store.rows('SELECT * FROM calendar_events').single['status'],
          'confirmed',
        );
        fixture.failCalendar = false;
        await connection.refresh();
        expect(
          store.rows('SELECT * FROM calendar_events').single['status'],
          'cancelled',
        );
        await expectLater(connection.driveFiles(), throwsStateError);
        expect(fixture.operations.every((s) => !s.contains('drive')), true);
      } finally {
        connection.close();
        await helper.close();
        store.close();
      }
    },
  );
}
