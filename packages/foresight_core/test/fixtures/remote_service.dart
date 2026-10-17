import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:matcher/expect.dart';

Future<void> eventually(bool Function() predicate) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not observed');
}

class RemoteFixture {
  late Directory root;
  late ProfilePaths profile;
  late Store owner;
  late ServerSocket server;
  late RemoteDomain remote;
  final sockets = <Socket>[];
  final requests = <Map<String, dynamic>>[];
  Map<String, dynamic> status = {
    'capture': <String, dynamic>{},
    'google': <String, dynamic>{},
    'sources_paused': false,
    'generation': <String, dynamic>{},
    'web_search_available': false,
  };
  void Function(Socket, Map<String, dynamic>)? handler;

  Future<void> start() async {
    root = await createPrivateTempDirectory(Directory('/tmp'), 'of-remote-');
    profile = ProfilePaths(
      root.resolveSymbolicLinksSync(),
      root.resolveSymbolicLinksSync(),
    );
    owner = Store('${profile.data}/application.db');
    owner.db.execute(
      'CREATE TABLE calendar_events(meeting_id INTEGER,metadata TEXT)',
    );
    server = await ServerSocket.bind(
      InternetAddress(
        '${profile.runtime}/application.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    server.listen((socket) {
      sockets.add(socket);
      unawaited(socket.done.catchError((Object _) {}));
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final message = jsonDecode(line) as Map<String, dynamic>;
            requests.add(message);
            if (message.containsKey('cancel')) return;
            if (message['method'] == 'status') {
              reply(socket, message, status);
            } else {
              handler?.call(socket, message);
            }
          }, onError: (Object _) {});
    });
    remote = await RemoteDomain.connect(profile);
  }

  void reply(
    Socket socket,
    Map<String, dynamic> request,
    Object? value, {
    bool done = true,
  }) {
    socket.writeln(
      jsonEncode({'id': request['id'], 'result': value, 'done': done}),
    );
  }

  void event(Map<String, dynamic> state) {
    sockets.last.writeln(jsonEncode({'event': 'changed', ...state}));
  }

  Future<void> close() async {
    remote.close();
    remote.store.close();
    await remote.helper.close();
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
    owner.close();
    root.deleteSync(recursive: true);
  }
}
