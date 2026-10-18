import 'rpc_error.dart';
import 'operations.dart';
import 'dart:async';
import 'dart:io';
import 'profile_paths.dart';

/// Agent imports are limited to folders explicitly selected in the desktop.
/// Canonical paths prevent both '..' and symlink escapes into private state.
class ImportPolicy {
  final String profile;
  final List<String> Function() roots;
  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxDirectoryEntries = 10000;
  static const maxDirectoryFiles = 1000;
  ImportPolicy(String profile, this.roots)
    : profile = canonicalProfilePath(profile);

  bool _within(String path, String root) =>
      path == root || path.startsWith('$root/');

  String validate(String path, {bool directory = false}) {
    final type = FileSystemEntity.typeSync(path);
    if (type !=
        (directory
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file)) {
      throw StateError(
        'Imports require a regular ${directory ? 'directory' : 'file'}',
      );
    }
    final canonical = File(path).resolveSymbolicLinksSync();
    if (_within(canonical, profile)) {
      throw StateError('The application profile cannot be imported');
    }
    if (!roots().any(
      (root) => _within(canonical, canonicalProfilePath(root)),
    )) {
      throw StateError('Select this import folder in the desktop first');
    }
    if (!directory && File(canonical).lengthSync() > maxFileBytes) {
      throw StateError('File exceeds the 10 MiB import limit');
    }
    return canonical;
  }

  Future<List<String>> directoryFiles(String path) async {
    final pending = [validate(path, directory: true)];
    final files = <String>[];
    var entries = 0;
    var bytes = 0;
    while (pending.isNotEmpty) {
      await for (final entry in Directory(
        pending.removeLast(),
      ).list(followLinks: false)) {
        if (++entries > maxDirectoryEntries)
          throw StateError('Directory entry limit exceeded');
        if (entry is Directory) {
          pending.add(validate(entry.path, directory: true));
        } else if (entry is File &&
            RegExp(
              r'\.(txt|md|pdf|rtf)$',
              caseSensitive: false,
            ).hasMatch(entry.path)) {
          final file = validate(entry.path);
          bytes += File(file).lengthSync();
          if (bytes > 100 * 1024 * 1024 || files.length >= maxDirectoryFiles) {
            throw StateError('Directory import limit exceeded');
          }
          files.add(file);
        }
      }
    }
    return files;
  }
}

/// Approval decisions belong to a single live desktop connection and request.
/// Tokens authenticate the desktop; they never grant agent connections rights.
class AgentAccessGate {
  final String desktopToken;
  final void Function(Object host, Map<String, Object?> event) send;
  final Duration timeout;
  Object? _host;
  int _next = 0;
  final _pending = <String, ({Object client, Completer<bool> done})>{};
  AgentAccessGate(
    this.desktopToken,
    this.send, {
    this.timeout = const Duration(minutes: 2),
  });

  bool get hasHost => _host != null;
  bool isHost(Object client) => identical(client, _host);
  void attach(Object client, String token) {
    if (token != desktopToken || token.isEmpty)
      throw RpcError(RpcErrorCode.denied, 'Invalid desktop capability');
    if (_host != null && !isHost(client))
      throw RpcError(
        RpcErrorCode.busy,
        'A desktop approval window is already connected',
      );
    _host = client;
  }

  void detach(Object client) {
    if (isHost(client)) _host = null;
    for (final entry in _pending.entries.toList()) {
      if (_host == null || identical(entry.value.client, client)) {
        if (!entry.value.done.isCompleted) entry.value.done.complete(false);
        _pending.remove(entry.key);
      }
    }
  }

  void decide(Object client, String id, bool allow) {
    if (!isHost(client))
      throw RpcError(
        RpcErrorCode.denied,
        'Only the visible desktop can approve requests',
      );
    final pending = _pending[id];
    if (pending == null)
      throw RpcError(RpcErrorCode.notFound, 'Approval expired');
    if (!pending.done.isCompleted) pending.done.complete(allow);
  }

  static bool needsApproval(String method, Map<String, dynamic> args) {
    return Operation.parse(
      method,
    ).requiresApproval(webSearch: args['web_search'] == true);
  }

  Future<void> authorize(
    Object client,
    String method,
    Map<String, dynamic> args, {
    required bool Function() current,
  }) async {
    final capture =
        method == Operation.meetings_start.wire ||
        method == Operation.meetings_resume.wire;
    if (!needsApproval(method, args)) return;
    if (isHost(client) && !capture) return;
    final host = _host;
    if (host == null)
      throw RpcError(
        RpcErrorCode.denied,
        'Open the desktop app to review this operation',
      );
    if (_pending.length >= 8)
      throw RpcError(RpcErrorCode.busy, 'Too many pending approval requests');
    final id = 'approval-${++_next}';
    final done = Completer<bool>();
    _pending[id] = (client: client, done: done);
    send(host, {
      'event': 'approval',
      'approval_id': id,
      'method': method,
      'args': args,
    });
    try {
      final allowed = await done.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      if (!allowed || !identical(_host, host) || !current()) {
        throw RpcError(
          !current() ? RpcErrorCode.cancelled : RpcErrorCode.denied,
          'Operation was denied, cancelled, or its desktop approval expired',
        );
      }
    } finally {
      _pending.remove(id);
      send(host, {'event': 'approval_closed', 'approval_id': id});
    }
  }
}
