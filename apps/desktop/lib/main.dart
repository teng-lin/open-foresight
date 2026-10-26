import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/desktop_bootstrap.dart';

import 'app_theme.dart';
import 'application.dart';
import 'commands.dart';
import 'desktop_environment.dart';

export 'application.dart' show Foresight, Workspace, WorkspaceTestAccess;

ApplicationRuntimeBootstrap? _desktopRuntime;
LoggingSession? _desktopDiagnostics;
final _desktopDiagnosticSupport = LocalDiagnosticSupport.platform();
Future<void>? _quittingDesktop;

Future<void> _prepareDesktopRuntime() async {
  final runtime = _desktopRuntime ??= ApplicationRuntimeBootstrap.prepare(
    DiagnosticHost.desktop,
  );
  _desktopDiagnostics ??= await runtime.startDiagnostics();
  _desktopDiagnosticSupport.attachSession(_desktopDiagnostics!);
}

Future<void> main([List<String> arguments = const []]) async {
  if (DiagnosticWorkerInvocation.parse(arguments).kind !=
          DiagnosticWorkerInvocationKind.absent ||
      arguments.any(
        (argument) => argument.startsWith('--model-transport-worker'),
      )) {
    exit(64);
  }
  Object? bootstrapFailure;
  try {
    await _prepareDesktopRuntime();
  } catch (error) {
    bootstrapFailure = error;
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    DesktopStartup(
      arguments: arguments,
      environment: DesktopEnvironment.production().withDiagnosticSupport(
        _desktopDiagnosticSupport,
      ),
      prepareRuntime: _prepareDesktopRuntime,
      bootstrapFailure: bootstrapFailure,
    ),
  );
}

Future<DesktopConnection> connectDesktopDomain(ProfilePaths profile) =>
    connectDesktop(profile);
void quitDesktop() {
  // This callback is for startup forwarding/failure before a workspace owns
  // application resources. Normal workspace cleanup keeps its existing owner.
  unawaited(
    _quittingDesktop ??= () async {
      await _desktopDiagnostics?.close();
      exit(0);
    }(),
  );
}

/// Mount before connecting so service/profile failures remain visible and can
/// be retried without retaining the failed attempt's activation socket.
class DesktopStartup extends StatefulWidget {
  final DesktopEnvironment environment;
  final List<String> arguments;
  final ProfilePaths? profile;
  final Future<DesktopConnection> Function(ProfilePaths) connect;
  final VoidCallback quit;
  final void Function(String) configureRuntime;
  final Future<List<AudioDevice>> Function()? deviceLoader;
  final Future<void> Function()? prepareRuntime;
  final Object? bootstrapFailure;
  const DesktopStartup({
    super.key,
    required this.environment,
    this.arguments = const [],
    this.profile,
    this.connect = connectDesktopDomain,
    this.quit = quitDesktop,
    this.configureRuntime = configureProfileRuntime,
    this.deviceLoader,
    this.prepareRuntime,
    this.bootstrapFailure,
  });
  @override
  State<DesktopStartup> createState() => _DesktopStartupState();
}

class _DesktopStartupState extends State<DesktopStartup> {
  Widget? application;
  Object? failure;
  bool starting = false;

  @override
  void initState() {
    super.initState();
    if (widget.bootstrapFailure case final failure?) {
      this.failure = failure;
    } else {
      unawaited(start());
    }
  }

  Future<void> start() async {
    if (starting) return;
    setState(() {
      starting = true;
      failure = null;
    });
    AppCommands? ownedCommands;
    try {
      await widget.prepareRuntime?.call();
      final profile =
          widget.profile ?? ProfilePaths.resolve(widget.environment.variables);
      privateDirectory(profile.data, repairOwnedPermissions: true);
      privateRuntime(profile);
      widget.configureRuntime(profile.data);
      _desktopDiagnostics?.selectProfile(profile.data);
      _desktopDiagnosticSupport.selectProfile(profile);
      final commandPath = '${profile.runtime}/commands.sock';
      final authUrl = widget.arguments
          .where(
            (argument) =>
                argument.startsWith('open-foresight://login-in-progress?'),
          )
          .firstOrNull;
      final launchCommand = authUrl != null
          ? 'calendar-auth'
          : widget.arguments.contains('--stop-meeting')
          ? 'stop-meeting'
          : widget.arguments.contains('--quick-meeting')
          ? 'quick-meeting'
          : 'activate';
      if (await AppCommands.forward(
        commandPath,
        command: launchCommand,
        authUrl: authUrl,
        activationToken: widget.environment.variables['XDG_ACTIVATION_TOKEN'],
      )) {
        widget.quit();
        return;
      }
      // Sign-in attempts are memory-bound to the running desktop/service.
      // Do not launch a fresh workspace with an unsolicited or stale callback.
      if (launchCommand == 'stop-meeting' || launchCommand == 'calendar-auth') {
        widget.quit();
        return;
      }
      try {
        ownedCommands = await AppCommands.bind(
          commandPath,
          environment: widget.environment,
        );
      } catch (error) {
        if (error is! SocketException && error is! FileSystemException) rethrow;
        if (await AppCommands.forward(commandPath, command: launchCommand)) {
          widget.quit();
          return;
        }
        rethrow;
      }
      final domain = await widget.connect(profile);
      if (!mounted) {
        await ownedCommands.close();
        ownedCommands = null;
        domain.close();
        return;
      }
      setState(
        () => application = Foresight(
          domain,
          commands: ownedCommands,
          environment: widget.environment,
          deviceLoader: widget.deviceLoader,
          quickOnLaunch: widget.arguments.contains('--quick-meeting'),
        ),
      );
      ownedCommands = null; // Workspace now owns the successful connection.
    } catch (error) {
      // Cleanup finishes before Retry becomes available or another app binds.
      try {
        await ownedCommands?.close();
      } catch (_) {
        // Preserve the actionable connection error if cleanup also fails.
      }
      if (mounted) setState(() => failure = error);
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      application ??
      MaterialApp(
        title: 'Open Foresight',
        debugShowCheckedModeBanner: false,
        theme: foresightTheme(),
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      starting
                          ? 'Starting Open Foresight…'
                          : 'Open Foresight could not start',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    if (starting)
                      const LinearProgressIndicator()
                    else ...[
                      SelectableText(failure.toString()),
                      const SizedBox(height: 16),
                      const Text(
                        'Resolve the problem above, then retry. If another installation owns this profile, stop its application service explicitly or use a different profile.',
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          FilledButton(
                            onPressed: start,
                            child: const Text('Retry'),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: widget.quit,
                            child: const Text('Quit'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
