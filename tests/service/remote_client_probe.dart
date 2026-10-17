import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/remote.dart';
import 'package:foresight_core/foresight_core.dart' show ProfilePaths;

Future<void> main() async {
  final domain = await RemoteDomain.connect(
    ProfilePaths.resolve(Platform.environment),
  );
  int? replacementPid;
  try {
    final status = await domain.command('status') as Map;
    final firstPid = status['pid'] as int;
    final note =
        await domain.command('notes.save', {
              'title': 'Desktop facade',
              'body': 'service-owned',
            })
            as Map;
    if (domain.store.rows('SELECT body FROM notes WHERE id=?', [
          note['id'],
        ]).single['body'] !=
        'service-owned')
      throw StateError('UI read snapshot missed service write');
    var rejected = false;
    try {
      domain.store.saveNote(null, 'forbidden', '');
    } catch (_) {
      rejected = true;
    }
    if (!rejected) throw StateError('Desktop connection can write');
    final auth = RemoteGoogleAuth(domain);
    final configuration = File(
      '${File(domain.store.path).parent.path}/oauth-fixture.json',
    );
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
        await domain.command('google.cancel_sign_in');
      });
    } catch (error) {
      oauthCancelled = error.toString().toLowerCase().contains('cancel');
    }
    if (!browserInvited || !oauthCancelled)
      throw StateError('Desktop did not receive/cancel the OAuth invitation');
    final update = Completer<void>();
    domain.helper.changed = () {
      if (!update.isCompleted) update.complete();
    };
    // Unchanged service heartbeats no longer rebuild the desktop. Observe an
    // actual committed mutation after subscribing to the change callback.
    await domain.command('notes.save', {
      'id': note['id'],
      'title': 'Desktop facade',
      'body': 'service-owned',
    });
    await update.future.timeout(const Duration(seconds: 5));
    Process.killPid(firstPid, ProcessSignal.sigterm);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final current = await domain.command('status') as Map;
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
    if (domain.store.rows('SELECT body FROM notes WHERE id=?', [
          note['id'],
        ]).single['body'] !=
        'service-owned')
      throw StateError('Data lost after service restart');
    print(
      jsonEncode({
        'browser_invitation_received': browserInvited,
        'oauth_cancelled_cleanly': oauthCancelled,
        'read_only': true,
        'changes': true,
        'reconnected': true,
        'original_pid': firstPid,
        'replacement_pid': replacementPid,
      }),
    );
  } finally {
    domain.close();
    await domain.helper.close();
    domain.store.close();
    if (replacementPid != null)
      Process.killPid(replacementPid, ProcessSignal.sigterm);
  }
}
