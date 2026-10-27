import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

class UpdateNoticeView extends StatefulWidget {
  const UpdateNoticeView({
    super.key,
    required this.enabled,
    required this.setEnabled,
    required this.openRelease,
    this.client,
    this.currentVersion = openForesightVersion,
  });

  final bool enabled;
  final Future<void> Function(bool) setEnabled;
  final UpdateNoticeClient? client;
  final String currentVersion;
  final Future<void> Function(Uri) openRelease;

  @override
  State<UpdateNoticeView> createState() => _UpdateNoticeViewState();
}

class _UpdateNoticeViewState extends State<UpdateNoticeView> {
  late final _client = widget.client ?? UpdateNoticeClient();
  bool _checking = false, _saving = false;
  String _message = '';
  Uri? _releasePage;
  int _generation = 0;

  void _cancel() {
    _generation++;
    _client.cancelPending();
    _checking = false;
    _message = '';
    _releasePage = null;
  }

  @override
  void didUpdateWidget(covariant UpdateNoticeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) _cancel();
  }

  Future<void> _setEnabled(bool value) async {
    setState(() {
      _saving = true;
      _message = '';
      if (!value) _cancel();
    });
    try {
      await widget.setEnabled(value);
    } catch (_) {
      if (mounted)
        setState(() => _message = 'Could not save the update setting.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _check() async {
    if (!widget.enabled || _checking) return;
    final generation = ++_generation;
    setState(() {
      _checking = true;
      _message = '';
      _releasePage = null;
    });
    try {
      final result = await _client.check(
        enabled: widget.enabled,
        currentVersion: widget.currentVersion,
      );
      if (!mounted || generation != _generation || !widget.enabled) return;
      setState(() {
        _message = result.hasUpdate
            ? 'Version ${result.version} is available.'
            : 'No newer stable release is available.';
        _releasePage = result.releasePage;
      });
    } on UpdateNoticeException catch (error) {
      if (!mounted || generation != _generation || !widget.enabled) return;
      setState(() {
        _message = switch (error.problem) {
          UpdateNoticeProblem.timedOut =>
            'The update check timed out. Try again.',
          UpdateNoticeProblem.untrustedMetadata =>
            'The release identity could not be verified.',
          UpdateNoticeProblem.invalidMetadata =>
            'The release information could not be read.',
          UpdateNoticeProblem.wrongChannel =>
            'No valid stable release information was returned.',
          UpdateNoticeProblem.unavailable =>
            'Update information is unavailable. Try again when online.',
          UpdateNoticeProblem.cancelled => '',
        };
      });
    } finally {
      if (mounted && generation == _generation)
        setState(() => _checking = false);
    }
  }

  Future<void> _openRelease() async {
    final page = _releasePage;
    if (page == null) return;
    try {
      await widget.openRelease(page);
    } catch (_) {
      if (mounted)
        setState(
          () => _message = 'Could not open the release page. Try again.',
        );
    }
  }

  @override
  void dispose() {
    _generation++;
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('updateNoticeEnabled'),
          title: const Text('Allow manual update checks'),
          subtitle: const Text(
            'Check public GitHub releases when you click Check for updates. No profile data is sent. Install updates manually.',
          ),
          value: widget.enabled,
          onChanged: _saving ? null : _setEnabled,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                key: const Key('checkForUpdates'),
                onPressed: widget.enabled && !_checking && !_saving
                    ? _check
                    : null,
                child: Text(_checking ? 'Checking…' : 'Check for updates'),
              ),
              if (_message.isNotEmpty) Text(_message),
              if (_releasePage != null)
                TextButton(
                  key: const Key('updateReleasePage'),
                  onPressed: _openRelease,
                  child: const Text('Open release page'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
