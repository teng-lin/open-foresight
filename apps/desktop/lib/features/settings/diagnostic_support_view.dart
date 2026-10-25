import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foresight_core/desktop.dart';

/// Local logging health for this desktop app process and an explicit action
/// that reveals the profile's logs folder. Nothing is uploaded.
class DiagnosticSupportView extends StatefulWidget {
  const DiagnosticSupportView({
    super.key,
    required this.support,
    this.copyText,
    this.version = openForesightVersion,
    this.buildNumber = openForesightBuildNumber,
  });

  final DiagnosticSupportPort support;
  final Future<void> Function(String)? copyText;
  final String version;
  final int buildNumber;

  @override
  State<DiagnosticSupportView> createState() => _DiagnosticSupportViewState();
}

class _DiagnosticSupportViewState extends State<DiagnosticSupportView> {
  late DiagnosticSupportSnapshot _snapshot = widget.support.snapshot();
  bool _opening = false;
  String _message = '';
  int _generation = 0;

  @override
  void didUpdateWidget(covariant DiagnosticSupportView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.support, widget.support)) {
      _generation++;
      _opening = false;
      _message = '';
      _snapshot = widget.support.snapshot();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _refresh() => setState(() {
    _snapshot = widget.support.snapshot();
    _message = '';
  });

  Future<void> _open() async {
    if (_opening) return;
    final generation = ++_generation;
    final support = widget.support;
    setState(() {
      _opening = true;
      _message = '';
    });
    DiagnosticFolderOpenResult result;
    try {
      result = await support.openLogsFolder();
    } catch (_) {
      result = DiagnosticFolderOpenResult.failed;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _opening = false;
      _snapshot = support.snapshot();
      _message = switch (result) {
        DiagnosticFolderOpenResult.opened => '',
        DiagnosticFolderOpenResult.unavailable =>
          'The logs folder is unavailable in this session.',
        DiagnosticFolderOpenResult.missing =>
          'No log files have been written yet.',
        DiagnosticFolderOpenResult.unsafe =>
          'The logs folder was not opened because it is not a private folder.',
        DiagnosticFolderOpenResult.failed =>
          'Could not show the logs folder. Try again.',
      };
    });
  }

  String get _summary =>
      'Open Foresight ${widget.version} (build ${widget.buildNumber})\n'
      '${_snapshot.supportText}';

  Future<void> _copy() async {
    final generation = _generation;
    try {
      await (widget.copyText?.call(_summary) ??
          Clipboard.setData(ClipboardData(text: _summary)));
      if (mounted && generation == _generation)
        setState(() => _message = 'Copied the health summary.');
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _message = 'Could not copy the health summary.');
    }
  }

  static String _status(DiagnosticSupportStatus status) => switch (status) {
    DiagnosticSupportStatus.unavailable => 'Unavailable in this session',
    DiagnosticSupportStatus.off => 'Off',
    DiagnosticSupportStatus.active => 'Recording',
    DiagnosticSupportStatus.memoryOnly => 'Held in memory, not written',
    DiagnosticSupportStatus.limited =>
      'Not writing log files; the app continues',
    DiagnosticSupportStatus.failed =>
      'Log writing stopped after a failure; the app continues',
    DiagnosticSupportStatus.closed => 'Closed',
  };

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final available = snapshot.status != DiagnosticSupportStatus.unavailable;
    final canOpen = snapshot.logsFolderKnown && !_opening;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: const Key('diagnosticHealth'),
            title: const Text('Logging in this desktop app'),
            subtitle: Text(
              '${_status(snapshot.status)}'
              '${available ? ' · level ${snapshot.level.name}' : ''}'
              '${snapshot.invalidLevel ? ' (FORESIGHT_LOG_LEVEL was invalid)' : ''}\n'
              'Logs stay on this computer and are never uploaded. Open logs '
              'folder shows it in your file manager. The background service '
              'keeps its own logs there; its health is not shown here.',
            ),
          ),
          if (available)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                key: const Key('diagnosticCounters'),
                'Recorded ${snapshot.admitted} · dropped ${snapshot.dropped}'
                ' · rejected ${snapshot.rejected}',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const Key('openLogsFolder'),
                  onPressed: canOpen ? _open : null,
                  child: Text(_opening ? 'Opening…' : 'Open logs folder'),
                ),
                TextButton(
                  key: const Key('refreshDiagnosticHealth'),
                  onPressed: _opening ? null : _refresh,
                  child: const Text('Refresh'),
                ),
                TextButton(
                  key: const Key('copyDiagnosticSummary'),
                  onPressed: available ? _copy : null,
                  child: const Text('Copy health summary'),
                ),
                if (!snapshot.logsFolderKnown)
                  const Text('The logs folder is unavailable in this session.'),
                if (_message.isNotEmpty)
                  Semantics(liveRegion: true, child: Text(_message)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
