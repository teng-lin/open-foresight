part of 'settings_controller.dart';

extension _SettingsView on SettingsController {
  Widget settingRow(String title, String subtitle, Widget control) =>
      LayoutBuilder(
        builder: (_, constraints) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (subtitle.isNotEmpty) Text(subtitle),
            ],
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: constraints.maxWidth < 720
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [text, const SizedBox(height: 12), control],
                  )
                : Row(
                    children: [
                      Expanded(child: text),
                      const SizedBox(width: 20),
                      control,
                    ],
                  ),
          );
        },
      );

  Widget serviceIdleSetting() {
    final value = _reads.preference('serviceIdleMinutes', '30');
    const choices = ['0', '15', '30', '60', '120'];
    return settingRow(
      'Stop the background service after agent inactivity',
      'With the window closed, the service and its models exit this long after the last agent request.',
      DesktopSettingSelect<String>(
        key: const Key('serviceIdleMinutes'),
        value: value,
        items: [...choices, if (!choices.contains(value)) value]
            .map(
              (v) => DropdownMenuItem(
                value: v,
                child: Text(
                  v == '0'
                      ? 'Never'
                      : v == '30'
                      ? '30 minutes (Default)'
                      : '$v minutes',
                ),
              ),
            )
            .toList(),
        onChanged: (v) => runAction(() => preference('serviceIdleMinutes', v!)),
      ),
    );
  }

  Widget _buildSettings() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('Settings'),
        const SizedBox(height: 30),
        const Text('General', style: DesktopVisuals.sectionTitle),
        const SizedBox(height: 6),
        const Text('Configure general application settings.'),
        const SizedBox(height: 16),
        _generalSettings(),
        const SizedBox(height: 24),
        const Text('Hotkeys', style: DesktopVisuals.sectionTitle),
        const SizedBox(height: 8),
        Text(
          _reads.preference('globalShortcut') == 'true'
              ? 'The meeting shortcut works across the desktop.'
              : 'Enable global shortcuts to use the meeting shortcut outside Foresight.',
        ),
        Card(
          child: SwitchListTile(
            title: const Text('Global meeting shortcut'),
            subtitle: Text(_integrations.globalShortcutState),
            value: _reads.preference('globalShortcut') == 'true',
            onChanged: _operations.busy
                ? null
                : (enabled) => _operations.run(
                    enabled
                        ? _integrationCommands.enableGlobalShortcuts
                        : _integrationCommands.disableGlobalShortcuts,
                  ),
          ),
        ),
        Card(
          child: settingRow(
            'Quick start new meeting transcript',
            'Use at least two modifiers and a letter or digit.',
            TextButton(
              onPressed: _operations.busy
                  ? null
                  : _integrationCommands.changeQuickShortcut,
              child: Text(
                _reads.preference('quickShortcut', 'CTRL + SHIFT + F'),
              ),
            ),
          ),
        ),
        Card(
          child: settingRow(
            'New editable note',
            '',
            TextButton(
              onPressed: () =>
                  _host.update(() => _navigation.navigate(WorkspaceTab.notes)),
              child: Text(
                _host.environment.capabilities.usesMetaShortcuts
                    ? '⌘ + N'
                    : 'Ctrl + N',
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Audio and notifications',
          style: DesktopVisuals.sectionTitle,
        ),
        _audioSettings(),
        const SizedBox(height: 24),
        const Text('Connected services', style: DesktopVisuals.sectionTitle),
        _connectedServices(),
        const SizedBox(height: 24),
        const Text('Updates', style: DesktopVisuals.sectionTitle),
        UpdateNoticeView(
          enabled: _reads.preference('updateNoticeEnabled') == 'true',
          openRelease: _host.environment.openUri,
          setEnabled: (enabled) => runAction(
            () => preference('updateNoticeEnabled', enabled ? 'true' : 'false'),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Diagnostics', style: DesktopVisuals.sectionTitle),
        DiagnosticSupportView(support: _host.environment.diagnosticSupport),
        const SizedBox(height: 24),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Foresight processes knowledge sources and AI requests on your computer. Transcribing listens to microphone and system playback while active. Transcripts update during recording; Stop finalizes pending speech. Imported URL pages are fetched only when you request an import.',
            ),
          ),
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('Third-party Libraries'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Foresight',
                  applicationVersion: openForesightVersion,
                ),
              ),
              const Divider(height: 1),
              const ListTile(
                title: Text('Version'),
                subtitle: Text(
                  'Open Foresight $openForesightVersion '
                  '(build $openForesightBuildNumber)'
                  '${openForesightBuildLabel == '' ? '' : ' · $openForesightBuildLabel'}',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _generalSettings() => Card(
    child: Column(
      children: [
        SwitchListTile(
          title: const Text('Open at login'),
          subtitle: Text(
            _integrations.loginState.isEmpty
                ? 'Automatically open Foresight when you log in to your computer.'
                : _integrations.loginState,
          ),
          value: _integrations.openAtLogin,
          onChanged: _operations.busy
              ? null
              : (value) => _operations.run(
                  () => _integrationCommands.setOpenAtLogin(value),
                ),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Upcoming meeting reminders'),
          subtitle: const Text(
            'Notify five minutes before a timed Calendar meeting starts.',
          ),
          value: _reads.preference('googleReminders') == 'true',
          onChanged: _operations.busy
              ? null
              : (value) => _operations.run(
                  () => _integrationCommands.setMeetingReminders(value),
                ),
        ),
        const Divider(height: 1),
        _generationSetting(),
        const Divider(height: 1),
        _embeddingSetting(),
        const Divider(height: 1),
        settingRow(
          'Transcription Model',
          'Choose multilingual speech recognition for Chinese and English.',
          OutlinedButton.icon(
            onPressed: _operations.busy || _meetings.recording != null
                ? null
                : chooseSpeech,
            icon: const Icon(Icons.unfold_more, size: 18),
            label: Text(speechModelName()),
          ),
        ),
        const Divider(height: 1),
        _noteStyleSetting(),
        const Divider(height: 1),
        settingRow(
          'Auto-stop transcribing after inactivity',
          'Finalize when microphone and playback audio are inactive.',
          DesktopSettingSelect<String>(
            key: const Key('inactivity'),
            value: _reads.preference('inactivity', '15'),
            items: ['0', '5', '10', '15', '30']
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                      v == '0'
                          ? 'Never'
                          : v == '15'
                          ? '15 minutes (Default)'
                          : '$v minutes',
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => runAction(() => preference('inactivity', v!)),
          ),
        ),
        const Divider(height: 1),
        serviceIdleSetting(),
        if (_host.environment.capabilities.supportsEchoCancellation) ...[
          const Divider(height: 1),
          settingRow(
            'Echo cancellation',
            _meetings.echoCancellationDescription,
            Switch(
              value: _reads.preference('echoCancellation', 'false') == 'true',
              onChanged: (value) => preference('echoCancellation', '$value'),
            ),
          ),
        ],
        const Divider(height: 1),
        settingRow(
          'Launch Agent Monitor',
          'Monitor and control the local helper.',
          IconButton(
            tooltip: 'Helper monitor',
            onPressed: showHelperMonitor,
            icon: const Icon(Icons.chevron_right),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text(
            'Clear workspace data',
            style: TextStyle(color: Colors.red),
          ),
          subtitle: const Text(
            'Delete sources, answers, meetings and notes. Keep local model files.',
          ),
          trailing: const Icon(Icons.delete_outline, color: Colors.red),
          onTap: _operations.busy || _meetings.recording != null
              ? null
              : clearWorkspace,
        ),
      ],
    ),
  );

  Widget _audioSettings() => Card(
    child: Column(
      children: [
        if (_host.environment.capabilities.requiresAudioPermissions) ...[
          ListTile(
            title: const Text('Recording access'),
            subtitle: Text(
              _integrations.captureCapabilityError.isNotEmpty
                  ? _integrations.captureCapabilityError
                  : 'Microphone: ${_integrations.microphoneAccessLabel}\nSystem audio: ${_integrations.systemAudioAccessLabel}',
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _operations.busy
                    ? null
                    : () => _operations.run(
                        _integrationCommands.requestMicrophoneAccess,
                      ),
                child: const Text('Allow microphone'),
              ),
              TextButton(
                onPressed: _operations.busy
                    ? null
                    : () => _operations.run(() async {
                        await _integrationCommands.setupSystemAudioAccess();
                      }),
                child: const Text('Allow system audio'),
              ),
              TextButton(
                onPressed: _operations.busy
                    ? null
                    : _integrationCommands.refreshCaptureCapabilities,
                child: const Text('Refresh access status'),
              ),
            ],
          ),
          const Divider(height: 1),
        ],
        settingRow(
          'Microphone',
          'Select the microphone used for spoken transcription.',
          _integrationCommands.deviceChoice(false),
        ),
        const Divider(height: 1),
        settingRow(
          'System playback',
          'Select the output whose playback should be transcribed.',
          _integrationCommands.deviceChoice(true),
        ),
        if (_integrations.audioDeviceState.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_integrations.audioDeviceState),
          ),
        TextButton(
          onPressed: _integrationCommands.refreshAudioDevices,
          child: const Text('Refresh audio devices'),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Desktop completion notifications'),
          subtitle: Text(_integrations.notificationState),
          value: _integrations.notifications,
          onChanged: _operations.busy
              ? null
              : (value) => _operations.run(
                  () => _integrationCommands.setNotifications(value),
                ),
        ),
        const Divider(height: 1),
      ],
    ),
  );

  Widget _connectedServices() => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Calendar and files',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose one connection. Google connects Drive and Calendar directly; Granola connects Calendar only.',
          ),
          if (!_integrations.googlePresentation.connected &&
              !_integrations.googlePresentation.configured)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Google sign-in is unavailable in this build. Install a distribution with Google sign-in included.',
              ),
            ),
          if (_integrations.googleState.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_integrations.googleState),
            ),
          _connectionActions(),
          const Divider(),
          settingRow(
            _integrations.granolaCalendar
                ? 'Calendar refresh interval'
                : 'Refresh interval for Calendar events and Drive files',
            _integrations.granolaCalendar
                ? 'Refreshes upcoming meetings through Granola.'
                : 'Refreshes imported Drive folders, files and upcoming Calendar events.',
            DesktopSettingSelect<String>(
              value: _integrations.granolaCalendar
                  ? _reads.preference('granolaCalendarRefreshMinutes', '10')
                  : _reads.preference('googleRefreshHours', '4'),
              items:
                  (_integrations.granolaCalendar
                          ? ['5', '10', '30', '60']
                          : ['1', '2', '4', '8', '24'])
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(
                            _integrations.granolaCalendar
                                ? '$value minutes'
                                : '$value hours',
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (value) => runAction(
                () => preference(
                  _integrations.granolaCalendar
                      ? 'granolaCalendarRefreshMinutes'
                      : 'googleRefreshHours',
                  value!,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _generationSetting() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Local Inference Model',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        const Text('Select the local generative model to use.'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _operations.busy || _meetings.recording != null
                ? null
                : chooseGemma,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffdee3e9),
              foregroundColor: const Color(0xff26272b),
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    generationName(),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                const Icon(Icons.unfold_more, size: 18),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _embeddingSetting() => settingRow(
    'Source Search Model',
    preparedNeedsModel(_reads.currentModel('embedding'), 'embedding')
        ? 'EmbeddingGemma 2 runs source search locally. Setup reuses an existing model or downloads 485 MB.'
        : 'EmbeddingGemma 2 is installed and runs source search locally.',
    OutlinedButton(
      onPressed:
          _operations.busy ||
              _meetings.recording != null ||
              !preparedNeedsModel(_reads.currentModel('embedding'), 'embedding')
          ? null
          : () => chooseGemma(embeddingOnly: true),
      child: Text(
        preparedNeedsModel(_reads.currentModel('embedding'), 'embedding')
            ? 'Download EmbeddingGemma 2'
            : 'Embedding model ready',
      ),
    ),
  );

  Widget _noteStyleSetting() => settingRow(
    'Default Note Enhancement Style',
    'Format enhanced notes as complete sentences or brief phrases.',
    SegmentedButton<String>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        textStyle: WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'GoogleSans',
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
      ),
      segments: const [
        ButtonSegment(
          value: 'Standard',
          label: Text('Standard'),
          icon: Icon(Icons.description_outlined, size: 16),
        ),
        ButtonSegment(
          value: 'Concise',
          label: Text('Concise'),
          icon: Icon(Icons.short_text, size: 16),
        ),
      ],
      selected: {_reads.preference('noteStyle', 'Standard')},
      onSelectionChanged: (v) =>
          runAction(() => preference('noteStyle', v.first)),
    ),
  );

  Widget _connectionActions() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      _providerConnection(throughGranola: false),
      const SizedBox(height: 12),
      _providerConnection(throughGranola: true),
      TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(
            title: Text('Google connection setup'),
            content: SingleChildScrollView(
              child: SelectableText(
                'Google connects directly for read-only Drive and Calendar access. Google sign-in must be included in your distribution. Your Google password is never entered into Foresight.\n\n'
                'Granola connects Calendar only and processes authorization and calendar data. Drive is unavailable. Google consent may include calendar write access. If your browser opens Granola, paste the return link into the waiting Foresight sign-in dialog.\n\n'
                'Only one connection provider can be used at a time. Switching signs out saved accounts in Foresight; imported documents remain on this computer. Manage service access in Google or Granola.',
              ),
            ),
          ),
        ),
        child: const Text('Connection help'),
      ),
      if (_integrations.googlePresentation.signingIn)
        TextButton(
          onPressed: _integrationCommands.cancelGoogleSignIn,
          child: const Text('Cancel sign-in'),
        ),
    ],
  );

  Widget _providerConnection({required bool throughGranola}) {
    final selected = _integrations.granolaCalendar == throughGranola;
    final connected = selected && _integrations.googlePresentation.connected;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            throughGranola
                ? 'Calendar through Granola'
                : 'Google Drive and Calendar',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            throughGranola
                ? 'Calendar only. Granola handles sign-in and calendar data. Drive is unavailable.'
                : 'Read-only access to Drive files and upcoming meetings. Imported text is indexed on this computer.',
          ),
          const SizedBox(height: 8),
          Text(
            connected
                ? 'Connected as ${_integrations.googlePresentation.email}'
                : selected && _integrations.googlePresentation.signingIn
                ? 'Signing in…'
                : 'Not connected',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!connected)
                if (throughGranola)
                  OutlinedButton(
                    onPressed: _operations.busy
                        ? null
                        : () => _operations.run(
                            _integrationCommands.connectGranolaCalendar,
                          ),
                    child: const Text('Connect calendar through Granola'),
                  )
                else
                  FilledButton(
                    onPressed: _operations.busy
                        ? null
                        : () => _operations.run(
                            _integrationCommands.connectGoogle,
                          ),
                    child: const Text('Connect Google'),
                  )
              else ...[
                TextButton(
                  onPressed: _operations.busy || _integrations.googleSyncing
                      ? null
                      : () =>
                            _operations.run(_integrationCommands.refreshGoogle),
                  child: Text(
                    throughGranola ? 'Refresh calendar' : 'Refresh Google',
                  ),
                ),
                TextButton(
                  onPressed: _operations.busy
                      ? null
                      : () => _operations.run(
                          _integrationCommands.disconnectGoogle,
                        ),
                  child: Text(
                    throughGranola
                        ? 'Disconnect calendar'
                        : 'Disconnect Google',
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class SettingsView extends StatelessWidget {
  final SettingsController controller;
  const SettingsView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) => controller.settings();
}
