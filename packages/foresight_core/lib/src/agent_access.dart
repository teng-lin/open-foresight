import 'rpc_error.dart';
import 'operations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'profile_paths.dart';
import 'runtime_execution_policy.dart';
import 'native.dart' show liteRtRunner;

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
        if (++entries > maxDirectoryEntries) {
          throw StateError('Directory entry limit exceeded');
        }
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

/// Whether an event reached a connection, and if not, why.
enum EventDelivery {
  sent,

  /// The event exceeds the frame limit, so it was dropped.
  tooLarge,

  /// The event holds a value JSON cannot represent, such as NaN or Infinity,
  /// so it was dropped.
  unencodable,

  /// Writing to the connection failed; the connection has been closed.
  writeFailed,
}

/// Approval decisions belong to a single live desktop connection and request.
/// Tokens authenticate the desktop; they never grant agent connections rights.
class AgentAccessGate {
  String desktopToken;
  final void Function(String token)? rotateToken;

  /// Writes an event to the host's connection and says whether it got there.
  final EventDelivery Function(Object host, Map<String, Object?> event) send;
  final Duration timeout;
  final DateTime Function() now;
  final _recent =
      Map<Object, List<({String fingerprint, DateTime at})>>.identity();
  Object? _host;
  bool _visible = false;
  final _random = Random.secure();
  final _pending = <String, ({Object client, Completer<bool> done})>{};
  AgentAccessGate(
    this.desktopToken,
    this.send, {
    this.timeout = const Duration(minutes: 2),
    this.rotateToken,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  bool get hasHost => _host != null;
  bool get hasVisibleHost => hasHost && _visible;
  bool isHost(Object client) => identical(client, _host);
  void attach(
    Object client,
    String token, {
    required bool verifiedDesktop,
    bool visible = true,
  }) {
    if (!verifiedDesktop) {
      throw RpcError(
        RpcErrorCode.denied,
        'Only the verified desktop process can attach',
      );
    }
    if (token != desktopToken || token.isEmpty) {
      throw RpcError(RpcErrorCode.denied, 'Invalid desktop capability');
    }
    final next = base64Url.encode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    rotateToken?.call(next);
    if (_host case final previous?) detach(previous);
    desktopToken = next;
    _host = client;
    _visible = visible;
  }

  void setVisible(Object client, bool visible) {
    if (!isHost(client)) {
      throw RpcError(
        RpcErrorCode.denied,
        'Only the desktop host can report window visibility',
      );
    }
    _visible = visible;
    if (!visible) {
      for (final pending in _pending.values) {
        if (!pending.done.isCompleted) pending.done.complete(false);
      }
    }
  }

  void detach(Object client) {
    _recent.remove(client);
    if (isHost(client)) {
      _host = null;
      _visible = false;
    }
    for (final entry in _pending.entries.toList()) {
      if (_host == null || identical(entry.value.client, client)) {
        if (!entry.value.done.isCompleted) entry.value.done.complete(false);
        _pending.remove(entry.key);
      }
    }
  }

  void decide(Object client, String id, bool allow) {
    if (!isHost(client) || !_visible) {
      throw RpcError(
        RpcErrorCode.denied,
        'Only the visible desktop can approve requests',
      );
    }
    final pending = _pending[id];
    if (pending == null) {
      throw RpcError(RpcErrorCode.notFound, 'Approval expired');
    }
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
    if (!needsApproval(method, args)) return;
    // The authenticated desktop's Start/Resume controls are direct user
    // consent. External clients still require a per-operation desktop decision.
    // Embedding's runtime field is tokenizer data, not executable code.
    final embeddingData =
        method == Operation.modelsEmbedding.wire ||
        (method == Operation.modelsRegister.wire &&
            args['kind'] == 'embedding');
    if (method.startsWith('models.') &&
        !embeddingData &&
        args['runtime'] is String) {
      final generation =
          (method == Operation.modelsGeneration.wire &&
              (args['backend'] ?? 'litert_lm') == 'litert_lm') ||
          (method == Operation.modelsRegister.wire &&
              args['kind'] == 'generation' &&
              args['backend'] == 'litert_lm');
      final runtime = args['runtime'] as String;
      requireInstalledRuntime(generation ? liteRtRunner(runtime) : runtime);
    }
    if (isHost(client) && hasVisibleHost) return;
    final host = _host;
    if (host == null || !_visible) {
      throw RpcError(
        RpcErrorCode.denied,
        'Open the desktop app to review this operation',
        reason: RpcErrorReason.needsDesktop,
      );
    }
    final time = now();
    final recent = _recent.putIfAbsent(client, () => []);
    recent.removeWhere(
      (entry) => time.difference(entry.at) >= const Duration(minutes: 1),
    );
    final entries =
        args.entries
            .where((e) => e.key != 'requestId' && e.key != 'conversation')
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final fingerprint = '$method:${jsonEncode(Map.fromEntries(entries))}';
    if (recent.where((entry) => entry.fingerprint == fingerprint).length >= 3) {
      throw RpcError(
        RpcErrorCode.busy,
        'Repeated identical approval requests are rate limited. Retry in one minute.',
      );
    }
    if (_pending.length >= 8) {
      throw RpcError(RpcErrorCode.busy, 'Too many pending approval requests');
    }
    recent.add((fingerprint: fingerprint, at: time));
    // Random, so an ID from an owner that has gone never names a request of
    // its replacement in the desktop.
    final id =
        'approval-${[for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
    final done = Completer<bool>();
    _pending[id] = (client: client, done: done);
    final delivery = send(host, {
      'event': 'approval',
      'approval_id': id,
      'method': method,
      'args': args,
      'requester': isHost(client)
          ? 'Desktop connection (identity unverified)'
          : 'External client (identity unverified)',
      'risk_flags': [
        if (args['allow_private_network'] == true)
          'Private network access requested',
        if (method == Operation.sourcesImport.wire && args['id'] != null)
          'Replaces source ${args['id']}',
      ],
    });
    // Waiting for a decision on an approval the desktop never received would
    // only end at the timeout.
    if (delivery != EventDelivery.sent) {
      _pending.remove(id);
      throw switch (delivery) {
        EventDelivery.tooLarge => RpcError(
          RpcErrorCode.invalidArgument,
          'Request is too large to show for approval',
        ),
        EventDelivery.unencodable => RpcError(
          RpcErrorCode.invalidArgument,
          'Request contains a value JSON cannot represent, such as NaN or '
          'Infinity, so it cannot be shown for approval',
        ),
        _ => RpcError(
          RpcErrorCode.unavailable,
          'The desktop approval window could not be reached; retry once the '
          'desktop app is open',
        ),
      };
    }
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
