# Documentation

Start with the [README](../README.md) for features, installation, profiles and
recording backups. [CONTRIBUTING](../CONTRIBUTING.md) covers development checks;
[RELEASING](../RELEASING.md) covers release preparation.

## Using and building the app

- [Linux builds and packages](platforms/linux-packaging.md)
- [macOS builds, bundles and permissions](platforms/macos-support.md)
- [Speech models](models/speech-models.md)
- [Diagnostics and logs](diagnostics.md)
- [Manual updates and rollback](manual-updates.md)
- [Native inference](../services/inference/README.md)

## Architecture

- [Application service and MCP](architecture/application-service.md)
- [Desktop and core boundary](architecture/desktop-core-boundary.md)
- [Meeting AI workflows](architecture/meeting-ai-workflows.md)
- [Meeting summaries](architecture/meeting-summary.md)
- [Incremental transcript indexing](architecture/meeting-indexing.md)
- [Recording storage and background work](architecture/recording-audio-store.md)
- [Playback, transcript seeking and export controls](architecture/recording-audio-presentation.md)
- [Audio worker protocol](architecture/audio-worker-protocol.md)
- [Codec build and installation](architecture/audio-codecs.md)
- [Export publication and recovery](architecture/audio-export-publication.md)
- [Audio and database backups](architecture/audio-backups.md)
- [Storage retention and recovery](architecture/storage-recovery.md)
- [Schema migrations](architecture/schema-migrations.md)
- [Credentials at rest](architecture/credentials-at-rest.md)
- [Diagnostic workers and build identities](architecture/diagnostic-workers.md)
- [Diagnostic SHA-256 ABI](architecture/diagnostic-sha256.md)
- [Native retirement](architecture/native-retirement.md) and [owned lifetime protocol](architecture/native-retirement-protocol.md)
- [SQLite read workers](architecture/sqlite-read-workers.md)
- [Architecture decisions](adr/README.md)

## Testing and releases

- [Integration and model/device gates](testing.md)
- [Installed GUI approval](installed-gui-approval.md)
- [Installer acceptance](release-acceptance.md)
- [CI, dependency reuse and preview installers](ci.md)
- [CI integrity rules](platforms/ci-integrity.md)
- [Release history](../CHANGELOG.md)
