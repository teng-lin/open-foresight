import 'rpc_error.dart';
import 'desktop_connection.dart';
import 'desktop_status.dart';
import 'secret_store.dart';
import 'google_credential_cleanup.dart';
export 'secret_store.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

part 'granola_calendar_auth.dart';

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
        )) {
      throw StateError(
        'Choose a Google OAuth Desktop app client JSON, not a web or Apple client.',
      );
    }
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

/// Direct Google OAuth and an explicitly selected Granola calendar connection.
/// Each connection obtains its own authorization through the system browser.
class GoogleAuth implements GoogleAccount {
  static const scopes = [
    'openid',
    'email',
    'profile',
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/calendar.events.readonly',
  ];
  final Directory directory;
  final GoogleEndpoints endpoints;
  final GranolaEndpoints granolaEndpoints;
  bool _viaGranola = false;
  String? _granolaNonce;
  String? _granolaSignInClickId;
  bool get viaGranola => _viaGranola;
  final HttpClient http;
  final SecretStore secretStore;
  late final String _secretKey = sha256
      .convert(utf8.encode(directory.absolute.path))
      .toString();
  GoogleClient? client;
  @override
  bool get configured => client != null;
  @override
  String loadError = '';
  Map<String, dynamic>? _tokens;
  Map<String, dynamic>? _persistedActive;
  final Map<String, Map<String, dynamic>> _savedAccounts = {};
  HttpServer? _callback;
  Completer<String>? _authorization;
  Future<String>? _refreshing;
  Future<void>? _profileRefresh;
  bool _profileLoaded = false;
  bool _closed = false, _disconnecting = false;
  int _authorizationGeneration = 0;
  Future<void> _credentialBarrier = Future<void>.value();
  Future<void>? _forgetting;
  late final _cleanup = GoogleCredentialCleanup(
    directory,
    secretStore,
    _secretKey,
  );

  Set<String> get _activeCredentialKeys => {
    for (final data in [
      if (_tokens != null) _tokens!,
      if (_persistedActive != null) _persistedActive!,
      ..._savedAccounts.values,
    ])
      _credentialKey(data),
  };

  Future<void> retryCredentialCleanup() => _changeCredential(
    () => _cleanup.retry(
      revoke: _revokeBestEffort,
      activeKeys: _activeCredentialKeys,
    ),
  );

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
    GranolaEndpoints? granolaEndpoints,
    HttpClient? http,
    File? defaultClient,
    SecretStore? secretStore,
  }) : endpoints = endpoints ?? GoogleEndpoints(),
       granolaEndpoints = granolaEndpoints ?? GranolaEndpoints(),
       http = http ?? HttpClient(),
       secretStore = secretStore ?? PlatformSecretStore() {
    final config = File('${directory.path}/client.json'),
        tokens = File('${directory.path}/tokens.json');
    try {
      if (config.existsSync()) {
        final configuration =
            jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
        _viaGranola = configuration['provider'] == 'granola';
        client = _viaGranola
            ? GoogleClient('granola', '')
            : GoogleClient.parse(configuration);
      } else {
        final bundled =
            defaultClient ??
            (runtimeConfiguration['FORESIGHT_GOOGLE_CLIENT'] == null
                ? null
                : File(runtimeConfiguration['FORESIGHT_GOOGLE_CLIENT']!));
        if (bundled?.existsSync() == true) {
          client = GoogleClient.parse(
            jsonDecode(bundled!.readAsStringSync()) as Map<String, dynamic>,
          );
        }
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
            loaded['expires_at'] is! int) {
          throw StateError('Incomplete saved Google authorization');
        }
        if ((loaded['provider'] == 'granola') != _viaGranola) {
          throw StateError(
            'Saved authorization belongs to a different provider',
          );
        }
        final inactive = loaded.remove('saved_accounts');
        if (inactive != null) {
          if (inactive is! List) throw StateError('Invalid saved accounts');
          for (final value in inactive) {
            final saved = Map<String, dynamic>.from(value as Map);
            if ((saved['provider'] == 'granola') != _viaGranola ||
                !_validTokens(saved) ||
                _savedAccounts.containsKey(saved['account_sub']) ||
                saved['account_sub'] == loaded['account_sub']) {
              throw StateError('Invalid saved Google account');
            }
            _savedAccounts[saved['account_sub'] as String] = saved;
          }
        }
        _tokens = loaded;
        _persistedActive = Map<String, dynamic>.from(loaded);
      }
    } catch (_) {
      _tokens = null;
      _savedAccounts.clear();
      loadError = _viaGranola
          ? 'Saved Granola calendar authorization could not be loaded. Sign in again.'
          : 'Saved Google setup could not be loaded. Import your Desktop client configuration and sign in again.';
    }
  }
  static bool _validTokens(Map<String, dynamic> data) =>
      data['access_token'] is String &&
      (data['refresh_token'] is String ||
          data['refresh_token_store'] == 'platform') &&
      data['account_sub'] is String &&
      data['expires_at'] is int;

  String _credentialKey(Map<String, dynamic> data) =>
      data['refresh_token_account'] == true
      ? '$_secretKey-${sha256.convert(utf8.encode(data['account_sub'] as String))}'
      : _secretKey;

  @override
  List<GoogleAccountPresentation> get accounts => List.unmodifiable([
    if (_tokens != null) _summary(_tokens!, true),
    for (final saved in _savedAccounts.values) _summary(saved, false),
  ]);

  GoogleAccountPresentation _summary(Map<String, dynamic> data, bool current) =>
      GoogleAccountPresentation(
        id: data['account_sub'] as String,
        email: data['email'] as String? ?? '',
        displayName: data['name'] as String? ?? '',
        photoUrl: data['picture'] as String? ?? '',
        current: current,
      );

  @override
  bool get connected =>
      !_disconnecting &&
      (_tokens?['refresh_token'] is String ||
          _tokens?['refresh_token_store'] == 'platform') &&
      _tokens?['account_sub'] is String;
  @override
  String get account => _tokens?['account_sub'] as String? ?? '';
  @override
  String get email => _tokens?['email'] as String? ?? '';
  @override
  String get displayName => _tokens?['name'] as String? ?? '';
  @override
  String get photoUrl => _tokens?['picture'] as String? ?? '';
  @override
  bool get signingIn =>
      _callback != null || (_viaGranola && _authorization != null);

  Future<void> configureGranola() => _configureGranola();
  void completeGranolaSignIn(Uri uri, {bool manual = false}) =>
      _completeGranolaSignIn(uri, manual: manual);
  Future<Map<String, dynamic>> granolaCalendarEvents() {
    if (!_viaGranola) throw StateError('Granola calendar is not configured.');
    return _granolaApi('refresh-calendar-events');
  }

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
      final mode = await Process.run('/bin/chmod', ['600', temp.path]);
      if (mode.exitCode != 0 || _closed) {
        throw StateError('Cannot protect Google connection data');
      }
      await temp.writeAsString(jsonEncode(data), flush: true);
      if (authorizationGeneration != null &&
          authorizationGeneration != _authorizationGeneration) {
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      }
      temp.renameSync('${directory.path}/$name');
    } finally {
      if (temp.existsSync()) await temp.delete();
    }
  }

  Future<String?> _refreshCredential([Map<String, dynamic>? saved]) async {
    final data = saved ?? _tokens;
    final token = data?['refresh_token'];
    if (token is String) return token;
    if (data?['refresh_token_store'] == 'platform') {
      final token = await secretStore.read(_credentialKey(data!));
      if (token == null) {
        throw StateError(
          'Saved Google authorization is unavailable. Sign in again.',
        );
      }
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
    final subject = data['account_sub'] as String;
    final target = {
      ...data,
      'refresh_token_account': true,
      if (data['refresh_token_store'] == 'platform' &&
          data['refresh_token_account'] != true)
        'refresh_token_legacy': true,
    };
    final key = _credentialKey(target);
    final previousSecret = await secretStore.read(key);
    final secured = await secretStore.write(key, token);
    try {
      final persisted = Map<String, dynamic>.from(target);
      if (secured) {
        persisted.remove('refresh_token');
        persisted['refresh_token_store'] = 'platform';
      } else {
        persisted.remove('refresh_token_store');
        persisted['refresh_token'] = token;
      }
      final inactive = Map<String, Map<String, dynamic>>.from(_savedAccounts);
      inactive.remove(subject);
      if (_persistedActive != null &&
          _persistedActive!['account_sub'] != subject) {
        inactive[_persistedActive!['account_sub'] as String] =
            _persistedActive!;
      }
      await _saveRegistry(persisted, inactive, generation);
      _savedAccounts
        ..clear()
        ..addAll(inactive);
      _persistedActive = persisted;
      data['refresh_token_account'] = true;
      if (target['refresh_token_legacy'] == true) {
        data['refresh_token_legacy'] = true;
        if (!inactive.values.any(
          (saved) =>
              saved['refresh_token_store'] == 'platform' &&
              saved['refresh_token_account'] != true,
        )) {
          try {
            // The atomic registry already points at the verified scoped key.
            // A failed save above always retains the original legacy secret.
            await secretStore.delete(_secretKey);
          } catch (_) {
            // Keep the legacy marker so per-account logout retries cleanup.
          }
        }
      }
    } catch (_) {
      if (secured) {
        if (previousSecret == null) {
          await secretStore.delete(key);
        } else {
          await secretStore.write(key, previousSecret);
        }
      }
      rethrow;
    }
  }

  Future<void> _saveRegistry(
    Map<String, dynamic>? active,
    Map<String, Map<String, dynamic>> inactive,
    int generation,
  ) async {
    if (_closed || generation != _authorizationGeneration) {
      throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
    }
    if (active == null) {
      final file = File('${directory.path}/tokens.json');
      if (file.existsSync()) await file.delete();
      return;
    }
    await _save('tokens.json', {
      ...active,
      if (inactive.isNotEmpty) 'saved_accounts': inactive.values.toList(),
    }, authorizationGeneration: generation);
  }

  void _resetActiveWork() {
    _profileLoaded = false;
    _profileRefresh = null;
    _refreshing = null;
  }

  @override
  Future<void> switchAccount(String id) async {
    if (id == account) return;
    if (!_savedAccounts.containsKey(id)) {
      throw StateError('Google account is not saved');
    }
    if (_disconnecting) {
      throw RpcError(RpcErrorCode.busy, 'Google account change in progress');
    }
    cancelSignIn();
    final generation = ++_authorizationGeneration;
    await _changeCredential(() async {
      final next = _savedAccounts[id];
      if (next == null) throw StateError('Google account is not saved');
      final inactive = Map<String, Map<String, dynamic>>.from(_savedAccounts)
        ..remove(id);
      if (_persistedActive != null) {
        inactive[_persistedActive!['account_sub'] as String] =
            _persistedActive!;
      }
      await _saveRegistry(next, inactive, generation);
      _tokens = Map<String, dynamic>.from(next);
      _persistedActive = next;
      _savedAccounts
        ..clear()
        ..addAll(inactive);
      _resetActiveWork();
    });
  }

  @override
  Future<void> addAccount(Future<void> Function(Uri) openBrowser) =>
      _authorize(openBrowser, allowConnected: true);

  @override
  Future<void> configure(File file) async {
    if (_disconnecting || _forgetting != null) {
      throw RpcError(RpcErrorCode.busy, 'Google disconnect is in progress');
    }
    if (connected || (_viaGranola && accounts.isNotEmpty) || signingIn) {
      throw StateError(
        'Disconnect the current Google account before changing its OAuth client.',
      );
    }
    final candidate = GoogleClient.parse(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
    await _save('client.json', candidate.toJson());
    client = candidate;
    _viaGranola = false;
    loadError = '';
  }

  Future<Uint8ListResponse> request(
    Uri uri, {
    String method = 'GET',
    String? bearer,
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
    int maximumBytes = 32 * 1024 * 1024,
  }) async {
    if (_closed) throw StateError('Google connection closed');
    final request = await http
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 30));
    if (jsonBody != null) {
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'OpenForesight/GranolaCalendar',
      );
      request.headers.set('X-Client-Version', '7.663.2');
      request.headers.set(
        'X-Granola-Platform',
        Platform.isMacOS ? 'macOS' : 'linux',
      );
    }
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
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
    if (jsonBody != null) request.write(jsonEncode(jsonBody));
    final response = await request.close().timeout(const Duration(seconds: 45));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > maximumBytes) {
        throw StateError('Google response exceeds the supported size limit.');
      }
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

  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) =>
      _authorize(openBrowser);

  Future<void> _authorize(
    Future<void> Function(Uri) openBrowser, {
    bool allowConnected = false,
  }) async {
    if (_viaGranola) {
      return _authorizeGranola(openBrowser, allowConnected: allowConnected);
    }
    if (_closed) throw StateError('Google connection closed');
    if (_disconnecting || _forgetting != null) {
      throw RpcError(RpcErrorCode.busy, 'Google disconnect is in progress');
    }
    var generation = _authorizationGeneration;
    if (connected && !allowConnected) {
      throw StateError(
        'Disconnect the current Google account before signing in again.',
      );
    }
    if (client == null) {
      throw StateError('Import a Desktop OAuth client configuration first.');
    }
    if (signingIn) {
      throw RpcError(RpcErrorCode.busy, 'Google sign-in is already open.');
    }
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
          'prompt': allowConnected ? 'select_account consent' : 'consent',
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
      if (!scopes
          .where((scope) => scope.startsWith('https://'))
          .every(granted.contains)) {
        throw StateError(
          'Drive and Calendar read access are both required. Reconnect and grant these permissions.',
        );
      }
      final access = token['access_token'] as String;
      final identity = _json(await request(endpoints.userinfo, bearer: access));
      final saved = {
        ...token,
        'expires_at':
            DateTime.now().millisecondsSinceEpoch +
            (token['expires_in'] as num).toInt() * 1000,
        'account_sub': identity['sub'],
        'email': identity['email'],
        if (identity['name'] is String) 'name': identity['name'],
        if (identity['picture'] is String) 'picture': identity['picture'],
      };
      if (saved['refresh_token'] is! String ||
          saved['account_sub'] is! String) {
        throw StateError(
          'Google did not return a persistent account authorization. Reconnect.',
        );
      }
      if (generation != _authorizationGeneration) {
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      }
      generation = ++_authorizationGeneration;
      await _saveTokens(saved, generation);
      if (generation != _authorizationGeneration) {
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      }
      _tokens = saved;
      _resetActiveWork();
      _profileLoaded = displayName.isNotEmpty && photoUrl.isNotEmpty;
      if (!_profileLoaded) {
        try {
          await _loadProfile(identity);
        } catch (_) {
          // Optional identity enrichment cannot invalidate successful consent.
        }
      }
      loadError = '';
    } finally {
      if (!authorization.isCompleted) {
        authorization.completeError(
          RpcError(RpcErrorCode.cancelled, 'Google sign-in cancelled'),
        );
      }
      await listener.cancel();
      await server.close(force: true);
      if (identical(_callback, server)) _callback = null;
      if (identical(_authorization, authorization)) _authorization = null;
    }
  }

  @override
  void cancelSignIn() {
    if (_viaGranola && _authorization != null) _authorizationGeneration++;
    if (_authorization?.isCompleted == false) {
      _authorization!.completeError(
        RpcError(RpcErrorCode.cancelled, 'Google sign-in cancelled'),
      );
    }
  }

  /// Populate identity omitted by older installations without replacing consent.
  /// Missing profile claims remain optional for existing authorizations.
  Future<void> refreshProfile() {
    if (!connected ||
        _profileLoaded ||
        (displayName.isNotEmpty && photoUrl.isNotEmpty)) {
      return Future<void>.value();
    }
    return _profileRefresh ??= _loadProfile().whenComplete(
      () => _profileRefresh = null,
    );
  }

  Future<void> _loadProfile([Map<String, dynamic>? currentIdentity]) async {
    if (_viaGranola) return _loadGranolaProfile();
    final generation = _authorizationGeneration;
    final subject = account;
    final identity = currentIdentity ?? await apiJson(endpoints.userinfo);
    if (!connected || generation != _authorizationGeneration) return;
    if (identity['sub'] != subject) {
      throw StateError('Google profile does not match the connected account');
    }
    final profile = <String, dynamic>{
      if (identity['name'] is String) 'name': identity['name'],
      if (identity['picture'] is String) 'picture': identity['picture'],
    };
    var retryProfile = false;
    // Older grants include Drive read access but may lack the profile scope.
    // Drive exposes the same signed-in user's optional name and photo.
    if ((profile['name'] as String? ?? '').isEmpty ||
        (profile['picture'] as String? ?? '').isEmpty) {
      try {
        final about = await apiJson(
          endpoints.drive
              .resolve('about')
              .replace(
                queryParameters: {
                  'fields': 'user(displayName,photoLink,emailAddress)',
                },
              ),
        );
        if (!connected || generation != _authorizationGeneration) return;
        final user = about['user'];
        final address = user is Map ? user['emailAddress'] : null;
        if (address is String &&
            email.isNotEmpty &&
            address.toLowerCase() == email.toLowerCase()) {
          if ((profile['name'] as String? ?? '').isEmpty &&
              user['displayName'] is String) {
            profile['name'] = user['displayName'];
          }
          if ((profile['picture'] as String? ?? '').isEmpty &&
              user['photoLink'] is String) {
            profile['picture'] = user['photoLink'];
          }
        }
      } catch (_) {
        // Retry transient failures during maintenance, while successful responses
        // with legitimately absent claims are complete for this session.
        retryProfile = true;
      }
    }
    if (!connected || generation != _authorizationGeneration) return;
    final saved = {..._tokens!, ...profile};
    await _saveTokens(saved, generation);
    if (!connected || generation != _authorizationGeneration) return;
    _tokens = saved;
    _profileLoaded = !retryProfile;
  }

  Future<String> accessToken({bool forceRefresh = false}) async {
    if (!connected || client == null) {
      throw StateError('Connect your Google account first.');
    }
    if (!forceRefresh &&
        (_tokens!['expires_at'] as int) >
            DateTime.now().millisecondsSinceEpoch + 60000) {
      return _tokens!['access_token'] as String;
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    if (_viaGranola) return _refreshGranola();
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
    if (_disconnecting || _closed || generation != _authorizationGeneration) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Google connection changed during refresh',
      );
    }
    final saved = {
      ..._tokens!,
      ...token,
      'expires_at':
          DateTime.now().millisecondsSinceEpoch +
          (token['expires_in'] as num).toInt() * 1000,
    };
    await _saveTokens(saved, generation);
    if (generation != _authorizationGeneration) {
      throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
    }
    _tokens = saved;
    return saved['access_token'] as String;
  }

  Future<Uint8ListResponse> api(
    Uri uri, {
    int maximumBytes = 32 * 1024 * 1024,
  }) async {
    if (_viaGranola) {
      throw StateError(
        'This connection supports Calendar through Granola. Drive is unavailable.',
      );
    }
    var response = await request(
      uri,
      bearer: await accessToken(),
      maximumBytes: maximumBytes,
    );
    if (response.status == 401) {
      response = await request(
        uri,
        bearer: await accessToken(forceRefresh: true),
        maximumBytes: maximumBytes,
      );
    }
    if (response.status < 200 || response.status >= 300) {
      _json(response);
    }
    return response;
  }

  Future<Map<String, dynamic>> apiJson(Uri uri) async => _json(await api(uri));

  /// Forget every account immediately; remote revocation cannot gate local erasure.
  Future<void> forget() {
    _authorizationGeneration++;
    cancelSignIn();
    final existing = _forgetting;
    if (existing != null) return existing;
    final saved = [if (_tokens != null) _tokens!, ..._savedAccounts.values];
    // Commit key-only retry work before discarding the account registry.
    final cleanupKeys = {
      for (final data in saved)
        _credentialKey(data): data['provider'] != 'granola',
      _secretKey: saved.any(
        (data) =>
            _credentialKey(data) == _secretKey && data['provider'] != 'granola',
      ),
    };
    Object? journalError;
    try {
      _cleanup.add(cleanupKeys);
    } catch (error) {
      // A storage failure must not leave cleared accounts usable in memory.
      // Keep the known keys for another durable attempt on the credential queue.
      journalError = error;
    }
    final file = File('${directory.path}/tokens.json');
    if (file.existsSync()) file.deleteSync();
    _tokens = null;
    _persistedActive = null;
    _savedAccounts.clear();
    _resetActiveWork();
    return _forgetting = _changeCredential(() async {
      for (final data in saved) {
        if (data['provider'] != 'granola' && data['refresh_token'] is String) {
          final token = data['refresh_token'] as String;
          await _revokeBestEffort(token);
        }
      }
      if (journalError != null) {
        try {
          _cleanup.add(cleanupKeys);
          journalError = null;
        } catch (error) {
          journalError = error;
        }
      }
      // Even persistent journal I/O failure must not prevent local deletion.
      // retry retains unsuccessful journal commits in memory for maintenance.
      try {
        await _cleanup.retry(
          revoke: _revokeBestEffort,
          activeKeys: _activeCredentialKeys,
        );
      } catch (_) {
        if (journalError != null) throw journalError!;
        rethrow;
      }
      if (journalError != null) throw journalError!;
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

  @override
  Future<void> disconnect() async {
    if (account.isNotEmpty) await signOutAccount(account);
    await retryCredentialCleanup();
  }

  @override
  Future<void> signOutAccount(String id) async {
    final data = id == account ? _tokens : _savedAccounts[id];
    if (data == null) throw StateError('Google account is not saved');
    if (_disconnecting) {
      throw RpcError(RpcErrorCode.busy, 'Google account change in progress');
    }
    cancelSignIn();
    final generation = ++_authorizationGeneration;
    _disconnecting = true;
    try {
      await _changeCredential(() async {
        final token = await _refreshCredential(data);
        if (token != null && !_viaGranola) {
          final response = await request(
            endpoints.revoke,
            method: 'POST',
            form: {'token': token},
          );
          if (response.status != 200 && response.status != 400) {
            throw StateError(
              'Google could not revoke the connection. Retry disconnect.',
            );
          }
        }
        final inactive = Map<String, Map<String, dynamic>>.from(_savedAccounts)
          ..remove(id);
        Map<String, dynamic>? next = _persistedActive;
        if (id == account) {
          next = inactive.isEmpty ? null : inactive.values.first;
          if (next != null) inactive.remove(next['account_sub']);
        }
        // Queue erasure before committing the registry change. A failed
        // registry write leaves the still-active key protected from retry.
        // Remote revocation above has already settled for this account.
        _cleanup.add({
          _credentialKey(data): false,
          if (data['refresh_token_legacy'] == true) _secretKey: false,
        });
        await _saveRegistry(next, inactive, generation);
        _tokens = next == null ? null : Map<String, dynamic>.from(next);
        _persistedActive = next;
        _savedAccounts
          ..clear()
          ..addAll(inactive);
        _resetActiveWork();
        await _cleanup.retry(
          revoke: _revokeBestEffort,
          activeKeys: _activeCredentialKeys,
        );
      });
    } finally {
      _disconnecting = false;
    }
  }

  @override
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
