import 'dart:isolate';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'backup_files.dart';
import 'recording_media.dart';

final class AudioErasureProgress {
  const AudioErasureProgress({
    required this.sessionsCompleted,
    required this.filesRemoved,
  });
  final int sessionsCompleted, filesRemoved;
}

/// Completes SQL tombstones only after real capture/work/read owners have been
/// fenced. Owns the private managed subtree, never a selected final export.
final class AudioMediaErasure {
  AudioMediaErasure({required this.media, required this.sessionQuiesced});
  final RecordingMedia media;

  /// Service-owned lifecycle evidence, not a flag decoded from a request or a
  /// stopped DB row. Startup may acknowledge after inherited-owner recovery.
  final bool Function(String sessionId) sessionQuiesced;
  Future<AudioErasureProgress>? _work;
  String _afterGeneration = '', _afterSession = '';

  Future<AudioErasureProgress> drain({
    required bool Function() current,
    int limit = 16,
    int filesPerSession = 64,
  }) {
    if (limit < 1 ||
        limit > 64 ||
        filesPerSession < 1 ||
        filesPerSession > 128) {
      throw ArgumentError('Invalid erasure batch');
    }
    if (_work case final work?) return work;
    late final Future<AudioErasureProgress> work;
    work = _drain(current, limit, filesPerSession).whenComplete(() {
      if (identical(_work, work)) _work = null;
    });
    _work = work;
    work.ignore();
    return work;
  }

  /// Finish this exact durable intent before acknowledging recording deletion.
  /// Batches yield between bounded filesystem passes. Unrelated tombstones do
  /// not consume the target's budget or hide it behind unsafe older entries.
  Future<AudioErasureProgress> eraseSession(
    String sessionId,
    String generation, {
    required bool Function() current,
    int filesPerBatch = 64,
  }) {
    if (filesPerBatch < 1 || filesPerBatch > 128) {
      throw ArgumentError.value(filesPerBatch, 'filesPerBatch');
    }
    final previous = _work;
    late final Future<AudioErasureProgress> work;
    work =
        () async {
          try {
            await previous;
          } catch (_) {
            // Join the real owner; an unrelated refused entry cannot prevent the
            // selected recording's independently authorized erasure.
          }
          var removed = 0;
          while (true) {
            if (!current() || !sessionQuiesced(sessionId)) {
              throw StateError('Recording erasure ownership changed');
            }
            media.ensureAvailable();
            _validateIdentity(generation, sessionId);
            final store = media.audio;
            if (store.session(sessionId) != null) {
              throw StateError('An extant session cannot be erased');
            }
            final intents = store.db.select(
              'SELECT generation FROM audio_erasure_intents WHERE session_id=?',
              [sessionId],
            );
            if (intents.isEmpty) {
              return AudioErasureProgress(
                sessionsCompleted: removed == 0 ? 0 : 1,
                filesRemoved: removed,
              );
            }
            if (!intents.any((row) => row['generation'] == generation) ||
                !_authorized(generation, sessionId, current)) {
              throw StateError('Recording erasure intent changed');
            }
            final progress = await _eraseOffThread(
              p.dirname(media.store.path),
              generation,
              sessionId,
              filesPerBatch,
            );
            removed += progress.files;
            if (!_authorized(generation, sessionId, current)) {
              throw StateError('Recording erasure ownership changed');
            }
            if (progress.complete) {
              store.completeErasure(sessionId, generation);
              return AudioErasureProgress(
                sessionsCompleted: 1,
                filesRemoved: removed,
              );
            }
            if (progress.files == 0) {
              throw StateError('Recording erasure made no safe progress');
            }
            await Future<void>.delayed(Duration.zero);
          }
        }().whenComplete(() {
          if (identical(_work, work)) _work = null;
        });
    _work = work;
    work.ignore();
    return work;
  }

  Future<void> fence() async {
    await _work;
  }

  bool _authorized(String generation, String session, bool Function() current) {
    if (!current() || !sessionQuiesced(session)) return false;
    // Access proves the service still owns the inherited-worker lock.
    media.ownerLockDescriptor;
    if (!media.binding.matches(media.audio.storageGeneration)) {
      return false;
    }
    _validateIdentity(generation, session);
    final store = media.audio;
    if (store.session(session) != null) {
      throw StateError('An extant session cannot be erased');
    }
    return store.db.select(
      'SELECT 1 FROM audio_erasure_intents WHERE session_id=? AND generation=?',
      [session, generation],
    ).isNotEmpty;
  }

  Future<AudioErasureProgress> _drain(
    bool Function() current,
    int limit,
    int files,
  ) async {
    final store = media.audio;
    List<Map<String, Object?>> page(String generation, String session) => store
        .db
        .select(
          'SELECT session_id,generation FROM audio_erasure_intents WHERE generation>? OR (generation=? AND session_id>?) ORDER BY generation,session_id LIMIT ?',
          [generation, generation, session, limit],
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    var rows = page(_afterGeneration, _afterSession);
    if (rows.isEmpty && _afterGeneration.isNotEmpty) {
      _afterGeneration = _afterSession = '';
      rows = page('', '');
    }
    var completed = 0, removed = 0;
    Object? failure;
    StackTrace? trace;
    for (final row in rows) {
      final generation = row['generation'] as String,
          session = row['session_id'] as String;
      _afterGeneration = generation;
      _afterSession = session;
      if (!_authorized(generation, session, current)) continue;
      final profile = p.dirname(media.store.path);
      try {
        final progress = await _eraseOffThread(
          profile,
          generation,
          session,
          files,
        );
        removed += progress.files;
        if (progress.complete && _authorized(generation, session, current)) {
          store.completeErasure(session, generation);
          completed++;
        }
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    // Other safe tombstones progressed; a refused entry still remains durable.
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
    return AudioErasureProgress(
      sessionsCompleted: completed,
      filesRemoved: removed,
    );
  }
}

void _validateIdentity(String generation, String session) {
  final uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  if (!uuid.hasMatch(session) ||
      !(uuid.hasMatch(generation) ||
          RegExp(r'^[a-f0-9]{32}$').hasMatch(generation))) {
    throw StateError('Invalid media erasure identity');
  }
}

Future<({bool complete, int files})> _eraseOffThread(
  String profile,
  String generation,
  String session,
  int files,
) => Isolate.run(() => _eraseBatch(profile, generation, session, files));

({bool complete, int files}) _eraseBatch(
  String profilePath,
  String generationId,
  String sessionId,
  int limit,
) {
  final profile = BackupDirectory(profilePath, create: false, private: false);
  BackupDirectory? recordings, generation, session;
  try {
    if (!profile.entryExists('recordings')) return (complete: true, files: 0);
    recordings = profile.child('recordings', create: false);
    if (!recordings.entryExists(generationId)) {
      return (complete: true, files: 0);
    }
    generation = recordings.child(generationId, create: false);
    if (!generation.entryExists(sessionId)) return (complete: true, files: 0);
    session = generation.child(sessionId, create: false);
    final names = <String>[];
    var more = false;
    session.visitEntries((name) {
      if (names.length == limit) {
        more = true;
        return false;
      }
      names.add(name);
      return true;
    });
    var removed = 0;
    for (final name in names) {
      session.verifyAnchor();
      generation.verifyAnchor();
      recordings.verifyAnchor();
      profile.verifyAnchor();
      // Metadata refuses symlinks, subdirectories, hardlinks, foreign ownership
      // and public files. A refusal preserves both entry and SQL tombstone.
      final identity = session.metadata(name).identity;
      session.remove(name, expectedIdentity: identity);
      removed++;
    }
    session.sync();
    if (more) return (complete: false, files: removed);
    generation.removeEmptyChild(session);
    return (complete: true, files: removed);
  } finally {
    session?.close();
    generation?.close();
    recordings?.close();
    profile.close();
  }
}
