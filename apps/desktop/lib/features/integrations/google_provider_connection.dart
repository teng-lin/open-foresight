import 'package:flutter/material.dart';

import 'package:foresight_core/desktop.dart';

import '../../shell/ports.dart' show FeatureHost;
import '../../feature_request_identity.dart';
import 'google_sign_in_dialog.dart';

Future<bool> selectGoogleProvider(
  FeatureHost host, {
  required bool throughGranola,
}) async {
  final connection = host.connection;
  final identity = FeatureRequestIdentity.capture(connection);
  bool current() => identity.isCurrent(host.connection, alive: host.mounted);
  final googleAuth = connection.googleAuth;
  final granolaCalendar = connection.googlePresentation.provider == 'granola';
  if (granolaCalendar == throughGranola) return current();
  if (!throughGranola) {
    if (!current()) return false;
    // Validate the target before asking to sign out the working connection.
    await googleConfigureDescriptor.sendCurrent(
      connection,
      GoogleConfigureInput(
        provider: WireField('google'),
        checkOnly: WireField(true),
      ),
      current,
    );
    if (!current()) return false;
  }
  final accounts = googleAuth.accounts;
  if (accounts.isNotEmpty) {
    final context = host.context;
    if (!context.mounted) return false;
    final switchProvider = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          throughGranola
              ? 'Switch calendar connection to Granola?'
              : 'Switch connection to Google?',
        ),
        content: Text(
          throughGranola
              ? 'Granola provides Calendar only. Switching signs out all saved Google accounts in Foresight and stops Drive sync. Imported documents remain on this computer. You will then sign in through Granola, which processes authorization and calendar data.'
              : 'Switching signs out all saved Granola accounts in Foresight. You will then sign in directly with Google for Drive and Calendar access. Imported documents remain on this computer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out and switch'),
          ),
        ],
      ),
    );
    if (switchProvider != true || !current()) return false;
    for (final account in accounts) {
      await googleAuth.signOutAccount(account.id);
      if (!current()) return false;
    }
  }
  // The service publishes provider status before returning the reply.
  if (!current()) return false;
  await googleConfigureDescriptor.sendCurrent(
    connection,
    GoogleConfigureInput(
      provider: WireField(throughGranola ? 'granola' : 'google'),
    ),
    current,
  );
  if (!current()) return false;
  return true;
}

Future<GoogleSignInOutcome?> signInGoogleProvider(
  FeatureHost host,
  Future<void> Function() returnToApp, {
  bool addAccount = false,
}) {
  final connection = host.connection;
  final auth = connection.googleAuth;
  final throughGranola = connection.googlePresentation.provider == 'granola';
  if (!auth.configured) {
    throw StateError(
      'Google sign-in is unavailable in this build. Install a distribution with Google sign-in included.',
    );
  }
  return showDialog<GoogleSignInOutcome>(
    context: host.context,
    barrierDismissible: false,
    builder: (_) => GoogleSignInDialog(
      auth: auth,
      openBrowser: host.environment.openUri,
      returnToApp: returnToApp,
      addAccount: addAccount,
      calendarThroughGranola: throughGranola,
      completeSignIn: throughGranola
          ? (url) async {
              await googleCompleteSignInDescriptor.send(
                connection,
                GoogleCompleteSignInInput(url: url, manual: WireField(true)),
              );
            }
          : null,
    ),
  );
}
