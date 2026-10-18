import 'test_paths.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';

export 'poll.dart';

class RemoteFixture {
  RemoteFixture({this.openStore = Store.new});
  final Store Function(String) openStore;
  bool _hasRoot = false,
      _hasOwner = false,
      _hasServer = false,
      _hasRemote = false;
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
    try {
      root = await createPrivateTempDirectory(shortTestTempRoot, 'of-remote-');
      _hasRoot = true;
      profile = ProfilePaths(
        root.resolveSymbolicLinksSync(),
        root.resolveSymbolicLinksSync(),
      );
      owner = openStore('${profile.data}/application.db');
      _hasOwner = true;
      server = await ServerSocket.bind(
        InternetAddress(
          '${profile.runtime}/application.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
      _hasServer = true;
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
      _hasRemote = true;
    } catch (error, stack) {
      try {
        await close();
      } catch (cleanupError) {
        stderr.writeln('Remote fixture cleanup also failed: $cleanupError');
      }
      Error.throwWithStackTrace(error, stack);
    }
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
    final cleanup = <FutureOr<void> Function()>[];
    if (_hasRemote) {
      _hasRemote = false;
      cleanup.addAll([remote.close, remote.store.close, remote.helper.close]);
    }
    cleanup.add(() {
      for (final socket in sockets) {
        socket.destroy();
      }
      sockets.clear();
    });
    if (_hasServer) {
      _hasServer = false;
      cleanup.add(() async {
        await server.close();
      });
    }
    if (_hasOwner) {
      _hasOwner = false;
      cleanup.add(owner.close);
    }
    if (_hasRoot) {
      _hasRoot = false;
      cleanup.add(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
    }
    Object? failure;
    StackTrace? trace;
    for (final release in cleanup) {
      try {
        await release();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
