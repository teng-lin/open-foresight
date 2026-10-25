part of 'settings_controller.dart';

extension _ModelViews on SettingsController {
  Widget _buildModels() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Local models',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const Text('Choose a local model and load it on this computer.'),
        DropdownButton<String>(
          value: modelKind,
          items: ['embedding', 'generation', 'speech', 'query-detection']
              .map(
                (s) => DropdownMenuItem(
                  value: s,
                  child: Text(
                    s == 'query-detection' ? 'Automatic questions' : s,
                  ),
                ),
              )
              .toList(),
          onChanged: (s) => setState(() => modelKind = s!),
        ),
        TextField(
          controller: modelPath,
          decoration: const InputDecoration(labelText: 'Model file'),
        ),
        if (modelKind == 'query-detection')
          SwitchListTile(
            title: const Text('Use a portable local detector'),
            subtitle: const Text(
              'Import a dedicated model and an executable raw-completion worker on macOS or Linux.',
            ),
            value: portableQuery,
            onChanged: _operations.busy
                ? null
                : (value) => setState(() => portableQuery = value),
          ),
        if (modelKind == 'query-detection' && portableQuery) ...[
          TextField(
            controller: runtimePath,
            decoration: const InputDecoration(
              labelText: 'Dedicated raw-completion worker executable',
            ),
          ),
          TextField(
            onChanged: (value) => queryDigest = value,
            decoration: const InputDecoration(
              labelText: 'Expected model SHA-256',
            ),
          ),
          const Text(
            'The worker must implement the Open Foresight dedicated question JSONL protocol. Chat runners are not compatible.',
          ),
        ],
        if (modelKind == 'query-detection')
          const Text(
            'Download the dedicated question model using this distribution, or import an already-decrypted copy. Its identity and bundled runtime are verified before replacing the current model.',
          ),
        if (modelKind == 'query-detection') _queryDownloadControls(),
        if (modelKind == 'query-detection' &&
            (!_host.environment.capabilities.supportsWebContentAcquisition ||
                !desktopRuntimeSettings.webContentAvailable))
          const Text(
            'Automatic download is unavailable in this distribution. You can import a supported local copy.',
          ),
        if (modelKind != 'embedding' && modelKind != 'query-detection')
          TextField(
            controller: runtimePath,
            decoration: const InputDecoration(
              labelText: 'Generation / speech runner executable',
            ),
          ),
        const SizedBox(height: 12),
        if (modelKind == 'embedding')
          CheckboxListTile(
            value: embeddingGpu,
            title: const Text('Use GPU for EmbeddingGemma 2'),
            onChanged: _operations.busy
                ? null
                : (value) => setState(() => embeddingGpu = value!),
          ),
        _registerModelButton(),
        if (modelState.isNotEmpty) Text('Last setup: $modelState'),
        Text(
          'Embedding: ${d.helper.snapshot?.pipeline ?? 'unconfigured'} · Index: ${d.helper.snapshot?.index ?? 'empty'}',
        ),
        Text(
          'Speech: ${preparedSpeechSetupProblem(_reads.model('speech')) ?? 'Ready for live transcription'}',
        ),
        SelectableText(
          'Generator: ${d.generator?.presentation.diagnosticText ?? '{state: unconfigured}'}',
        ),
        CheckboxListTile(
          value: _integrations.notifications,
          onChanged:
              (_host.environment.capabilities.requiresNotificationPermission
                  ? desktopRuntimeSettings['FORESIGHT_NOTIFICATIONS'] != null
                  : _integrations.notificationState.startsWith(
                      'Notifications available',
                    ))
              ? (value) => _operations.run(
                  () => _integrationCommands.setNotifications(value!),
                )
              : null,
          title: const Text('Desktop completion/error notifications'),
          subtitle: Text(_integrations.notificationState),
        ),
        ListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: _reads.models
              .map(
                (m) => ListTile(
                  title: Text('${m.kind}: ${m.path}'),
                  subtitle: SelectableText(
                    'SHA256 ${m.digest}\nRunner ${m.runtime}',
                  ),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
  Widget _queryDownloadControls() => Row(
    children: [
      OutlinedButton(
        onPressed:
            _operations.busy ||
                !_host.environment.capabilities.supportsWebContentAcquisition ||
                !desktopRuntimeSettings.webContentAvailable
            ? null
            : () async {
                setState(() => queryModelDownloading = true);
                try {
                  await _operations.run(() async {
                    final terms = dedicatedQueryTermsUri();
                    if (terms == null)
                      throw StateError(
                        'This distribution has not supplied question model terms.',
                      );
                    if (_reads.preference(dedicatedQueryTermsKey) !=
                        'accepted') {
                      if (!await confirmQueryModelTerms(
                        context,
                        terms,
                        dedicatedQueryModelDigest,
                        openUri: _host.environment.openUri,
                      ))
                        return;
                      await preferencesSetDescriptor.send(
                        d,
                        PreferencesSetInput(
                          key: dedicatedQueryTermsKey,
                          value: 'accepted',
                        ),
                      );
                    }
                    await modelsAcquireQueryDescriptor.send(
                      d,
                      ModelsAcquireQueryInput(),
                    );
                    modelState = 'Automatic question model ready';
                  });
                } finally {
                  if (mounted) setState(() => queryModelDownloading = false);
                }
              },
        child: Text(
          queryModelDownloading
              ? 'Downloading and verifying…'
              : 'Download question model',
        ),
      ),
      if (queryModelDownloading)
        TextButton(
          onPressed: () async {
            try {
              await modelsCancelQueryAcquisitionDescriptor.send(
                d,
                ModelsCancelQueryAcquisitionInput(),
              );
            } catch (failure) {
              if (mounted)
                setState(() => _operations.setError(failure.toString()));
            }
          },
          child: const Text('Cancel download'),
        ),
    ],
  );

  Widget _registerModelButton() => FilledButton(
    onPressed: _operations.busy
        ? null
        : () => _operations.run(() async {
            final path = modelPath.text;
            final runtime = modelKind == 'query-detection' && !portableQuery
                ? ''
                : runtimePath.text;
            if (modelKind == 'embedding') {
              await modelsEmbeddingDescriptor.send(
                d,
                ModelsEmbeddingInput(
                  path: path,
                  runtime: WireField(runtime),
                  kind: WireField(modelKind),
                  gpu: WireField(embeddingGpu),
                ),
              );
            } else if (modelKind == 'generation') {
              await modelsGenerationDescriptor.send(
                d,
                ModelsGenerationInput(
                  path: path,
                  runtime: runtime,
                  kind: WireField(modelKind),
                  gpu: WireField(embeddingGpu),
                ),
              );
            } else {
              await modelsRegisterDescriptor.send(
                d,
                ModelsRegisterInput(
                  kind: modelKind,
                  path: path,
                  runtime: WireField(runtime),
                  gpu: WireField(embeddingGpu),
                  backend: modelKind == 'query-detection'
                      ? WireField(
                          portableQuery
                              ? 'raw_query_jsonl_v1'
                              : 'legacy_query_cpu',
                        )
                      : const WireField.absent(),
                  digest: modelKind == 'query-detection' && portableQuery
                      ? WireField(queryDigest.trim())
                      : const WireField.absent(),
                ),
              );
            }
            modelState = modelKind == 'query-detection'
                ? 'Automatic question model ready'
                : '$modelKind ready';
          }),
    child: Text(
      modelKind == 'query-detection'
          ? 'Verify and import'
          : 'Register and load',
    ),
  );
}
