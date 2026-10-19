import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:matcher/expect.dart';
// Shared fixtures exercise internal wire protocol types.
// ignore: implementation_imports
import 'package:foresight_core/src/domain.dart';
// Shared fixtures exercise internal wire protocol types.
// ignore: implementation_imports
import 'package:foresight_core/src/google_auth.dart';

class GoogleFixture {
  late HttpServer server;
  String challenge = '', redirect = '';
  int refreshes = 0;
  bool denyDriveOnce = false, cancelledEvent = false;
  bool newFolderFile = false;
  String accountSub = 'fixture-account';
  String eventDescription = 'Review Apollo.';
  String eventUpdated = '2020-01-01T00:00:00Z';
  String eventStart = '2026-10-16T15:00:00Z';
  String modified = 'v1', document = 'Apollo launches Friday.';
  String linkSuffix = '';
  final queries = <String>[], exports = <String>[];
  final fieldQueries = <String>[];
  final restrictedFiles = <String>{}, exportDeniedFiles = <String>{};
  void Function()? onExport;
  Future<void> Function()? beforeUserInfo;
  late GoogleEndpoints endpoints;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = Uri.parse('http://127.0.0.1:${server.port}/');
    endpoints = GoogleEndpoints(
      authorize: base.resolve('authorize'),
      token: base.resolve('token'),
      revoke: base.resolve('revoke'),
      userinfo: base.resolve('userinfo'),
      drive: base.resolve('drive/'),
      calendar: base.resolve('calendar/'),
    );
    server.listen((request) async {
      try {
        dynamic response;
        final path = request.uri.path;
        if (path == '/token') {
          final form = Uri.splitQueryString(
            await utf8.decoder.bind(request).join(),
          );
          if (form['grant_type'] == 'authorization_code') {
            expect(form['redirect_uri'], redirect);
            expect(
              base64UrlEncode(
                sha256.convert(utf8.encode(form['code_verifier']!)).bytes,
              ).replaceAll('=', ''),
              challenge,
            );
            expect(form['code_verifier']!.length, inInclusiveRange(43, 128));
          } else {
            refreshes++;
            expect(form['refresh_token'], 'fixture-refresh');
          }
          response = {
            'access_token': 'fixture-access-$refreshes',
            'refresh_token': 'fixture-refresh',
            'expires_in': 3600,
            'scope': GoogleAuth.scopes.join(' '),
          };
        } else if (path == '/userinfo') {
          await beforeUserInfo?.call();
          expect(
            request.headers.value('authorization'),
            startsWith('Bearer fixture-access'),
          );
          response = {'sub': accountSub, 'email': 'fixture@example.test'};
        } else if (path == '/revoke') {
          response = {};
        } else {
          expect(
            request.headers.value('authorization'),
            startsWith('Bearer fixture-access'),
          );
          if (denyDriveOnce && path.startsWith('/drive/')) {
            denyDriveOnce = false;
            request.response.statusCode = 401;
            response = {
              'error': {'message': 'Fixture token expired'},
            };
          } else if (path == '/drive/files') {
            final fields = request.uri.queryParameters['fields'];
            if (fields != null) fieldQueries.add(fields);
            final query = request.uri.queryParameters['q']!;
            queries.add(query);
            if (query.contains("'nested' in parents")) {
              response = {
                'files': [
                  file(
                    'sheet',
                    'Sheet',
                    'application/vnd.google-apps.spreadsheet',
                  ),
                ],
              };
            } else if (query.contains("'folder' in parents")) {
              response = {
                'files': [
                  file('doc', 'Apollo', 'application/vnd.google-apps.document'),
                  if (newFolderFile)
                    file(
                      'slides',
                      'Slides',
                      'application/vnd.google-apps.presentation',
                    ),
                  file(
                    'nested',
                    'Nested',
                    'application/vnd.google-apps.folder',
                  ),
                ],
              };
            } else if (request.uri.queryParameters['pageToken'] == 'page2') {
              response = {
                'files': [
                  file(
                    'slides',
                    'Slides',
                    'application/vnd.google-apps.presentation',
                  ),
                ],
              };
            } else {
              response = {
                'nextPageToken': 'page2',
                'files': [
                  file(
                    'folder',
                    'Folder',
                    'application/vnd.google-apps.folder',
                  ),
                  file('doc', 'Apollo', 'application/vnd.google-apps.document'),
                ],
              };
            }
          } else if (path.endsWith('/export')) {
            final mime = request.uri.queryParameters['mimeType']!;
            exports.add(mime);
            onExport?.call();
            if (exportDeniedFiles.contains(path.split('/')[3])) {
              request.response.statusCode = 403;
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'error': {
                    'message': 'This file cannot be downloaded by the user.',
                  },
                }),
              );
              return;
            }
            request.response.headers.contentType = ContentType.text;
            request.response.write(
              mime == 'text/csv'
                  ? 'Task,Owner\nReview,Ravi'
                  : path.contains('doc/')
                  ? document
                  : 'Slides about Apollo.',
            );
            return;
          } else if (path.startsWith('/drive/files/')) {
            final fields = request.uri.queryParameters['fields'];
            if (fields != null) fieldQueries.add(fields);
            final id = path.split('/').last;
            response = file(
              id,
              id == 'sheet'
                  ? 'Sheet'
                  : id == 'slides'
                  ? 'Slides'
                  : 'Apollo',
              id == 'sheet'
                  ? 'application/vnd.google-apps.spreadsheet'
                  : id == 'slides'
                  ? 'application/vnd.google-apps.presentation'
                  : 'application/vnd.google-apps.document',
            );
          } else if (path == '/calendar/calendars/primary/events') {
            expect(request.uri.queryParameters['singleEvents'], 'true');
            response = {
              'items': [
                cancelledEvent
                    ? {'id': 'event-1', 'status': 'cancelled'}
                    : {
                        'id': 'event-1',
                        'summary': 'Planning',
                        'updated': eventUpdated,
                        'htmlLink': 'https://calendar.example.test/event-1',
                        'description': eventDescription,
                        'status': 'confirmed',
                        'start': {'dateTime': eventStart},
                        'end': {'dateTime': '2026-10-16T15:30:00Z'},
                        'attendees': [
                          {'displayName': 'Ravi', 'email': 'ravi@example.test'},
                        ],
                        'attachments': [
                          {'fileId': 'doc', 'title': 'Apollo'},
                        ],
                      },
              ],
            };
          } else {
            request.response.statusCode = 404;
            response = {
              'error': {'message': 'Fixture endpoint not found: $path'},
            };
          }
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
      } finally {
        await request.response.close();
      }
    });
  }

  Map<String, Object?> file(String id, String name, String mime) => {
    'id': id,
    'name': name,
    'mimeType': mime,
    'modifiedTime': modified,
    'trashed': false,
    'capabilities': {'canDownload': !restrictedFiles.contains(id)},
    'webViewLink': 'https://drive.example.test/$id$linkSuffix',
  };
  Future<void> consent(Uri uri, {bool deny = false}) async {
    final params = uri.queryParameters;
    expect(params['code_challenge_method'], 'S256');
    challenge = params['code_challenge']!;
    redirect = params['redirect_uri']!;
    final browser = HttpClient();
    try {
      final invalid = await (await browser.getUrl(
        Uri.parse(
          redirect,
        ).replace(queryParameters: {'state': 'wrong', 'code': 'fixture-code'}),
      )).close();
      expect(invalid.statusCode, 400);
      await invalid.drain<void>();
      final response = await (await browser.getUrl(
        Uri.parse(redirect).replace(
          queryParameters: {
            'state': params['state']!,
            if (deny) 'error': 'access_denied' else 'code': 'fixture-code',
          },
        ),
      )).close();
      await response.drain<void>();
    } finally {
      browser.close(force: true);
    }
  }

  Future<void> close() => server.close(force: true);
}

class AdapterDomain extends Domain {
  final indexed = <String>[];
  AdapterDomain(super.store, super.helper);
  @override
  Future<void> index(String id) async {
    indexed.add(id);
    store.state(id, 'indexed');
  }

  @override
  Future<void> delete(String id) async {
    store.tombstone(id);
  }
}

class PausedAdapterDomain extends AdapterDomain {
  PausedAdapterDomain(super.store, super.helper);
  var pausedCheckpoint = Completer<void>();
  @override
  Future<void> waitForSourceWork() {
    if (sourcesPaused && !pausedCheckpoint.isCompleted) {
      pausedCheckpoint.complete();
    }
    return super.waitForSourceWork();
  }
}
