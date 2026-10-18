import 'dart:async';
import 'package:flutter/material.dart';
import 'package:foresight_core/remote.dart';

/// The service can authorize agent operations only while this surface is alive.
class AgentApprovalSurface extends StatefulWidget {
  final DesktopConnection domain;
  final Widget child;
  const AgentApprovalSurface({
    super.key,
    required this.domain,
    required this.child,
  });
  @override
  State<AgentApprovalSurface> createState() => _AgentApprovalSurfaceState();
}

class _AgentApprovalSurfaceState extends State<AgentApprovalSurface>
    with WidgetsBindingObserver {
  Future<void> _queue = Future.value();
  final _closed = <String>{};
  String? _activeId;
  DialogRoute<bool>? _route;
  String? _failure;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_attach());
  }

  Future<void> _attach() async {
    try {
      await widget.domain.enableDesktopApprovals(_event);
      if (mounted) setState(() => _failure = null);
    } catch (e) {
      if (mounted) setState(() => _failure = 'Agent approvals unavailable: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_attach());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(
        widget.domain.disableDesktopApprovals().catchError((Object _) {}),
      );
    }
  }

  void _event(Map<String, dynamic> event) {
    final id = event['approval_id'] as String;
    if (event['event'] == 'approval_closed') {
      _closed.add(id);
      if (_activeId == id && _route?.isActive == true)
        Navigator.of(context).removeRoute(_route!);
      return;
    }
    _queue = _queue.then((_) => _show(event)).catchError((Object _) {});
  }

  Future<void> _show(Map<String, dynamic> event) async {
    final id = event['approval_id'] as String;
    if (!mounted || _closed.remove(id)) return;
    _activeId = id;
    final args = Map<String, dynamic>.from(event['args'] as Map)
      ..remove('requestId')
      ..remove('conversation');
    const actionNames = {
      'sources.import': 'Import or replace text',
      'sources.import_file': 'Import a local file',
      'sources.import_directory': 'Import files from a folder',
      'sources.import_url': 'Fetch and import a web page',
      'sources.refresh': 'Refresh imported files and connected accounts',
      'sources.delete': 'Delete a source',
      'workspace.clear': 'Clear all workspace data and disconnect Google',
      'google.sign_in': 'Connect a Google account',
      'google.configure': 'Configure a Google account',
      'preferences.set': 'Change an application setting',
      'answer.stream': 'Send a question to web search',
      'answer': 'Send a question to web search',
    };
    final action =
        actionNames[event['method']] ??
        (event['method'].toString().startsWith('models.')
            ? 'Change model settings'
            : 'Change application data or access a connected service');
    final details = args.entries
        .map((entry) {
          final label = entry.key.replaceAll('_', ' ');
          final value = entry.value.toString();
          return '$label: ${value.length > 1000 ? '${value.substring(0, 1000)}…' : value}';
        })
        .join('\n');
    final capture =
        event['method'] == 'meetings.start' ||
        event['method'] == 'meetings.resume';
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(
          capture
              ? 'Allow microphone and system audio recording?'
              : 'Allow this operation?',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                capture
                    ? 'Audio will be captured while the desktop indicator is visible. Closing or hiding the app stops recording.'
                    : action,
              ),
              const SizedBox(height: 16),
              SelectableText(
                details.length > 4000
                    ? '${details.substring(0, 4000)}\n…'
                    : details,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow once'),
          ),
        ],
      ),
    );
    _route = route;
    final allow = await Navigator.of(context).push(route) ?? false;
    _activeId = null;
    _route = null;
    if (!mounted || _closed.remove(id)) return;
    await widget.domain.command(Operation.security_decide, {
      'approval_id': id,
      'allow': allow,
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      widget.domain.disableDesktopApprovals().catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.domain.capture['active'] == true;
    return Column(
      children: [
        if (active || _failure != null)
          Material(
            color: active ? Colors.red.shade800 : Colors.orange.shade900,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    if (active) const Icon(Icons.mic, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        active
                            ? 'Microphone and system audio recording'
                            : _failure!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (active)
                      TextButton(
                        onPressed: () =>
                            widget.domain.command(Operation.meetings_stop),
                        child: const Text(
                          'Stop recording',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
