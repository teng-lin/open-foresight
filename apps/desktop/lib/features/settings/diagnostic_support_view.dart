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
  int _generation = 0, _copyGeneration = 0;

  @override
  void didUpdateWidget(covariant DiagnosticSupportView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.support, widget.support)) {
      _generation++;
      _copyGeneration++;
      _opening = false;
      _message = '';
      _snapshot = widget.support.snapshot();
    }
  }

  @override
  void dispose() {
    _generation++;
    _copyGeneration++;
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
          _snapshot.logsFolderKnown ? _folderUnavailable : '',
        DiagnosticFolderOpenResult.missing =>
          'No log files have been written yet.',
        DiagnosticFolderOpenResult.unsafe =>
          'The logs folder was not shown because it is not a private folder '
              'owned by you.',
        DiagnosticFolderOpenResult.failed =>
          'Could not show the logs folder. Try again.',
      };
    });
  }

  static const _folderUnavailable =
      'The logs folder is unavailable in this session.';

  String get _summary =>
      'Open Foresight ${widget.version} (build ${widget.buildNumber})\n'
      '${_snapshot.supportText}';

  Future<void> _copy() async {
    final generation = ++_copyGeneration;
    String message;
    try {
      await (widget.copyText?.call(_summary) ??
          Clipboard.setData(ClipboardData(text: _summary)));
      message = 'Copied the health summary.';
    } catch (_) {
      message = 'Could not copy the health summary.';
    }
    if (mounted && generation == _copyGeneration) {
      setState(() => _message = message);
    }
  }

  static String _degraded(DiagnosticSupportSnapshot snapshot) {
    if (!snapshot.storageConfigured) return 'log storage is not configured';
    return switch (snapshot.reason) {
      DiagnosticSupportReason.storageUnavailable =>
        'no log file slot is available',
      DiagnosticSupportReason.unsupportedFilesystem =>
        'this file system is not used for log files',
      DiagnosticSupportReason.sinkFailed ||
      DiagnosticSupportReason.writerFailed => 'writing log files failed',
      DiagnosticSupportReason.storageWorkerUnconfigured =>
        'log storage is not configured',
      DiagnosticSupportReason.storageStagingUnavailable ||
      DiagnosticSupportReason.storagePlatformUnsupported ||
      DiagnosticSupportReason.storageDescriptorLimit =>
        'log storage is unavailable on this system',
      DiagnosticSupportReason.storageWorkerLaunchFailed ||
      DiagnosticSupportReason.storageWorkerProtocolFailed ||
      DiagnosticSupportReason.storageWorkerExited ||
      DiagnosticSupportReason.storageWorkerUnresponsive ||
      DiagnosticSupportReason.storageWorkerUnknown =>
        'the log storage worker stopped or did not start',
      DiagnosticSupportReason.unavailable ||
      DiagnosticSupportReason.healthy ||
      DiagnosticSupportReason.bootstrapOnly ||
      DiagnosticSupportReason.off ||
      DiagnosticSupportReason.closed => 'logging is limited',
    };
  }

  static String _status(DiagnosticSupportSnapshot snapshot) =>
      switch (snapshot.status) {
        DiagnosticSupportStatus.unavailable => 'Unavailable in this session',
        DiagnosticSupportStatus.off => 'Off',
        DiagnosticSupportStatus.unknown =>
          snapshot.stale
              ? 'Unknown: the last report is out of date'
              : 'Unknown: no report yet',
        DiagnosticSupportStatus.starting =>
          'Starting: no log file has been admitted yet',
        DiagnosticSupportStatus.healthy => 'Writing to a log file',
        DiagnosticSupportStatus.degraded =>
          'Degraded: ${_degraded(snapshot)}; the app continues',
        DiagnosticSupportStatus.closing => 'Closing',
        DiagnosticSupportStatus.closed => 'Closed',
      };

  static String? _native(DiagnosticSupportSnapshot snapshot) {
    final reason = switch (snapshot.nativeReason) {
      DiagnosticSupportNativeReason.unconfigured => null,
      DiagnosticSupportNativeReason.healthy => 'working',
      DiagnosticSupportNativeReason.unsupported =>
        'not supported by this native library',
      DiagnosticSupportNativeReason.capacity => 'at capacity',
      DiagnosticSupportNativeReason.protocolFailed => 'failed',
      DiagnosticSupportNativeReason.unsettled => 'not settled',
    };
    if (reason == null) return null;
    return 'Native diagnostics: $reason'
        '${snapshot.nativeDropsExact ? '' : '; drop counts are approximate'}';
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final available = snapshot.status != DiagnosticSupportStatus.unavailable;
    final canOpen = snapshot.logsFolderKnown && !_opening;
    final native = _native(snapshot);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: const Key('diagnosticHealth'),
            title: const Text('Logging in this desktop app'),
            subtitle: Text(
              '${_status(snapshot)}'
              '${available ? ' · level ${snapshot.level.name}' : ''}'
              '${snapshot.invalidLevel ? ' (FORESIGHT_LOG_LEVEL was invalid)' : ''}\n'
              'Updated when this page opens or you choose Refresh. Logs stay '
              'on this computer and are never uploaded. Show logs folder '
              'reveals it in your file manager. The background service keeps '
              'its own logs there; its health is not shown here.',
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
          if (native != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(key: const Key('nativeDiagnosticHealth'), native),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const Key('showLogsFolder'),
                  onPressed: canOpen ? _open : null,
                  child: Text(_opening ? 'Showing…' : 'Show logs folder'),
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
                if (!snapshot.logsFolderKnown) const Text(_folderUnavailable),
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
