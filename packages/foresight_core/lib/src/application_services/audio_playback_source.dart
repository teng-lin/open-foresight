import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../audio_models.dart';
import '../native_lifetime.dart';
import '../persistence/audio_assembly_manifest.dart';
import '../persistence/audio_playback_timeline.dart';
import '../persistence/audio_store.dart';
import '../persistence/backup_files.dart';
import '../persistence/recording_media.dart';
import 'native_audio_media.dart';

abstract interface class AudioPlaybackSource {
  int get totalFrames;
  Future<Int16List> decode(int startFrame, int frameCount);
  void cancel();
  Future<void> close();
}

/// One frozen reader snapshot for a stopped recording, with bounded five-second
/// renders. It owns no output device. Pause/seek closes it after actual child
/// retirement so original-source purging does not wait indefinitely on a player.
final class NativeAudioPlaybackSource implements AudioPlaybackSource {
  NativeAudioPlaybackSource._(
    this.media,
    this.bindings,
    this.executable,
    this.lease,
    this._directory,
    this.totalFrames,
  );
  final RecordingMedia media;
  final NativeLibrary bindings;
  final AudioMediaExecutable executable;
  final AudioTransformLease lease;
  final BackupDirectory _directory;
  @override
  final int totalFrames;
  Future<Int16List>? _reading;
  Future<void>? _closing;
  NativeAudioMediaTask? _task;
  AudioAssemblyManifest? _manifest;
  BackupFile? _output;
  String _manifestName = '', _outputName = '';
  bool _cancelled = false, _closed = false, _unconfirmed = false;

  static NativeAudioPlaybackSource open({
    required RecordingMedia media,
    required NativeLibrary bindings,
    required AudioMediaExecutable executable,
    required String sessionId,
  }) {
    media.ensureAvailable();
    // No await between freezing and claiming: a background turn cannot claim
    // this private reader. Background selection excludes playback jobs too.
    final job = media.audio.createPlaybackJob(sessionId);
    final lease = media.audio.claimTransformJob(
      job.id,
      ownerGeneration: media.ownerGeneration,
      nowMs: 0,
    );
    if (lease == null) {
      throw StateError('Playback snapshot could not be claimed');
    }
    BackupDirectory? directory;
    try {
      directory = BackupDirectory(
        media.sessionDirectory(sessionId),
        create: false,
      );
      final frames = AudioPlaybackTimeline.frozenFrames(lease.job.settings);
      if (frames < 1 || frames > AudioAssemblyManifest.maximumFrames) {
        throw StateError('Playback duration exceeds supported range');
      }
      return NativeAudioPlaybackSource._(
        media,
        bindings,
        executable,
        lease,
        directory,
        frames,
      );
    } catch (_) {
      directory?.close();
      media.audio.releasePlaybackLease(lease);
      rethrow;
    }
  }

  bool _current() {
    if (_closed || _cancelled || _unconfirmed) return false;
    try {
      media.ensureAvailable();
      final job = media.audio.transformJob(lease.job.id);
      return job?.state == AudioJobState.running &&
          job?.ownerGeneration == lease.ownerGeneration &&
          job?.leaseGeneration == lease.leaseGeneration;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Int16List> decode(int startFrame, int frameCount) {
    if (!_current() ||
        _reading != null ||
        startFrame < 0 ||
        frameCount < 1 ||
        frameCount > 240000 ||
        startFrame + frameCount > totalFrames) {
      return Future.error(StateError('Playback decode admission refused'));
    }
    late final Future<Int16List> work;
    work = _decode(startFrame, frameCount).whenComplete(() => _reading = null);
    _reading = work;
    work.ignore();
    return work;
  }

  Future<Int16List> _decode(int start, int count) async {
    try {
      _manifestName = '${AudioStore.newIdentity()}.playback.assembly';
      _manifest = await AudioAssemblyManifest.create(
        media: media,
        lease: lease,
        directory: _directory,
        name: _manifestName,
        operation: AudioMediaOperation.assemblePcm,
        startFrame: start,
        frameCount: count,
        current: _current,
      );
      if (!_current()) throw StateError('Playback was cancelled');
      _outputName = '${AudioStore.newIdentity()}.playback.pcm';
      _output = _directory.open(_outputName, create: true);
      final task = _task = await NativeAudioMediaTask.start(
        bindings: bindings,
        executable: executable,
        request: AudioMediaRequest(
          operation: AudioMediaOperation.assemblePcm,
          sessionId: lease.job.sessionId,
          jobId: lease.job.id,
          epoch: lease.leaseGeneration,
          inputSha256: _manifest!.sha256,
          sourceFrames: totalFrames,
          startFrame: start,
          frameCount: count,
        ),
        inputDescriptor: _manifest!.descriptor,
        outputDescriptor: _output!.descriptor,
        ownerLockDescriptor: media.ownerLockDescriptor,
        inputs: _manifest!.inputs,
        current: _current,
      );
      task.closed.ignore();
      if (!_current()) {
        try {
          task.cancel();
        } catch (_) {
          /* Still join actual exit. */
        }
      }
      AudioMediaResult? result;
      Object? failure;
      StackTrace? trace;
      try {
        result = await task.result;
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      try {
        await task.closed;
      } catch (_) {
        _unconfirmed = true;
        rethrow;
      }
      _task = null;
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
      if (!_current() ||
          result!.frames != count ||
          result.outputBytes != count * 2) {
        throw StateError('Playback output was cancelled or changed');
      }
      final path = _directory.path,
          name = _outputName,
          identity = _output!.identity,
          digest = result.outputSha256;
      final pcm = await Isolate.run(
        () => _readPcm(path, name, identity, digest, count),
      );
      if (!_current()) throw StateError('Playback was cancelled');
      return pcm;
    } finally {
      // An unconfirmed native exit retains the actual owner, source references,
      // manifest/output descriptors and directory until process-owned recovery.
      if (!_unconfirmed) _cleanup();
    }
  }

  void _cleanup() {
    final output = _output, manifest = _manifest;
    _output = null;
    _manifest = null;
    try {
      output?.close();
      manifest?.close();
      if (output != null && _directory.entryExists(_outputName)) {
        _directory.remove(_outputName, expectedIdentity: output.identity);
      }
      if (manifest != null && _directory.entryExists(_manifestName)) {
        _directory.remove(
          _manifestName,
          expectedIdentity: manifest.file.identity,
        );
      }
      _directory.sync();
    } finally {
      output?.close();
      manifest?.close();
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _task?.cancel();
  }

  @override
  Future<void> close() => _closing ??= () async {
    _cancelled = true;
    try {
      _task?.cancel();
    } catch (_) {
      // Cancellation control failure never substitutes for the exit fence.
    }
    try {
      await _reading;
    } catch (_) {
      /* The caller owns a decode failure. */
    }
    if (_unconfirmed) {
      throw StateError('Playback worker ownership is unconfirmed');
    }
    _closed = true;
    try {
      _cleanup();
    } finally {
      _directory.close();
      media.audio.releasePlaybackLease(lease);
    }
  }();
}

Int16List _readPcm(
  String path,
  String name,
  String identity,
  String digest,
  int frames,
) {
  final directory = BackupDirectory(path, create: false);
  BackupFile? file;
  try {
    file = directory.open(name, readOnly: true);
    if (file.identity != identity || file.size != frames * 2) {
      throw StateError('Playback PCM extent changed');
    }
    final bytes = file.readSmall(480000);
    if (bytes.length != frames * 2 ||
        crypto.sha256.convert(bytes).toString() != digest) {
      throw StateError('Playback PCM hash changed');
    }
    final data = ByteData.sublistView(bytes), pcm = Int16List(frames);
    for (var i = 0; i < frames; i++) {
      pcm[i] = data.getInt16(i * 2, Endian.little);
    }
    return pcm;
  } finally {
    file?.close();
    directory.close();
  }
}
