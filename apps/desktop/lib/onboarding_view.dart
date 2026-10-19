import 'package:flutter/material.dart';
import 'app_theme.dart';

/// First-run navigation. Model installers retain their Settings behavior,
/// including checksum verification, cancellation, and local-file reuse.
class OnboardingView extends StatefulWidget {
  final int initialStep;
  final bool runtimeReady;
  final bool externalBusy;
  final String runtimeError;
  final Future<void> Function() retryRuntime;
  final Future<void> Function(int) saveStep;
  final Future<void> Function() complete;
  final Widget Function(VoidCallback) generation, transcription;
  final WidgetBuilder permissions, imports, library;
  final Future<bool> Function() connectGoogle;
  final bool googleConnected;
  final String googleEmail;
  const OnboardingView({
    super.key,
    this.initialStep = 0,
    required this.runtimeReady,
    this.externalBusy = false,
    this.runtimeError = '',
    required this.retryRuntime,
    required this.saveStep,
    required this.complete,
    required this.generation,
    required this.transcription,
    required this.permissions,
    required this.imports,
    required this.library,
    required this.connectGoogle,
    required this.googleConnected,
    required this.googleEmail,
  });

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  late int step = widget.initialStep.clamp(0, 5);
  bool working = false;
  String error = '';
  bool get busy => working || widget.externalBusy;
  static const titles = [
    'Harness your personal knowledge with on-device AI',
    'Choose your Gemma model',
    'Choose your transcription model',
    'Set up audio and notifications',
    'Build your knowledge library',
    'Add documents manually',
  ];

  Future<void> perform(Future<void> Function() action) async {
    if (working) return;
    setState(() {
      working = true;
      error = '';
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> go(int next) => perform(() async {
    await widget.saveStep(next);
    if (mounted) setState(() => step = next);
  });

  Future<void> signIn() => perform(() async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect your Google account'),
        content: const SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Text(
              'Signing in is optional. Open Foresight requests read-only access to Google Drive and Calendar. '
              'Calendar events are synced after sign-in. You choose which Drive files to import in the next step. '
              'Syncing and importing use an internet connection; analysis and indexing run on your device.\n\n'
              'Your Google password stays in your browser. You can disconnect in Settings. '
              'Recording starts only when you start a meeting. Obtain consent from participants before recording.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue to Google'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    if (await widget.connectGoogle()) {
      await widget.saveStep(5);
      if (mounted) setState(() => step = 5);
    }
  });

  Widget button(String label, VoidCallback action) =>
      FilledButton(onPressed: busy ? null : action, child: Text(label));

  Widget body() => switch (step) {
    0 => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Connect, organize, and chat with your files. Transcribe meetings and find answers with local AI.',
          style: TextStyle(fontSize: 18, height: 1.5),
        ),
        const SizedBox(height: 32),
        button('Start Foresight', () => go(1)),
        const SizedBox(height: 40),
        const Text(
          'Setup downloads the models you choose. You can review model licenses before downloading, use existing downloads, or set up models later in Settings.',
        ),
      ],
    ),
    1 || 2 =>
      widget.runtimeReady
          ? (step == 1
                ? widget.generation(() => go(2))
                : widget.transcription(() => go(3)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Connecting to the local service…'),
                if (widget.runtimeError.isEmpty)
                  const LinearProgressIndicator(),
                if (widget.runtimeError.isNotEmpty) ...[
                  Text(widget.runtimeError),
                  button(
                    'Retry connection',
                    () => perform(widget.retryRuntime),
                  ),
                ],
              ],
            ),
    3 => widget.permissions(context),
    4 => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Connect Google Drive and Calendar to bring your knowledge together. Syncing uses the internet; analysis and processing stay on your device.',
          style: TextStyle(fontSize: 18, height: 1.5),
        ),
        const SizedBox(height: 24),
        const ListTile(
          leading: Icon(Icons.calendar_month_outlined),
          title: Text('Meetings on Google Calendar'),
          subtitle: Text('View upcoming events and connect meeting notes.'),
        ),
        const ListTile(
          leading: Icon(Icons.add_to_drive_outlined),
          title: Text('Files from Google Drive'),
          subtitle: Text('Choose files or folders to import after connecting.'),
        ),
        const SizedBox(height: 24),
        if (widget.googleConnected) ...[
          Text('Connected as ${widget.googleEmail}'),
          const SizedBox(height: 16),
          button('Continue', () => go(5)),
        ] else
          button('Sign in with Google', signIn),
        const SizedBox(height: 16),
        const Text(
          'Google sign-in is optional. You can also use local files and connect later in Settings.',
        ),
      ],
    ),
    _ => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Build your knowledge library with your own documents. Imported data is stored locally on your device.',
          style: TextStyle(fontSize: 18, height: 1.5),
        ),
        const SizedBox(height: 24),
        widget.imports(context),
        const SizedBox(height: 24),
        button('Get started', () => perform(widget.complete)),
      ],
    ),
  };

  Widget information() {
    if (step == 5) return widget.library(context);
    final (icon, title, description) = switch (step) {
      0 => (
        Icons.hub_outlined,
        'Your knowledge, connected',
        'Bring documents, notes, and meetings together on your computer.',
      ),
      1 => (
        Icons.auto_awesome_outlined,
        'What’s Gemma?',
        'Gemma generates local answers and meeting summaries. EmbeddingGemma powers local source search. Choose a model that fits your device; switch later in Settings.',
      ),
      2 => (
        Icons.graphic_eq,
        'Speech stays on your device',
        'Choose from the same multilingual Whisper models available in Settings. Models detect the spoken language automatically. Existing verified downloads are reused.',
      ),
      3 => (
        Icons.privacy_tip_outlined,
        'You control recording',
        'Microphone and system playback are used only during meetings you start. Notifications are optional. Permissions can be revisited in Settings.',
      ),
      _ => (
        Icons.folder_copy_outlined,
        'A library that works for you',
        'Add files from Drive or your computer, then ask questions with citations. Local files work without a Google account.',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 170,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xfff2f4fa),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(icon, size: 72, color: const Color(0xff006c97)),
        ),
        const SizedBox(height: 32),
        Text(
          title,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),
        Text(description, style: const TextStyle(fontSize: 17, height: 1.5)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, bounds) {
            final wide = bounds.maxWidth >= 1000;
            final left = SingleChildScrollView(
              padding: EdgeInsets.all(wide ? 48 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: ForesightBrand(),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Step ${step + 1} of 6',
                    style: const TextStyle(color: Color(0xff60646b)),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: (step + 1) / 6, minHeight: 3),
                  const SizedBox(height: 24),
                  if (step > 0)
                    TextButton.icon(
                      onPressed: busy ? null : () => go(step - 1),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                  const SizedBox(height: 16),
                  // Model installers supply their own heading and progress surface.
                  if (step != 1 && step != 2) ...[
                    Text(
                      titles[step],
                      style: const TextStyle(
                        fontSize: 36,
                        height: 1.15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 28),
                  ],
                  AbsorbPointer(absorbing: busy, child: body()),
                  if (working)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (step > 0 && step < 5) ...[
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: busy ? null : () => go(step + 1),
                      child: Text(step == 3 ? 'Continue' : 'Skip for now'),
                    ),
                  ],
                  if (!wide) ...[const SizedBox(height: 32), information()],
                ],
              ),
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: left),
                if (wide)
                  Expanded(
                    child: ColoredBox(
                      color: const Color(0xffcbe7fb),
                      child: LayoutBuilder(
                        builder: (context, panel) => SingleChildScrollView(
                          padding: const EdgeInsets.all(48),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: (panel.maxHeight - 96).clamp(
                                0,
                                double.infinity,
                              ),
                            ),
                            child: Align(
                              alignment: Alignment.center,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 640,
                                ),
                                child: Container(
                                  key: const ValueKey(
                                    'onboarding-information-card',
                                  ),
                                  padding: const EdgeInsets.all(32),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                  child: information(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
