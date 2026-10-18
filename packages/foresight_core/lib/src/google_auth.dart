import 'rpc_error.dart';
import 'desktop_connection.dart';
import 'secret_store.dart';
export 'secret_store.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

class GoogleEndpoints {
  final Uri authorize, token, revoke, userinfo, drive, calendar;
  GoogleEndpoints({
    Uri? authorize,
    Uri? token,
    Uri? revoke,
    Uri? userinfo,
    Uri? drive,
    Uri? calendar,
  }) : authorize =
           authorize ??
           Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
       token = token ?? Uri.parse('https://oauth2.googleapis.com/token'),
       revoke = revoke ?? Uri.parse('https://oauth2.googleapis.com/revoke'),
       userinfo =
           userinfo ??
           Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
       drive = drive ?? Uri.parse('https://www.googleapis.com/drive/v3/'),
       calendar =
           calendar ?? Uri.parse('https://www.googleapis.com/calendar/v3/');
}

class GoogleClient {
  final String id, secret;
  GoogleClient(this.id, this.secret);
  factory GoogleClient.parse(Map<String, dynamic> json) {
    final installed = json['installed'];
    if (installed is! Map ||
        installed['client_id'] is! String ||
        !(installed['client_id'] as String).endsWith(
          '.apps.googleusercontent.com',
        ))
      throw StateError(
        'Choose a Google OAuth Desktop app client JSON, not a web or Apple client.',
      );
    return GoogleClient(
      installed['client_id'] as String,
      installed['client_secret'] as String? ?? '',
    );
  }
  Map<String, Object?> toJson() => {
    'installed': {
      'client_id': id,
      if (secret.isNotEmpty) 'client_secret': secret,
    },
  };
}

/// OAuth access never uses another application's tokens. Loopback listener,
/// PKCE and state validation bind consent to this app's sign-in attempt.
class GoogleAuth implements GoogleAccount {
  static const scopes = [
    'openid',
    'email',
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/calendar.events.readonly',
  ];
  final Directory directory;
  final GoogleEndpoints endpoints;
  final HttpClient http;
  final SecretStore secretStore;
  late final String _secretKey = sha256
      .convert(utf8.encode(directory.absolute.path))
      .toString();
  GoogleClient? client;
  String loadError = '';
  Map<String, dynamic>? _tokens;
  HttpServer? _callback;
  Completer<String>? _authorization;
  Future<String>? _refreshing;
  bool _closed = false, _disconnecting = false;
  int _authorizationGeneration = 0;
  Future<void> _credentialBarrier = Future<void>.value();
  Future<void>? _forgetting;

  Future<T> _changeCredential<T>(Future<T> Function() action) {
    final result = _credentialBarrier.then((_) => action());
    _credentialBarrier = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  GoogleAuth(
    this.directory, {
    GoogleEndpoints? endpoints,
    HttpClient? http,
    File? defaultClient,
    SecretStore? secretStore,
  }) : endpoints = endpoints ?? GoogleEndpoints(),
       http = http ?? HttpClient(),
       secretStore = secretStore ?? PlatformSecretStore() {
    final config = File('${directory.path}/client.json'),
        tokens = File('${directory.path}/tokens.json');
    try {
      if (config.existsSync())
        client = GoogleClient.parse(
          jsonDecode(config.readAsStringSync()) as Map<String, dynamic>,
        );
      else {
        final bundled =
            defaultClient ??
            (runtimeConfiguration['FORESIGHT_GOOGLE_CLIENT'] == null
                ? null
                : File(runtimeConfiguration['FORESIGHT_GOOGLE_CLIENT']!));
        if (bundled?.existsSync() == true)
          client = GoogleClient.parse(
            jsonDecode(bundled!.readAsStringSync()) as Map<String, dynamic>,
          );
      }
      if (tokens.existsSync()) {
        privateDirectory(directory.path);
        if (FileSystemEntity.typeSync(tokens.path, followLinks: false) !=
                FileSystemEntityType.file ||
            (tokens.statSync().mode & 0x3f) != 0) {
          throw StateError('Saved Google authorization must be a private file');
        }
        final loaded =
            jsonDecode(tokens.readAsStringSync()) as Map<String, dynamic>;
        if (loaded['access_token'] is! String ||
            (loaded['refresh_token'] is! String &&
                loaded['refresh_token_store'] != 'platform') ||
            loaded['account_sub'] is! String ||
            loaded['expires_at'] is! int)
          throw StateError('Incomplete saved Google authorization');
        _tokens = loaded;
      }
    } catch (_) {
      _tokens = null;
      loadError =
          'Saved Google setup could not be loaded. Import your Desktop client configuration and sign in again.';
    }
  }
  bool get connected =>
      !_disconnecting &&
      (_tokens?['refresh_token'] is String ||
          _tokens?['refresh_token_store'] == 'platform') &&
      _tokens?['account_sub'] is String;
  String get account => _tokens?['account_sub'] as String? ?? '';
  String get email => _tokens?['email'] as String? ?? '';
  bool get signingIn => _callback != null;
  String _random(int bytes) => base64UrlEncode(
    List.generate(bytes, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
  Future<void> _save(
    String name,
    Map<String, dynamic> data, {
    int? authorizationGeneration,
  }) async {
    if (_closed) throw StateError('Google connection closed');
    privateDirectory(directory.path);
    final temp = File('${directory.path}/.$name-${_random(8)}');
    try {
      await temp.create();
      final mode = await Process.run('chmod', ['600', temp.path]);
      if (mode.exitCode != 0 || _closed)
        throw StateError('Cannot protect Google connection data');
      await temp.writeAsString(jsonEncode(data), flush: true);
      if (authorizationGeneration != null &&
          authorizationGeneration != _authorizationGeneration)
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      temp.renameSync('${directory.path}/$name');
    } finally {
      if (temp.existsSync()) await temp.delete();
    }
  }

  Future<String?> _refreshCredential() async {
    final token = _tokens?['refresh_token'];
    if (token is String) return token;
    if (_tokens?['refresh_token_store'] == 'platform') {
      final token = await secretStore.read(_secretKey);
      if (token == null)
        throw StateError(
          'Saved Google authorization is unavailable. Sign in again.',
        );
      return token;
    }
    return null;
  }

  Future<void> _saveTokens(Map<String, dynamic> data, int generation) =>
      _changeCredential(() => _persistTokens(data, generation));

  Future<void> _persistTokens(Map<String, dynamic> data, int generation) async {
    if (_closed || generation != _authorizationGeneration) {
      throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
    }
    final token =
        data['refresh_token'] as String? ?? await _refreshCredential();
    if (token == null) throw StateError('Missing Google refresh authorization');
    final secured = await secretStore.write(_secretKey, token);
    try {
      final persisted = Map<String, dynamic>.from(data);
      if (secured) {
        persisted.remove('refresh_token');
        persisted['refresh_token_store'] = 'platform';
      } else {
        persisted.remove('refresh_token_store');
        persisted['refresh_token'] = token;
      }
      await _save(
        'tokens.json',
        persisted,
        authorizationGeneration: generation,
      );
    } catch (_) {
      if (secured && generation != _authorizationGeneration) {
        await secretStore.delete(_secretKey);
      }
      rethrow;
    }
  }

  Future<void> configure(File file) async {
    if (_disconnecting || _forgetting != null)
      throw RpcError(RpcErrorCode.busy, 'Google disconnect is in progress');
    if (connected)
      throw StateError(
        'Disconnect the current Google account before changing its OAuth client.',
      );
    final candidate = GoogleClient.parse(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
    await _save('client.json', candidate.toJson());
    client = candidate;
    loadError = '';
  }

  Future<Uint8ListResponse> request(
    Uri uri, {
    String method = 'GET',
    String? bearer,
    Map<String, String>? form,
    int maximumBytes = 32 * 1024 * 1024,
  }) async {
    if (_closed) throw StateError('Google connection closed');
    final request = await http
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 30));
    if (bearer != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    if (form != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(
        form.entries
            .map(
              (entry) =>
                  '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
            )
            .join('&'),
      );
    }
    final response = await request.close().timeout(const Duration(seconds: 45));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > maximumBytes)
        throw StateError('Google response exceeds the supported size limit.');
    }
    return Uint8ListResponse(response.statusCode, bytes);
  }

  Map<String, dynamic> _json(Uint8ListResponse response) {
    final json =
        jsonDecode(utf8.decode(response.bytes)) as Map<String, dynamic>;
    if (response.status < 200 || response.status >= 300) {
      final error = json['error'];
      throw StateError(
        error is Map
            ? error['message']?.toString() ??
                  'Google API failed (HTTP ${response.status})'
            : json['error_description']?.toString() ??
                  'Google authorization failed: $error',
      );
    }
    return json;
  }

  Future<void> signIn(Future<void> Function(Uri) openBrowser) async {
    if (_closed) throw StateError('Google connection closed');
    if (_disconnecting || _forgetting != null)
      throw RpcError(RpcErrorCode.busy, 'Google disconnect is in progress');
    final generation = _authorizationGeneration;
    if (connected)
      throw StateError(
        'Disconnect the current Google account before signing in again.',
      );
    if (client == null)
      throw StateError('Import a Desktop OAuth client configuration first.');
    if (signingIn)
      throw RpcError(RpcErrorCode.busy, 'Google sign-in is already open.');
    final nonce = _random(32), verifier = _random(64);
    final authorization = Completer<String>();
    _authorization = authorization;
    // A remote client may cancel while the loopback listener is still binding.
    unawaited(authorization.future.then<void>((_) {}, onError: (Object _) {}));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _callback = server;
    final redirect = 'http://127.0.0.1:${server.port}/oauth2callback';
    final listener = server.listen((request) async {
      try {
        final params = request.uri.queryParameters;
        if (request.uri.path != '/oauth2callback' || params['state'] != nonce) {
          request.response.statusCode = 400;
          request.response.write(
            'Invalid sign-in callback. Return to Foresight and retry.',
          );
          return;
        }
        if (authorization.isCompleted) {
          request.response.statusCode = 409;
          return;
        }
        if (params['error'] != null) {
          authorization.completeError(
            StateError('Google sign-in was denied: ${params['error']}'),
          );
          request.response.write('Sign-in cancelled. You can close this tab.');
        } else if (params['code']?.isNotEmpty == true) {
          authorization.complete(params['code']);
          request.response.write(
            'Signed in. You can close this tab and return to Foresight.',
          );
        } else {
          request.response.statusCode = 400;
          request.response.write('Missing authorization code.');
        }
      } finally {
        await request.response.close();
      }
    });
    // Install the error listener before opening the browser/callback can occur.
    final code = authorization.future
        .timeout(const Duration(minutes: 3))
        .then<Object>((value) => value, onError: (Object error) => error);
    try {
      final uri = endpoints.authorize.replace(
        queryParameters: {
          'client_id': client!.id,
          'redirect_uri': redirect,
          'response_type': 'code',
          'scope': scopes.join(' '),
          'state': nonce,
          'code_challenge': base64UrlEncode(
            sha256.convert(utf8.encode(verifier)).bytes,
          ).replaceAll('=', ''),
          'code_challenge_method': 'S256',
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );
      await openBrowser(uri);
      final returned = await code;
      if (returned is! String) throw returned;
      final token = _json(
        await request(
          endpoints.token,
          method: 'POST',
          form: {
            'client_id': client!.id,
            if (client!.secret.isNotEmpty) 'client_secret': client!.secret,
            'code': returned,
            'code_verifier': verifier,
            'redirect_uri': redirect,
            'grant_type': 'authorization_code',
          },
        ),
      );
      final granted = (token['scope'] as String? ?? '').split(' ').toSet();
      if (!scopes.skip(2).every(granted.contains))
        throw StateError(
          'Drive and Calendar read access are both required. Reconnect and grant these permissions.',
        );
      final access = token['access_token'] as String;
      final identity = _json(await request(endpoints.userinfo, bearer: access));
      final saved = {
        ...token,
        'expires_at':
            DateTime.now().millisecondsSinceEpoch +
            (token['expires_in'] as num).toInt() * 1000,
        'account_sub': identity['sub'],
        'email': identity['email'],
      };
      if (saved['refresh_token'] is! String || saved['account_sub'] is! String)
        throw StateError(
          'Google did not return a persistent account authorization. Reconnect.',
        );
      await _saveTokens(saved, generation);
      if (generation != _authorizationGeneration)
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      _tokens = saved;
      loadError = '';
    } finally {
      if (!authorization.isCompleted)
        authorization.completeError(
          RpcError(RpcErrorCode.cancelled, 'Google sign-in cancelled'),
        );
      await listener.cancel();
      await server.close(force: true);
      if (identical(_callback, server)) _callback = null;
      if (identical(_authorization, authorization)) _authorization = null;
    }
  }

  void cancelSignIn() {
    if (_authorization?.isCompleted == false)
      _authorization!.completeError(
        RpcError(RpcErrorCode.cancelled, 'Google sign-in cancelled'),
      );
  }

  Future<String> accessToken({bool forceRefresh = false}) async {
    if (!connected || client == null)
      throw StateError('Connect your Google account first.');
    if (!forceRefresh &&
        (_tokens!['expires_at'] as int) >
            DateTime.now().millisecondsSinceEpoch + 60000)
      return _tokens!['access_token'] as String;
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    final generation = _authorizationGeneration;
    final token = _json(
      await request(
        endpoints.token,
        method: 'POST',
        form: {
          'client_id': client!.id,
          if (client!.secret.isNotEmpty) 'client_secret': client!.secret,
          'refresh_token': (await _refreshCredential())!,
          'grant_type': 'refresh_token',
        },
      ),
    );
    if (_disconnecting || _closed || generation != _authorizationGeneration)
      throw RpcError(
        RpcErrorCode.cancelled,
        'Google connection changed during refresh',
      );
    final saved = {
      ..._tokens!,
      ...token,
      'expires_at':
          DateTime.now().millisecondsSinceEpoch +
          (token['expires_in'] as num).toInt() * 1000,
    };
    await _saveTokens(saved, generation);
    if (generation != _authorizationGeneration)
      throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
    _tokens = saved;
    return saved['access_token'] as String;
  }

  Future<Uint8ListResponse> api(
    Uri uri, {
    int maximumBytes = 32 * 1024 * 1024,
  }) async {
    var response = await request(
      uri,
      bearer: await accessToken(),
      maximumBytes: maximumBytes,
    );
    if (response.status == 401)
      response = await request(
        uri,
        bearer: await accessToken(forceRefresh: true),
        maximumBytes: maximumBytes,
      );
    if (response.status < 200 || response.status >= 300) {
      _json(response);
    }
    return response;
  }

  Future<Map<String, dynamic>> apiJson(Uri uri) async => _json(await api(uri));

  /// Forget credentials immediately; remote revocation cannot gate local erasure.
  Future<void> forget() {
    _authorizationGeneration++;
    cancelSignIn();
    final existing = _forgetting;
    if (existing != null) return existing;
    final token = _tokens?['refresh_token'] as String?;
    final secured = _tokens?['refresh_token_store'] == 'platform';
    final file = File('${directory.path}/tokens.json');
    if (file.existsSync()) file.deleteSync();
    _tokens = null;
    return _forgetting = _changeCredential(() async {
      String? refresh = token;
      if (refresh == null && secured) {
        try {
          refresh = await secretStore.read(_secretKey);
        } catch (_) {
          /* Still erase. */
        }
      }
      await secretStore.delete(_secretKey);
      await _revokeBestEffort(refresh);
    }).whenComplete(() => _forgetting = null);
  }

  Future<void> _revokeBestEffort(String? token) async {
    if (token == null) return;
    try {
      await request(
        endpoints.revoke,
        method: 'POST',
        form: {'token': token},
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Revocation cannot prevent clearing an offline local workspace.
    }
  }

  Future<void> disconnect() async {
    _authorizationGeneration++;
    cancelSignIn();
    _disconnecting = true;
    try {
      final refresh = _refreshing;
      if (refresh != null) {
        try {
          await refresh;
        } catch (_) {}
      }
      final token = await _refreshCredential();
      if (token != null) {
        final response = await request(
          endpoints.revoke,
          method: 'POST',
          form: {'token': token},
        );
        if (response.status != 200 && response.status != 400)
          throw StateError(
            'Google could not revoke the connection. Retry disconnect.',
          );
      }
      await _changeCredential(() => secretStore.delete(_secretKey));
      _tokens = null;
      final file = File('${directory.path}/tokens.json');
      if (file.existsSync()) await file.delete();
    } finally {
      _disconnecting = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    cancelSignIn();
    await _callback?.close(force: true);
    http.close(force: true);
  }
}

class Uint8ListResponse {
  final int status;
  final List<int> bytes;
  Uint8ListResponse(this.status, this.bytes);
}
