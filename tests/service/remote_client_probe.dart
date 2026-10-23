import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/desktop_bootstrap.dart';

String noteSnapshot(StoreReader reader) => jsonEncode([
  for (final note in reader.noteSummaries)
    {
      'id': note.id,
      'title': note.title,
      'revision': note.revision,
      'body': reader.noteBody(note.id),
    },
]);

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
    if (domain.store.noteBody(noteId) != 'service-owned')
      throw StateError('UI read snapshot missed service write');
    final beforeForbiddenWrite = noteSnapshot(domain.store);
    var rejected = false;
    try {
      // Deliberately probe the runtime capability boundary. The public reader
      // must not retain a hidden writer method after the facade migration.
      (domain.store as dynamic).saveNote(null, 'forbidden', '');
    } on NoSuchMethodError {
      rejected = true;
    }
    if (!rejected) throw StateError('Desktop connection can write');
    if (noteSnapshot(domain.store) != beforeForbiddenWrite)
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
    final beforeChange = noteSnapshot(domain.store);
    changes = domain.changes.listen((_) {
      if (!update.isCompleted && noteSnapshot(domain.store) != beforeChange)
        update.complete();
    });
    // Unchanged service heartbeats no longer rebuild the desktop. Observe an
    // actual committed mutation after subscribing to the change callback.
    await domain.command(Operation.notesSave, {
      'id': note['id'],
      'title': 'Desktop facade',
      'body': 'service-owned',
    });
    await update.future.timeout(const Duration(seconds: 5));
    final beforeRestart = noteSnapshot(domain.store);
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
    if (domain.store.noteBody(noteId) != 'service-owned')
      throw StateError('Data lost after service restart');
    if (noteSnapshot(domain.store) != beforeRestart)
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
