import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/desktop_bootstrap.dart';

/// A snapshot may span several typed reads, but never owners or revisions.
/// Reuse the probe's five-second change-observation budget for fresh reads.
Future<String> noteSnapshot(
  DesktopConnection domain, {
  DateTime? deadline,
}) async {
  final until = deadline ?? DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(until)) {
    final session = domain.clientSessionGeneration;
    final epoch = domain.workspaceEpoch;
    final reader = domain.store;
    final revision = reader.dataRevision;
    bool current() =>
        identical(session, domain.clientSessionGeneration) &&
        identical(reader, domain.store) &&
        epoch == domain.workspaceEpoch &&
        epoch == reader.workspaceEpoch &&
        revision == reader.dataRevision;
    final notes = await reader
        .read(StoreReadQueries.notes())
        .timeout(until.difference(DateTime.now()));
    if (current() && notes.error != null) throw notes.error!;
    if (current() && notes.current && notes.requestTag == revision) {
      final rows = <Map<String, Object?>>[];
      var complete = true;
      for (final note in notes.value!) {
        final remaining = until.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        final body = await reader
            .read(StoreReadQueries.noteBody(note.id))
            .timeout(remaining);
        if (current() && body.error != null) throw body.error!;
        if (!current() || !body.current || body.requestTag != revision) {
          complete = false;
          break;
        }
        rows.add({
          'id': note.id,
          'title': note.title,
          'revision': note.revision,
          'body': body.value,
        });
      }
      if (current() && complete && rows.length == notes.value!.length)
        return jsonEncode(rows);
    }
    final remaining = until.difference(DateTime.now());
    if (remaining <= Duration.zero) break;
    await Future<void>.delayed(
      remaining < const Duration(milliseconds: 10)
          ? remaining
          : const Duration(milliseconds: 10),
    );
  }
  throw TimeoutException('Desktop note snapshot did not become current');
}

Future<String?> noteBody(DesktopConnection domain, int id) async {
  final rows = jsonDecode(await noteSnapshot(domain)) as List;
  return (rows.singleWhere((row) => (row as Map)['id'] == id) as Map)['body']
      as String?;
}

Future<void> main() async => print(jsonEncode(await runRemoteClientProbe()));

Future<Map<String, Object?>> runRemoteClientProbe() async {
  final profile = ProfilePaths.resolve(Platform.environment);
  final domain = await connectDesktop(profile);
  int? replacementPid;
  StreamSubscription<void>? changes;
  try {
    final status = await domain.command(Operation.status) as Map;
    final firstPid = status['pid'] as int;
    final note =
        await domain.command(Operation.notesSave, {
              'title': 'Desktop facade',
              'body': 'service-owned',
            })
            as Map;
    final noteId = note['id'] as int;
    if (await noteBody(domain, noteId) != 'service-owned')
      throw StateError('UI read snapshot missed service write');
    final beforeForbiddenWrite = await noteSnapshot(domain);
    var rejected = false;
    try {
      // Deliberately probe the runtime capability boundary. The public reader
      // must not retain a hidden writer method after the facade migration.
      (domain.store as dynamic).saveNote(null, 'forbidden', '');
    } on NoSuchMethodError {
      rejected = true;
    }
    if (!rejected) throw StateError('Desktop connection can write');
    if (await noteSnapshot(domain) != beforeForbiddenWrite)
      throw StateError('Forbidden desktop write changed persisted notes');
    final auth = domain.googleAuth;
    final configuration = File('${profile.data}/oauth-fixture.json');
    await configuration.writeAsString(
      jsonEncode({
        'installed': {
          'client_id': 'fixture.apps.googleusercontent.com',
          'client_secret': 'controlled-fixture',
        },
      }),
    );
    await auth.configure(configuration);
    var browserInvited = false, oauthCancelled = false;
    try {
      await auth.signIn((uri) async {
        browserInvited =
            uri.scheme == 'https' && uri.host == 'accounts.google.com';
        await domain.command(Operation.googleCancelSignIn);
      });
    } catch (error) {
      oauthCancelled = error.toString().toLowerCase().contains('cancel');
    }
    if (!browserInvited || !oauthCancelled)
      throw StateError('Desktop did not receive/cancel the OAuth invitation');
    final update = Completer<void>();
    // A typed read can fail before the mutation reply; retain it for the await.
    update.future.ignore();
    final beforeChange = await noteSnapshot(domain);
    final changeDeadline = DateTime.now().add(const Duration(seconds: 5));
    Future<void> checkingChange = Future.value();
    changes = domain.changes.listen((_) {
      checkingChange = checkingChange.then((_) async {
        if (update.isCompleted) return;
        try {
          if (await noteSnapshot(domain, deadline: changeDeadline) !=
              beforeChange)
            update.complete();
        } catch (error, stack) {
          if (!update.isCompleted) update.completeError(error, stack);
        }
      });
    });
    // Unchanged service heartbeats no longer rebuild the desktop. Observe an
    // actual committed mutation after subscribing to the change callback.
    await domain.command(Operation.notesSave, {
      'id': note['id'],
      'title': 'Desktop facade',
      'body': 'service-owned',
    });
    await update.future.timeout(const Duration(seconds: 5));
    final beforeRestart = await noteSnapshot(domain);
    Process.killPid(firstPid, ProcessSignal.sigterm);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final current = await domain.command(Operation.status) as Map;
        if (current['pid'] != firstPid) {
          replacementPid = current['pid'] as int;
          break;
        }
      } catch (_) {
        /* An in-flight request fails rather than being replayed. */
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (replacementPid == null) throw StateError('Desktop did not reconnect');
    if (await noteBody(domain, noteId) != 'service-owned')
      throw StateError('Data lost after service restart');
    if (await noteSnapshot(domain) != beforeRestart)
      throw StateError('Reconnect replayed or changed a persisted mutation');
    return {
      'browser_invitation_received': browserInvited,
      'oauth_cancelled_cleanly': oauthCancelled,
      'read_only': true,
      'changes': true,
      'reconnected': true,
      'no_mutation_replay': true,
      'original_pid': firstPid,
      'replacement_pid': replacementPid,
    };
  } finally {
    await changes?.cancel();
    domain.close();
    await domain.closed;
    if (replacementPid != null)
      Process.killPid(replacementPid, ProcessSignal.sigterm);
  }
}
