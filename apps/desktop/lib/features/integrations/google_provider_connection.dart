import 'package:flutter/material.dart';

import 'package:foresight_core/desktop.dart';

import '../../shell/ports.dart' show FeatureHost;
import 'google_sign_in_dialog.dart';

Future<bool> selectGoogleProvider(
  FeatureHost host, {
  required bool throughGranola,
}) async {
  final connection = host.connection;
  final googleAuth = connection.googleAuth;
  final granolaCalendar = connection.googlePresentation.provider == 'granola';
  if (granolaCalendar == throughGranola) return true;
  final accounts = googleAuth.accounts;
  if (accounts.isNotEmpty) {
    final switchProvider = await showDialog<bool>(
      context: host.context,
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
    if (switchProvider != true || !host.mounted) return false;
    for (final account in accounts) {
      await googleAuth.signOutAccount(account.id);
      if (!host.mounted) return false;
    }
  }
  // The service publishes provider status before returning the reply.
  await connection.command(Operation.googleConfigure, {
    'provider': throughGranola ? 'granola' : 'google',
  });
  if (!host.mounted) return false;
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
              await connection.command(Operation.googleCompleteSignIn, {
                'url': url,
                'manual': true,
              });
            }
          : null,
    ),
  );
}
