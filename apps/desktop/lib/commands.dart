import 'desktop_environment.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A per-profile, private Unix socket lets a launcher activate the owning app
/// without opening its database or marking an active recording interrupted.
typedef CommandAction = Future<void> Function(String, String?);

class AppCommands {
  final ServerSocket server;
  final String path;
  final RandomAccessFile _lock;
  final _handler = Completer<CommandAction>();
  bool _closed = false;
  bool _released = false;

  /// The listening socket and activation lock have both been released.
  bool get isClosed => _released;
  void Function(Object error)? onError;
  AppCommands._(this.server, this.path, this._lock) {
    server.listen(
      (socket) => unawaited(
        _accept(socket).catchError((Object error) {
          socket.destroy();
          onError?.call(error);
        }),
      ),
    );
  }
  void setHandler(CommandAction action) {
    if (!_handler.isCompleted) _handler.complete(action);
  }

  static Future<bool> forward(
    String path, {
    String? activationToken,
    bool quick = true,
    String? command,
    String? authUrl,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 1),
      );
      socket.write(
        '${jsonEncode({'version': 1, 'command': command ?? (quick ? 'quick-meeting' : 'activate'), if (activationToken != null) 'activation_token': activationToken, if (authUrl != null) 'auth_url': authUrl})}\n',
      );
      await socket.flush();
      final response = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 3));
      // Acknowledges dispatch; completion/failure is shown by the owning UI.
      return response == 'queued' || response == 'accepted';
    } on SocketException {
      return false;
    } on OSError {
      // A connect that waited while the running desktop closed its listener
      // fails with the socket's pending error as a bare OSError.
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<AppCommands> bind(
    String path, {
    CommandAction? action,
    DesktopEnvironment environment = const DesktopEnvironment(),
  }) async {
    final lock = File('$path.lock').openSync(mode: FileMode.append);
    try {
      // Nonblocking OS lock lives with the owner. A second process cannot
      // unlink the live socket even if its initial connection probe failed.
      lock.lockSync(FileLock.exclusive);
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
    try {
      final stale = File(path);
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound)
        stale.deleteSync();
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final mode = await environment.run('/bin/chmod', ['600', path]);
      if (mode.exitCode != 0) {
        await server.close();
        throw StateError('Cannot protect activation socket');
      }
      final result = AppCommands._(server, path, lock);
      if (action != null) result.setHandler(action);
      return result;
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
  }

  Future<void> _accept(Socket socket) async {
    try {
      var bytes = 0;
      final line = await socket
          .map((chunk) {
            bytes += chunk.length;
            if (bytes > 20000) throw StateError('Activation command too large');
            return chunk;
          })
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      final message = jsonDecode(line) as Map;
      if (_closed ||
          message['version'] != 1 ||
          ![
            'quick-meeting',
            'stop-meeting',
            'activate',
            'calendar-auth',
          ].contains(message['command']) ||
          (message['command'] == 'calendar-auth' &&
              (message['auth_url'] is! String ||
                  !(message['auth_url'] as String).startsWith(
                    'open-foresight://login-in-progress?',
                  )))) {
        socket.writeln('rejected');
      } else {
        socket.writeln('queued');
        await socket.flush();
        unawaited(
          _handler.future
              .then(
                (action) => action(
                  message['command'] as String,
                  message[message['command'] == 'calendar-auth'
                          ? 'auth_url'
                          : 'activation_token']
                      as String?,
                ),
              )
              .catchError((Object error) {
                if (onError != null)
                  onError!(error);
                else
                  stderr.writeln('Global shortcut failed: $error');
              }),
        );
      }
      await socket.flush();
    } catch (_) {
    } finally {
      socket.destroy();
    }
  }

  Future<void> close() async {
    _closed = true;
    if (!_handler.isCompleted) _handler.complete((_, _) async {});
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound)
      File(path).deleteSync();
    await server.close();
    _lock.closeSync();
    _released = true;
  }
}
