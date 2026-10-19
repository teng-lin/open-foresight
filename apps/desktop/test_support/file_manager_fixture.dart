import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

/// Test-only receiver for the real, absolute Linux file-reveal launcher.
/// Acceptance runners must supply a disposable session bus, never a host bus.
class FileManagerRevealSpy extends DBusObject {
  final File report;
  DBusClient? _client;

  FileManagerRevealSpy(this.report)
    : super(DBusObjectPath('/org/freedesktop/FileManager1'));

  Future<void> start({required bool isolated}) async {
    if (!isolated) {
      throw StateError(
        'File reveal acceptance requires an isolated session bus',
      );
    }
    final client = DBusClient.session();
    try {
      await client.registerObject(this);
      final owner = await client.requestName(
        'org.freedesktop.FileManager1',
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (owner != DBusRequestNameReply.primaryOwner) {
        throw StateError('Refusing to replace an existing FileManager1 owner');
      }
      _client = client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> close() async {
    await _client?.close();
    _client = null;
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'org.freedesktop.FileManager1') {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (call.name != 'ShowItems') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (call.signature != DBusSignature('ass')) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    final uris = List<String>.from(call.values.first.toNative() as Iterable);
    if (uris.isEmpty ||
        uris.any((value) {
          final uri = Uri.tryParse(value);
          return uri == null ||
              uri.scheme != 'file' ||
              uri.host.isNotEmpty ||
              !uri.path.startsWith('/') ||
              uri.hasQuery ||
              uri.hasFragment;
        })) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    report.writeAsStringSync(
      jsonEncode({
        'interface': call.interface,
        'path': path.value,
        'method': call.name,
        'uris': uris,
        'startup_id': (call.values[1] as DBusString).value,
      }),
    );
    return DBusMethodSuccessResponse();
  }
}
