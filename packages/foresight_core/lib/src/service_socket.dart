import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'platform_services.dart';

/// Bind under a private, generation-specific name before publishing a socket.
///
/// Dart unlinks the original bind address when a Unix listener closes, even if
/// another listener has since replaced that address. Renaming before publication
/// leaves that automatic cleanup confined to this generation's temporary name.
/// The owner must remove [path] explicitly while it still holds its profile lock.
class ServiceSocketBinding {
  final ServerSocket listener;
  final String path;
  final String _boundPath;
  Future<void>? _closing;
  bool _published = false;

  /// Whether [publish] made this listener discoverable at [path]. Until
  /// then, whatever is at [path] is not this owner's to remove.
  bool get published => _published;

  ServiceSocketBinding._(this.listener, this.path, this._boundPath);

  static Future<ServiceSocketBinding> bind(String path) async {
    final random = Random.secure();
    // Ten bytes, shorter than worker.sock, also fits every public socket path.
    final name =
        '.s${base64Url.encode(List.generate(6, (_) => random.nextInt(256)))}';
    final boundPath = '${File(path).parent.path}/$name';
    final listener = await ServerSocket.bind(
      InternetAddress(boundPath, type: InternetAddressType.unix),
      0,
    );
    try {
      protectPrivateFile(boundPath);
      return ServiceSocketBinding._(listener, path, boundPath);
    } catch (_) {
      await listener.close();
      rethrow;
    }
  }

  /// Attach the consumer before making the protected socket discoverable.
  void publish(void Function(Socket) onClient) {
    if (_closing != null) throw StateError('Socket publication cancelled');
    listener.listen(onClient);
    File(_boundPath).renameSync(path);
    _published = true;
  }

  Future<void> close() => _closing ??= listener.close().then<void>((_) {});
}
