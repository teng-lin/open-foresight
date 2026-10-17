// Verify the packaged browser invitation without an account or Google API calls.
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/google_auth.dart';

Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('foresight-google-config-');
  final profile = Directory('${root.path}/google');
  final auth = GoogleAuth(profile);
  var invited = false;
  try {
    if (auth.client == null || auth.loadError.isNotEmpty) {
      throw StateError(
        'Packaged Google application registration is missing or invalid',
      );
    }
    try {
      await auth.signIn((uri) async {
        final params = uri.queryParameters;
        invited =
            uri.origin == 'https://accounts.google.com' &&
            params['client_id'] == auth.client!.id &&
            params['code_challenge_method'] == 'S256' &&
            params['state']!.isNotEmpty &&
            params['scope']!
                .split(' ')
                .toSet()
                .containsAll(GoogleAuth.scopes) &&
            Uri.parse(params['redirect_uri']!).host == '127.0.0.1';
        auth.cancelSignIn();
      });
    } on StateError {
      if (!invited) rethrow;
    }
    if (!invited || auth.connected || auth.signingIn || profile.existsSync()) {
      throw StateError('Packaged Google browser invitation failed');
    }
    stdout.writeln(
      jsonEncode({
        'status': 'passed',
        'application_configured': true,
        'browser_invitation_verified': true,
        'account_authorized': false,
        'account_state_created': false,
      }),
    );
  } finally {
    await auth.close();
    root.deleteSync(recursive: true);
  }
}
