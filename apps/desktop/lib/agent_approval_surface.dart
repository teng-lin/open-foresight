import 'dart:async';
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

/// The service can authorize agent operations only while this surface is alive.
class AgentApprovalSurface extends StatefulWidget {
  final DesktopConnection domain;
  final Widget child;
  final bool allowAgentRequests;
  const AgentApprovalSurface({
    super.key,
    required this.domain,
    required this.child,
    this.allowAgentRequests = true,
  });
  @override
  State<AgentApprovalSurface> createState() => _AgentApprovalSurfaceState();
}

class _AgentApprovalSurfaceState extends State<AgentApprovalSurface>
    with WidgetsBindingObserver {
  Future<void> _queue = Future.value();
  // Closed before their dialog could show; only queued IDs are recorded, so
  // a later request that reuses an ID is never swallowed.
  final _closed = <String>{};
  final _queued = <String>{};
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
      final state = WidgetsBinding.instance.lifecycleState;
      await widget.domain.setDesktopVisible(
        state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive,
      );
      await widget.domain.enableDesktopApprovals(_event);
      if (mounted) setState(() => _failure = null);
    } catch (e) {
      if (mounted) setState(() => _failure = 'Agent approvals unavailable: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        widget.domain.setDesktopVisible(true).catchError((Object error) {
          if (mounted)
            setState(() => _failure = 'Agent approvals unavailable: $error');
        }),
      );
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(
        widget.domain.setDesktopVisible(false).catchError((Object _) {}),
      );
    }
  }

  void _event(Map<String, dynamic> event) {
    final id = event['approval_id'] as String;
    if (event['event'] == 'approval_closed') {
      if (_queued.contains(id) || _activeId == id) _closed.add(id);
      if (_activeId == id && _route?.isActive == true)
        Navigator.of(context).removeRoute(_route!);
      return;
    }
    _queued.add(id);
    _queue = _queue.then((_) => _show(event)).catchError((Object _) {});
  }

  Future<void> _show(Map<String, dynamic> event) async {
    final id = event['approval_id'] as String;
    _queued.remove(id);
    if (!mounted || _closed.remove(id)) return;
    if (!widget.allowAgentRequests) {
      await widget.domain.command(Operation.securityDecide, {
        'approval_id': id,
        'allow': false,
      });
      return;
    }
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
                    ? 'Audio will be captured while the desktop recording controls are visible. Closing or hiding the app stops recording.'
                    : action,
              ),
              const SizedBox(height: 16),
              Text(
                event['requester'] as String? ??
                    'Requester identity unavailable',
              ),
              for (final flag in (event['risk_flags'] as List? ?? const []))
                Text(
                  flag.toString(),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              const SizedBox(height: 8),
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
    await widget.domain.command(Operation.securityDecide, {
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
    return Column(
      children: [
        if (_failure != null)
          Material(
            color: Colors.orange.shade900,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _failure!,
                        style: const TextStyle(color: Colors.white),
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
