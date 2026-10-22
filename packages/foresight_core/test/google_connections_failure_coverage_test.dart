import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _MediaAuth extends GoogleAuth {
  _MediaAuth(super.directory, {required super.endpoints})
    : super(secretStore: const UnavailableSecretStore());
  List<int> media = utf8.encode('Launch safely.');
  bool oversizedListing = false;

  @override
  Future<Uint8ListResponse> api(
    Uri uri, {
    int maximumBytes = 32 * 1024 * 1024,
  }) {
    if (uri.queryParameters['alt'] == 'media') {
      return Future.value(Uint8ListResponse(200, media));
    }
    return super.api(uri, maximumBytes: maximumBytes);
  }

  @override
  Future<Map<String, dynamic>> apiJson(Uri uri) {
    if (oversizedListing && uri.path == '/drive/files') {
      return Future.value({
        'files': List.generate(
          10001,
          (index) => <String, dynamic>{'id': '$index'},
        ),
      });
    }
    return super.apiJson(uri);
  }
}

class _RegistryOnlyHttp implements HttpClient {
  int requests = 0;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    requests++;
    throw StateError('Saved registry validation must not use HTTP');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late GoogleFixture fixture;
  late _MediaAuth auth;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late GoogleConnections connection;

  setUp(() async {
    root = createTestTempDirectorySync('google-import-errors-');
    fixture = GoogleFixture();
    await fixture.start();
    auth = _MediaAuth(
      Directory('${root.path}/google'),
      endpoints: fixture.endpoints,
    )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
    store = Store('${root.path}/app.db');
    helper = Helper('${root.path}/unused.sock', '${root.path}/unused');
    domain = AdapterDomain(store, helper);
    connection = GoogleConnections(domain, auth);
    addTearDown(() async {
      connection.close();
      domain.close();
      await auth.close();
      await helper.close();
      await fixture.close();
      store.close();
      root.deleteSync(recursive: true);
    });
    await auth.signIn(fixture.consent);
  });

  Map<String, dynamic> file(String mime, {bool trashed = false}) => {
    'id': 'owned-file',
    'name': 'Owned import',
    'mimeType': mime,
    'trashed': trashed,
    'modifiedTime': '2026-01-01T00:00:00Z',
    'webViewLink': 'https://fixture.invalid/owned-file',
  };

  test(
    'failed document parsing removes private cache and preserves published text',
    () async {
      await connection.importDriveFile(
        'owned-file',
        metadata: file('text/plain'),
      );
      final source = store.sources.single;
      expect(source['content'], contains('Launch safely'));
      expect(source['source_uri'], 'https://fixture.invalid/owned-file');
      expect(domain.indexed, [source['id']]);
      final cache = Directory('${auth.directory.path}/downloads');
      final previous = Map.of(source);
      auth.media = utf8.encode('not a PDF');
      await expectLater(
        connection.importDriveFile(
          'owned-file',
          metadata: file('application/pdf'),
        ),
        throwsStateError,
      );
      expect(cache.listSync(), isEmpty);
      expect(cache.statSync().mode & 0x1ff, 0x1c0);
      expect(store.sources.single['content'], previous['content']);
      expect(store.sources.single['revision'], previous['revision']);
    },
  );

  test(
    'trash, unsupported formats and oversized listings cannot publish or index',
    () async {
      await expectLater(
        connection.importDriveFile(
          'trash',
          metadata: file('text/plain', trashed: true),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('Drive trash'),
          ),
        ),
      );
      await expectLater(
        connection.importDriveFile(
          'archive',
          metadata: file('application/zip'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('unsupported file type'),
          ),
        ),
      );
      auth.oversizedListing = true;
      await expectLater(
        connection.driveFiles(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('10,000'),
          ),
        ),
      );
      expect(store.sources, isEmpty);
      expect(domain.indexed, isEmpty);
    },
  );

  test(
    'failed last-year imports report all filenames without replacing successful sources',
    () async {
      fixture.restrictedFiles.add('doc');
      fixture.exportDeniedFiles.add('slides');
      await expectLater(
        connection.importLastYear(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'failures',
            allOf(contains('Apollo'), contains('Slides')),
          ),
        ),
      );
      expect(store.sources, isEmpty);
      expect(domain.indexed, isEmpty);
      fixture.restrictedFiles.clear();
      fixture.exportDeniedFiles.clear();
      await connection.importLastYear();
      expect(
        store.sources.map((row) => row['title']),
        containsAll(['Apollo', 'Slides']),
      );
      final previous = store.sources
          .map((row) => (row['id'], row['revision']))
          .toList();
      await expectLater(
        connection.importLastYear(current: () => false),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(
        store.sources.map((row) => (row['id'], row['revision'])).toList(),
        previous,
      );
    },
  );

  test(
    'denied loopback sign-in rejects malformed callbacks and closes its listener',
    () async {
      final local = GoogleAuth(
        Directory('${root.path}/denied'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await local.close();
      });
      await expectLater(
        local.signIn((authorization) async {
          final redirect = Uri.parse(
            authorization.queryParameters['redirect_uri']!,
          );
          final state = authorization.queryParameters['state']!;
          Future<int> callback(Map<String, String> query) async {
            final response = await (await client.getUrl(
              redirect.replace(queryParameters: query),
            )).close();
            await response.drain<void>();
            return response.statusCode;
          }

          expect(
            await callback({'state': 'wrong', 'code': 'must-not-exchange'}),
            400,
          );
          expect(await callback({'state': state}), 400);
          await expectLater(
            local.signIn((_) async {}),
            throwsA(
              isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
            ),
          );
          expect(
            await callback({'state': state, 'error': 'access_denied'}),
            200,
          );
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('access_denied'),
          ),
        ),
      );
      expect(local.signingIn, isFalse);
      expect(local.connected, isFalse);
      expect(File('${local.directory.path}/tokens.json').existsSync(), isFalse);
      await local.close();
      await expectLater(local.signIn((_) async {}), throwsStateError);
    },
  );

  test(
    'local HTTP transport limits response size and sends explicit JSON headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<Map<String, Object?>>();
      server.listen((request) async {
        if (request.uri.path == '/large') {
          request.response.write('01234567890123456789');
        } else {
          received.complete({
            'body': jsonDecode(await utf8.decoder.bind(request).join()),
            'platform': request.headers.value('X-Granola-Platform'),
            'client': request.headers.value('X-Client-Version'),
            'authorization': request.headers.value(
              HttpHeaders.authorizationHeader,
            ),
          });
          request.response.write('{}');
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');
      await expectLater(
        auth.request(uri.resolve('large'), maximumBytes: 8),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('size limit'),
          ),
        ),
      );
      final response = await auth.request(
        uri.resolve('json'),
        method: 'POST',
        bearer: 'local-fixture-only',
        jsonBody: {'query': 'owned data'},
      );
      expect(response.status, 200);
      final request = await received.future;
      expect(request['body'], {'query': 'owned data'});
      expect(request['platform'], Platform.isMacOS ? 'macOS' : 'linux');
      expect(request['client'], '7.663.2');
      expect(request['authorization'], 'Bearer local-fixture-only');
    },
  );

  test(
    'invalid saved credential registries fail closed without rewriting local evidence',
    () async {
      final valid = <String, Object?>{
        'access_token': 'local-fixture',
        'refresh_token': 'local-refresh',
        'account_sub': 'local-account',
        'expires_at': 4102444800000,
      };
      Future<Directory> privateCase(String name) async {
        final directory = Directory('${root.path}/$name')..createSync();
        expect(
          (await Process.run('/bin/chmod', ['700', directory.path])).exitCode,
          0,
        );
        expect(directory.statSync().mode & 0x1ff, 0x1c0);
        return directory;
      }

      final clientConfiguration = File('${root.path}/registry-client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {'client_id': 'fixture.apps.googleusercontent.com'},
          }),
        );
      final admittedDirectory = await privateCase('valid-private-registry');
      final admittedTokens = File('${admittedDirectory.path}/tokens.json')
        ..writeAsStringSync(jsonEncode(valid));
      expect(
        (await Process.run('/bin/chmod', [
          '600',
          admittedTokens.path,
        ])).exitCode,
        0,
      );
      expect(admittedTokens.statSync().mode & 0x1ff, 0x180);
      final admittedBytes = admittedTokens.readAsBytesSync();
      final admittedHttp = _RegistryOnlyHttp();
      final admitted = GoogleAuth(
        admittedDirectory,
        defaultClient: clientConfiguration,
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
        http: admittedHttp,
      );
      try {
        expect(admitted.loadError, isEmpty);
        expect(admitted.connected, isTrue);
        expect(await admitted.accessToken(), 'local-fixture');
        expect(admittedHttp.requests, 0);
        expect(admittedTokens.readAsBytesSync(), admittedBytes);
        expect(admittedDirectory.statSync().mode & 0x1ff, 0x1c0);
        expect(admittedTokens.statSync().mode & 0x1ff, 0x180);
      } finally {
        await admitted.close();
      }
      final cases = <Map<String, Object?>>[
        {},
        {...valid, 'provider': 'granola'},
        {
          ...valid,
          'saved_accounts': [
            {...valid},
          ],
        },
        {
          ...valid,
          'saved_accounts': [
            {...valid, 'account_sub': 'other', 'provider': 'granola'},
          ],
        },
      ];
      for (var index = 0; index < cases.length; index++) {
        final directory = await privateCase('invalid-$index');
        final tokens = File('${directory.path}/tokens.json')
          ..writeAsStringSync(jsonEncode(cases[index]));
        expect(
          (await Process.run('/bin/chmod', ['600', tokens.path])).exitCode,
          0,
        );
        expect(tokens.statSync().mode & 0x1ff, 0x180);
        final previous = tokens.readAsBytesSync();
        final localHttp = _RegistryOnlyHttp();
        final local = GoogleAuth(
          directory,
          defaultClient: clientConfiguration,
          endpoints: fixture.endpoints,
          secretStore: const UnavailableSecretStore(),
          http: localHttp,
        );
        try {
          expect(local.loadError, isNotEmpty);
          await expectLater(local.accessToken(), throwsStateError);
          expect(local.connected, isFalse);
          expect(tokens.readAsBytesSync(), previous);
          expect(localHttp.requests, 0);
          expect(directory.statSync().mode & 0x1ff, 0x1c0);
          expect(tokens.statSync().mode & 0x1ff, 0x180);
        } finally {
          await local.close();
        }
      }
      final directory = await privateCase('public-tokens');
      final tokens = File('${directory.path}/tokens.json')
        ..writeAsStringSync(jsonEncode(valid));
      expect(
        (await Process.run('/bin/chmod', ['644', tokens.path])).exitCode,
        0,
      );
      expect(tokens.statSync().mode & 0x1ff, 0x1a4);
      final previous = tokens.readAsBytesSync();
      final localHttp = _RegistryOnlyHttp();
      final local = GoogleAuth(
        directory,
        defaultClient: clientConfiguration,
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
        http: localHttp,
      );
      try {
        expect(local.loadError, isNotEmpty);
        await expectLater(local.accessToken(), throwsStateError);
        expect(local.connected, isFalse);
        expect(tokens.readAsBytesSync(), previous);
        expect(localHttp.requests, 0);
        expect(directory.statSync().mode & 0x1ff, 0x1c0);
        expect(tokens.statSync().mode & 0x1ff, 0x1a4);
      } finally {
        await local.close();
      }
      await expectLater(auth.switchAccount('not-saved'), throwsStateError);
      await expectLater(auth.signOutAccount('not-saved'), throwsStateError);
      expect(auth.connected, isTrue);
    },
  );
}
