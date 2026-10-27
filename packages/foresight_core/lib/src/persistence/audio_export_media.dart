import '../application_services/audio_transform_scheduler.dart';
import '../application_services/native_audio_media.dart';
import '../audio_models.dart';
import '../native_lifetime.dart';
import 'audio_assembly_manifest.dart';
import 'audio_export_destinations.dart';
import 'audio_store.dart';
import 'backup_files.dart';
import 'recording_media.dart';

typedef AudioAssemblyStart =
    Future<AudioTransformExecution> Function({
      required AudioTransformLease lease,
      required AudioAssemblyManifest manifest,
      required int outputDescriptor,
      required bool Function() current,
    });

/// A fixed codec job; all original source descriptors come from the frozen
/// manifest pager. No complete meeting PCM or arbitrary input path is admitted.
final class NativeAudioAssemblyWorker {
  NativeAudioAssemblyWorker({required this.bindings, required this.executable});
  final NativeLibrary bindings;
  final AudioMediaExecutable executable;
  Future<AudioTransformExecution> start({
    required AudioTransformLease lease,
    required AudioAssemblyManifest manifest,
    required int outputDescriptor,
    required bool Function() current,
  }) async {
    final task = await NativeAudioMediaTask.start(
      bindings: bindings,
      executable: executable,
      request: AudioMediaRequest(
        operation: switch (lease.job.codec) {
          'mp3' => AudioMediaOperation.assembleMp3,
          'opus' => AudioMediaOperation.assembleOpus,
          _ => throw StateError('Unsupported export codec'),
        },
        sessionId: lease.job.sessionId,
        jobId: lease.job.id,
        epoch: lease.leaseGeneration,
        inputSha256: manifest.sha256,
        sourceFrames: manifest.timelineFrames,
      ),
      inputDescriptor: manifest.descriptor,
      outputDescriptor: outputDescriptor,
      ownerLockDescriptor: manifest.media.ownerLockDescriptor,
      inputs: manifest.inputs,
      current: current,
      // Background full-meeting exports may exceed a short chunk deadline.
      total: const Duration(hours: 24),
      // Final archival validation can decode the entire Opus output without a
      // new input page. The worker still bounds each pager wait to ten seconds;
      // total execution/CPU limits and explicit cancellation fence the job.
      idle: const Duration(hours: 24),
    );
    if (!current()) {
      try {
        task.cancel();
      } catch (_) {
        /* Return the real exit owner. */
      }
    }
    return _Execution(task, executable);
  }
}

final class _Execution implements AudioTransformExecution {
  _Execution(this.task, this.executable);
  final NativeAudioMediaTask task;
  final AudioMediaExecutable executable;
  @override
  Future<AudioEncodedResult> get result => task.result.then(
    (r) => AudioEncodedResult(
      sha256: r.outputSha256,
      byteLength: r.outputBytes,
      frames: r.frames,
      preSkip: r.preSkip,
      finalGranule: r.finalGranule,
      workerBuildId: executable.buildId,
      workerSha256: executable.sha256,
    ),
  );
  @override
  Future<void> get closed => task.closed;
  @override
  void cancel() => task.cancel();
}

/// Protected destination publication plus actual native assembly. Durable
/// transform inputs stay leased until the scheduler observes actual retirement.
final class AudioExportMedia {
  AudioExportMedia({
    required this.media,
    required this.destinations,
    required this.startWorker,
  });
  final RecordingMedia media;
  final AudioExportDestinations destinations;
  final AudioAssemblyStart startWorker;

  Future<AudioTransformOperation> prepare(
    AudioTransformLease lease,
    bool Function() current,
  ) async {
    if (lease.job.kind != AudioTransformKind.export ||
        !const ['mp3', 'opus'].contains(lease.job.codec) ||
        lease.job.container != (lease.job.codec == 'opus' ? 'ogg' : 'mp3')) {
      throw const AudioTransformBlocked('Unsupported recording export');
    }
    final destination =
        destinations.leaseForJob(lease.job.id) ??
        await destinations.recover(lease.job, current: current);
    final operation = _Export(this, lease, destination, current);
    try {
      destination.fenceTo(lease);
      if (!destination.hasValidatedOutput) {
        final directory = operation._directory = BackupDirectory(
          media.sessionDirectory(lease.job.sessionId),
          create: false,
        );
        operation._name =
            '${lease.job.id}.${AudioStore.newIdentity()}.assembly';
        operation._manifest = await AudioAssemblyManifest.create(
          media: media,
          lease: lease,
          directory: directory,
          name: operation._name,
          operation: lease.job.codec == 'opus'
              ? AudioMediaOperation.assembleOpus
              : AudioMediaOperation.assembleMp3,
          current: current,
        );
      }
      if (!current()) throw StateError('Export admission cancelled');
      return operation;
    } catch (_) {
      operation.close();
      rethrow;
    }
  }
}

final class _Export implements AudioTransformOperation {
  _Export(this.owner, this.lease, this.destination, this.current);
  final AudioExportMedia owner;
  final AudioTransformLease lease;
  final AudioExportDestinationLease destination;
  final bool Function() current;
  BackupDirectory? _directory;
  AudioAssemblyManifest? _manifest;
  String _name = '';
  bool _started = false, _workerClosed = true, _closed = false;
  @override
  bool get hasValidatedOutput => destination.hasValidatedOutput;
  @override
  Future<AudioTransformExecution> start() async {
    if (_closed || _started || !current() || _manifest == null) {
      throw StateError('Export start refused');
    }
    _started = true;
    destination.beginWorker();
    _workerClosed = false;
    try {
      return await owner.startWorker(
        lease: lease,
        manifest: _manifest!,
        outputDescriptor: destination.outputDescriptor,
        current: current,
      );
    } catch (_) {
      markWorkerClosed();
      rethrow;
    }
  }

  @override
  void markWorkerClosed() {
    _workerClosed = true;
    destination.markWorkerClosed();
  }

  @override
  Future<AudioTransformOutput> publish(AudioEncodedResult? result) async {
    if (!_workerClosed || !current()) {
      throw StateError('Export worker is not closed');
    }
    if (result == null) {
      return AudioTransformOutput(
        metadata: await destination.publishValidated(),
      );
    }
    if (result.frames != _manifest!.timelineFrames ||
        result.byteLength < 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.workerBuildId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.workerSha256) ||
        (lease.job.codec == 'opus'
            ? result.preSkip < 0 ||
                  result.preSkip > 65535 ||
                  result.finalGranule != result.frames + result.preSkip
            : result.preSkip != 0 || result.finalGranule != 0)) {
      throw StateError('Invalid owned assembly result');
    }
    final metadata = await destination.publish(
      sha256: result.sha256,
      byteLength: result.byteLength,
      frames: result.frames,
    );
    return AudioTransformOutput(
      metadata: {
        ...metadata,
        'codec': lease.job.codec,
        'worker_build_id': result.workerBuildId,
        'worker_sha256': result.workerSha256,
        'pre_skip': result.preSkip,
        'final_granule': result.finalGranule,
      },
    );
  }

  @override
  void resetForRetry() => destination.resetForRetry();
  @override
  void abort() => destination.abort();
  @override
  void committed() => destination.committed();
  @override
  void close() {
    if (_closed) return;
    if (!_workerClosed) {
      throw StateError('Cannot close an unfenced export worker');
    }
    destination.markWorkerClosed();
    _closed = true;
    final manifest = _manifest;
    manifest?.close();
    try {
      if (manifest != null && _directory!.entryExists(_name)) {
        _directory!.remove(_name, expectedIdentity: manifest.file.identity);
        _directory!.sync();
      }
    } finally {
      _directory?.close();
      destination.close();
    }
  }
}
