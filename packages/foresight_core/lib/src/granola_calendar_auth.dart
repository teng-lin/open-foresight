part of 'google_auth.dart';

// Use Granola's macOS client profile consistently, including on Linux hosts.
const _granolaPlatform = 'macOS';

/// Fixed production service; injectable only by callers constructing an auth
/// instance (tests). No credentials or private WorkOS project keys are needed.
class GranolaEndpoints {
  final Uri base;
  GranolaEndpoints({Uri? base})
    : base = base ?? Uri.parse('https://api.granola.ai/v1/');
}

/// Fixed messages are safe to show across the service boundary. No callback
/// data or remote response bodies may be incorporated into these messages.
enum GranolaReturnFailure {
  noAttempt(
    'No Granola calendar sign-in is waiting. Start a new sign-in and keep its dialog open.',
  ),
  tooLong('The return link exceeds the supported length.'),
  wrongAddress(
    'Paste the Granola return link beginning https://www.granola.ai/app-redirect or granola://login-complete.',
  ),
  wrongState(
    'This return link belongs to a different Foresight sign-in attempt.',
  ),
  missingReturn('This return link does not contain a sign-in completion.'),
  malformed('The return link could not be parsed.'),
  missingCode(
    'The completion link must contain exactly one non-empty sign-in code.',
  ),
  unsupportedFlow(
    'This link finishes a Granola SSO or calendar-linking flow that this connection does not support yet.',
  ),
  wrongAttempt(
    'This completion link belongs to a different sign-in attempt. Use the new link from the current sign-in.',
  );

  const GranolaReturnFailure(this.message);
  final String message;
}

extension _GranolaAuthorization on GoogleAuth {
  Future<void> _configureGranola() async {
    if (_closed || _disconnecting || _forgetting != null || signingIn) {
      throw StateError('Finish the current Google connection operation first.');
    }
    if (accounts.isNotEmpty) {
      throw StateError(
        'Sign out of saved accounts before changing connection providers.',
      );
    }
    // Keep direct OAuth recoverable, including custom clients and restarts.
    if (!_viaGranola && client != null) {
      await _save('google-client.json', client!.toJson());
    }
    await _save('client.json', {'provider': 'granola'});
    _viaGranola = true;
    client = GoogleClient('granola', '');
    loadError = '';
  }

  /// Automatic returns require Foresight's own scheme and random envelope state.
  /// Explicit manual pastes may supply a Granola link; the service must bind its
  /// code to the active Foresight attempt's verifier.
  void _completeGranolaSignIn(Uri uri, {required bool manual}) {
    final pending = _authorization;
    if (!_viaGranola ||
        pending == null ||
        pending.isCompleted ||
        _granolaNonce == null) {
      throw StateError(GranolaReturnFailure.noAttempt.message);
    }
    if (uri.toString().length > 16384) {
      throw StateError(GranolaReturnFailure.tooLong.message);
    }
    Uri? callback;
    if (manual &&
        uri.scheme.isEmpty &&
        uri.toString().toLowerCase().startsWith('granola%3a')) {
      try {
        final decoded = Uri.tryParse(Uri.decodeComponent(uri.toString()));
        if (decoded == null) throw const FormatException();
        uri = decoded;
      } on FormatException {
        throw StateError(GranolaReturnFailure.malformed.message);
      }
    }
    if (manual &&
        uri.scheme == 'https' &&
        uri.host == 'www.granola.ai' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        (uri.path == '/app-redirect' || uri.path == '/app-redirect/')) {
      // Granola's public app-redirect page forwards these query fields to the
      // native login-complete link. Preserve every value and duplicate here;
      // validation below rejects ambiguous authentication parameters. Never
      // fetch the supplied URL or send its code to another origin.
      callback = Uri(
        scheme: 'granola',
        host: 'login-complete',
        queryParameters: uri.queryParametersAll,
      );
    } else if (manual && uri.scheme == 'granola') {
      // Explicit paste does not register or intercept Granola's scheme. The
      // service must accept the code with THIS active attempt's app verifier.
      callback = uri;
    } else {
      if (uri.scheme != 'open-foresight' ||
          uri.host != 'login-in-progress' ||
          uri.path.isNotEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort) {
        throw StateError(GranolaReturnFailure.wrongAddress.message);
      }
      if (uri.queryParametersAll['foresight_state']?.length != 1 ||
          uri.queryParameters['foresight_state'] != _granolaNonce) {
        throw StateError(GranolaReturnFailure.wrongState.message);
      }
      final nested = uri.queryParameters['open-url'];
      if (nested == null || uri.queryParametersAll['open-url']?.length != 1) {
        throw StateError(GranolaReturnFailure.missingReturn.message);
      }
      try {
        final decoded =
            nested.startsWith('granola%3A') ||
                nested.startsWith('%2Flogin-complete')
            ? Uri.decodeComponent(nested)
            : nested;
        callback = Uri.tryParse(decoded);
      } on FormatException {
        throw StateError(GranolaReturnFailure.malformed.message);
      }
      if (callback == null) {
        throw StateError(GranolaReturnFailure.malformed.message);
      }
      if (callback.scheme.isEmpty && callback.path == '/login-complete') {
        callback = callback.replace(
          scheme: 'granola',
          host: 'login-complete',
          path: '',
        );
      }
    }
    // Browsers may copy the authority with a trailing slash. Granola's shipped
    // parser dispatches on hostname; this slash carries no different action.
    if (callback.scheme != 'granola' ||
        callback.host != 'login-complete' ||
        (callback.path.isNotEmpty && callback.path != '/') ||
        callback.userInfo.isNotEmpty ||
        callback.hasPort) {
      throw StateError(GranolaReturnFailure.wrongAddress.message);
    }
    const authenticationFields = [
      'isDev',
      'sso',
      'ssoCode',
      'authContext',
      'inAppCalendarLinking',
      'calendarLinkingFlow',
      'signInClickId',
    ];
    if (authenticationFields.any(
      (key) => (callback!.queryParametersAll[key]?.length ?? 0) > 1,
    )) {
      throw StateError(GranolaReturnFailure.malformed.message);
    }
    if (callback.queryParametersAll['code']?.length != 1 ||
        (callback.queryParameters['code'] ?? '').isEmpty) {
      throw StateError(GranolaReturnFailure.missingCode.message);
    }
    if (callback.queryParameters['isDev'] == 'true' ||
        callback.queryParameters['sso'] == 'true' ||
        callback.queryParameters['calendarLinkingFlow'] == 'true') {
      throw StateError(GranolaReturnFailure.unsupportedFlow.message);
    }
    if (callback.queryParameters.containsKey('signInClickId') &&
        (callback.queryParametersAll['signInClickId']?.length != 1 ||
            callback.queryParameters['signInClickId'] !=
                _granolaSignInClickId)) {
      throw StateError(GranolaReturnFailure.wrongAttempt.message);
    }
    pending.complete(callback.toString());
  }

  Future<Map<String, dynamic>> _granolaPost(
    String operation, {
    Map<String, dynamic> body = const {},
    String? bearer,
  }) async {
    const allowed = {
      'workos-auth-complete',
      'get-user-info',
      'refresh-access-token',
      'refresh-calendar-events',
      'get-selected-calendars',
    };
    if (!allowed.contains(operation)) {
      throw StateError('Unsupported calendar service operation');
    }
    final response = await request(
      granolaEndpoints.base.resolve(operation),
      method: 'POST',
      bearer: bearer,
      jsonBody: body,
    );
    if (response.status < 200 || response.status >= 300) {
      // Never include response bodies, callback codes, or credentials in errors.
      throw StateError(
        'Granola calendar service failed (HTTP ${response.status}).',
      );
    }
    final dynamic value;
    try {
      value = jsonDecode(utf8.decode(response.bytes));
    } on FormatException {
      throw StateError('Invalid Granola calendar response.');
    }
    if (value is! Map<String, dynamic>) {
      throw StateError('Invalid Granola calendar response.');
    }
    return value;
  }

  Map<String, dynamic> _granolaTokens(Map<String, dynamic> token) {
    if (token['access_token'] is! String ||
        (token['access_token'] as String).isEmpty ||
        token['refresh_token'] is! String ||
        (token['refresh_token'] as String).isEmpty ||
        token['expires_in'] is! num ||
        (token['expires_in'] as num) <= 0 ||
        token['token_type'] is! String) {
      throw StateError(
        'Granola did not return a persistent application session.',
      );
    }
    return {
      ...token,
      'provider': 'granola',
      'expires_at':
          DateTime.now().millisecondsSinceEpoch +
          (token['expires_in'] as num).toInt() * 1000,
    };
  }

  Map<String, dynamic> _granolaIdentity(Map<String, dynamic> identity) {
    if (identity['id'] is! String ||
        (identity['id'] as String).isEmpty ||
        identity['email'] is! String) {
      throw StateError('Granola did not return an account identity.');
    }
    final metadata = identity['user_metadata'] is Map
        ? identity['user_metadata'] as Map
        : const {};
    final name = [
      identity['first_name'],
      identity['last_name'],
    ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    return {
      'account_sub': identity['id'],
      'email': identity['email'],
      'name':
          identity['name'] as String? ?? metadata['name'] as String? ?? name,
      'picture':
          identity['profile_picture_url'] as String? ??
          metadata['avatar_url'] as String? ??
          '',
    };
  }

  Future<void> _authorizeGranola(
    Future<void> Function(Uri) openBrowser, {
    required bool allowConnected,
  }) async {
    if (_closed || _disconnecting || _forgetting != null) {
      throw StateError('Google connection is unavailable.');
    }
    if (connected && !allowConnected) {
      throw StateError('This account is already connected.');
    }
    if (signingIn) {
      throw RpcError(RpcErrorCode.busy, 'Google sign-in is already open.');
    }
    var generation = _authorizationGeneration;
    final verifier = _random(32), nonce = _random(32);
    final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final clickId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final pending = Completer<String>();
    _authorization = pending;
    _granolaNonce = nonce;
    _granolaSignInClickId = clickId;
    final completion = pending.future
        .timeout(const Duration(minutes: 5))
        .then<Object>((value) => value, onError: (Object error) => error);
    final redirect = Uri(
      scheme: 'open-foresight',
      host: 'login-in-progress',
      queryParameters: {'foresight_state': nonce},
    );
    try {
      await openBrowser(
        granolaEndpoints.base
            .resolve('auth')
            .replace(
              queryParameters: {
                'provider': 'google',
                'dev': 'false',
                'platform': _granolaPlatform,
                'version': '7.663.2',
                'intent': 'download',
                'sign_in_click_id': clickId,
                'redirect': redirect.toString(),
                'code_challenge': base64UrlEncode(
                  sha256.convert(utf8.encode(verifier)).bytes,
                ).replaceAll('=', ''),
                'select_account': 'true',
                'max_age': '0',
              },
            ),
      );
      final returned = await completion;
      if (returned is! String) throw returned;
      final params = Uri.parse(returned).queryParameters;
      final result = await _granolaPost(
        'workos-auth-complete',
        body: {
          'code': params['code'],
          'codeVerifier': verifier,
          'isDev': false,
          'platform': _granolaPlatform,
          'signInClickId': clickId,
          'sso': false,
          'ssoCode': '',
          if (params['authContext'] != null)
            'authContext': params['authContext'],
          if (params['inAppCalendarLinking'] != null)
            'inAppCalendarLinking': params['inAppCalendarLinking'] == 'true',
        },
      );
      if (result['status'] == 'verification_required') {
        throw StateError(
          'Granola requires additional email verification. This experimental connection cannot complete that flow yet.',
        );
      }
      if (result['tokens'] is! Map) {
        throw StateError('Granola did not return a session.');
      }
      final token = _granolaTokens(
        Map<String, dynamic>.from(result['tokens'] as Map),
      );
      final identity = _granolaIdentity(
        await _granolaPost(
          'get-user-info',
          bearer: token['access_token'] as String,
        ),
      );
      final saved = {...token, ...identity};
      if (_closed ||
          generation != _authorizationGeneration ||
          !identical(_authorization, pending)) {
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      }
      generation = ++_authorizationGeneration;
      await _saveTokens(saved, generation);
      if (_closed || generation != _authorizationGeneration) {
        throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
      }
      _tokens = saved;
      _resetActiveWork();
      _profileLoaded = true;
      loadError = '';
    } finally {
      if (!pending.isCompleted) {
        pending.completeError(
          RpcError(RpcErrorCode.cancelled, 'Google sign-in cancelled'),
        );
      }
      if (identical(_authorization, pending)) {
        _authorization = null;
        _granolaNonce = null;
        _granolaSignInClickId = null;
      }
    }
  }

  Future<String> _refreshGranola() async {
    final generation = _authorizationGeneration;
    final current = _tokens!;
    final result = await _granolaPost(
      'refresh-access-token',
      bearer: current['access_token'] as String,
      body: {'refresh_token': await _refreshCredential()},
    );
    final saved = {...current, ..._granolaTokens(result)};
    if (_closed || _disconnecting || generation != _authorizationGeneration) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Google connection changed during refresh',
      );
    }
    await _saveTokens(saved, generation);
    if (_closed || generation != _authorizationGeneration) {
      throw RpcError(RpcErrorCode.cancelled, 'Google connection changed');
    }
    _tokens = saved;
    return saved['access_token'] as String;
  }

  Future<Map<String, dynamic>> _granolaApi(String operation) async {
    try {
      return await _granolaPost(operation, bearer: await accessToken());
    } on StateError catch (error) {
      if (error.message != 'Granola calendar service failed (HTTP 401).') {
        rethrow;
      }
      return _granolaPost(
        operation,
        bearer: await accessToken(forceRefresh: true),
      );
    }
  }

  Future<void> _loadGranolaProfile() async {
    final generation = _authorizationGeneration;
    final subject = account;
    final identity = _granolaIdentity(await _granolaApi('get-user-info'));
    if (_closed || !connected || generation != _authorizationGeneration) return;
    if (identity['account_sub'] != subject) {
      throw StateError('Calendar profile account mismatch.');
    }
    final saved = {..._tokens!, ...identity};
    await _saveTokens(saved, generation);
    if (_closed || generation != _authorizationGeneration) return;
    _tokens = saved;
    _profileLoaded = true;
  }
}
