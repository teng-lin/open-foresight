import 'package:foresight_core/remote.dart' show DesktopConnection, GenerationStatus, RecordingStatus, GoogleAccount, ConnectedSources;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GoogleSignInOutcome {
  const GoogleSignInOutcome({
    this.cancelled = false,
    this.error,
    this.stackTrace,
  });
  final bool cancelled;
  final Object? error;
  final StackTrace? stackTrace;
}

/// All entry points keep cancellation reachable while browser consent is open.
/// Wait for auth cleanup before dismissing, so retry cannot race the listener.
class GoogleSignInDialog extends StatefulWidget {
  const GoogleSignInDialog({
    super.key,
    required this.auth,
    required this.openBrowser,
  });
  final GoogleAccount auth;
  final Future<void> Function(Uri) openBrowser;

  @override
  State<GoogleSignInDialog> createState() => _GoogleSignInDialogState();
}

class _GoogleSignInDialogState extends State<GoogleSignInDialog> {
  bool cancelling = false;
  bool browserOpened = false;
  bool finished = false;

  @override
  void initState() {
    super.initState();
    // A synchronous auth failure must not pop the route while it is building.
    WidgetsBinding.instance.addPostFrameCallback((_) => signIn());
  }

  Future<void> signIn() async {
    if (!mounted) return;
    GoogleSignInOutcome outcome;
    try {
      await widget.auth.signIn((uri) async {
        if (cancelling || !mounted) {
          widget.auth.cancelSignIn();
          return;
        }
        await widget.openBrowser(uri);
        if (mounted) setState(() => browserOpened = true);
      });
      // If consent already completed before Cancel, retain the actual account
      // outcome rather than presenting a connected account as cancelled.
      outcome = GoogleSignInOutcome(
        cancelled: cancelling && !widget.auth.connected,
      );
    } catch (error, stackTrace) {
      outcome = GoogleSignInOutcome(
        cancelled: cancelling,
        error: cancelling ? null : error,
        stackTrace: cancelling ? null : stackTrace,
      );
    }
    finished = true;
    if (mounted) Navigator.of(context).pop(outcome);
  }

  void cancel() {
    if (cancelling || finished) return;
    setState(() => cancelling = true);
    widget.auth.cancelSignIn();
  }

  @override
  void dispose() {
    if (!finished) widget.auth.cancelSignIn();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): cancel},
    child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) cancel();
      },
      child: AlertDialog(
        title: const Text('Connect Google'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                cancelling
                    ? 'Cancelling Google sign-in…'
                    : browserOpened
                    ? 'Complete Google sign-in in your browser, then return here.'
                    : 'Opening Google sign-in in your browser…',
              ),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: cancelling ? null : cancel,
            child: const Text('Cancel sign-in'),
          ),
        ],
      ),
    ),
  );
}
