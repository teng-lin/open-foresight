import 'package:foresight_core/desktop.dart'
    show GoogleAccount, RpcError, GranolaReturnFailure;
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
    this.returnToApp,
    this.addAccount = false,
    this.calendarThroughGranola = false,
    this.completeSignIn,
  });
  final GoogleAccount auth;
  final Future<void> Function(Uri) openBrowser;
  final Future<void> Function()? returnToApp;
  final bool addAccount;
  final bool calendarThroughGranola;
  final Future<void> Function(String)? completeSignIn;

  @override
  State<GoogleSignInDialog> createState() => _GoogleSignInDialogState();
}

class _GoogleSignInDialogState extends State<GoogleSignInDialog> {
  bool cancelling = false;
  bool browserOpened = false;
  bool finished = false;
  bool submittingReturn = false;
  String returnError = '';
  final returnUrl = TextEditingController();

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
      final authenticate = widget.addAccount
          ? widget.auth.addAccount
          : widget.auth.signIn;
      await authenticate((uri) async {
        if (cancelling || !mounted) {
          widget.auth.cancelSignIn();
          return;
        }
        await widget.openBrowser(uri);
        if (mounted) setState(() => browserOpened = true);
      });
      if (widget.auth.connected && mounted) {
        // Focus failure must not discard an otherwise successful account login.
        try {
          await widget.returnToApp?.call();
        } catch (_) {
          // Desktop focus policies may refuse activation; login still succeeded.
        }
      }
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
    if (mounted) {
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        final navigator = Navigator.of(context);
        if (route.isCurrent) {
          navigator.pop(outcome);
        } else {
          navigator.removeRoute(route, outcome);
        }
      }
    }
  }

  Future<void> submitReturn() async {
    if (submittingReturn ||
        cancelling ||
        finished ||
        widget.completeSignIn == null)
      return;
    final url = returnUrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      submittingReturn = true;
      returnError = '';
    });
    try {
      await widget.completeSignIn!(url);
      if (mounted) returnUrl.clear();
    } catch (error) {
      // Callback URLs contain codes. Never echo them or transport error bodies.
      final message = switch (error) {
        RpcError() => error.message,
        StateError() => error.message.toString(),
        _ => null,
      };
      if (mounted)
        setState(
          () => returnError =
              GranolaReturnFailure.values.any(
                (failure) => failure.message == message,
              )
              ? message!
              : 'The return link was not accepted. Use the link from this sign-in attempt, or cancel and sign in again.',
        );
    } finally {
      if (mounted) setState(() => submittingReturn = false);
    }
  }

  void cancel() {
    if (cancelling || finished) return;
    setState(() => cancelling = true);
    widget.auth.cancelSignIn();
  }

  @override
  void dispose() {
    if (!finished) widget.auth.cancelSignIn();
    returnUrl.dispose();
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
        title: Text(
          widget.addAccount
              ? 'Add another account'
              : widget.calendarThroughGranola
              ? 'Connect Calendar through Granola'
              : 'Connect Google',
        ),
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
                    ? 'Complete Google sign-in in your browser. If Open Foresight does not reopen, return to the app manually.'
                    : 'Opening Google sign-in in your browser…',
              ),
              if (widget.calendarThroughGranola) ...[
                const SizedBox(height: 12),
                const Text(
                  'Granola handles sign-in and calendar data. Drive is unavailable with this connection.',
                ),
              ],
              if (widget.calendarThroughGranola &&
                  widget.completeSignIn != null) ...[
                const SizedBox(height: 16),
                const Text(
                  'If the browser opens Granola, paste the full https://www.granola.ai/app-redirect or granola://login-complete return link from this sign-in here.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: returnUrl,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [],
                  maxLength: 16384,
                  enabled: !cancelling && !submittingReturn,
                  decoration: const InputDecoration(
                    labelText: 'Return URL from browser',
                    counterText: '',
                  ),
                  onSubmitted: (_) => submitReturn(),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: cancelling || submittingReturn
                      ? null
                      : submitReturn,
                  child: Text(
                    submittingReturn
                        ? 'Submitting return link…'
                        : 'Complete sign-in with return URL',
                  ),
                ),
                if (returnError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(returnError),
                  ),
              ],
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
