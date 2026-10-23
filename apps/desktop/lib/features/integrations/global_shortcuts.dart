import 'dart:async';
import 'dart:math';
import '../../platform_capabilities.dart';
import 'package:flutter/services.dart';
import 'package:dbus/dbus.dart';

/// Owned native macOS registration or Freedesktop portal session.
class GlobalShortcuts {
  DBusClient? _client;
  DBusClient get client => _client ??= DBusClient.session();
  final bool macOS;
  bool _macEnabled = false;
  static const channel = MethodChannel('foresight/desktop');
  final void Function(String, String?) activated;
  final void Function()? changed;
  static const service = 'org.freedesktop.portal.Desktop';
  static const interface = 'org.freedesktop.portal.GlobalShortcuts';
  late final portal = DBusRemoteObject(
    client,
    name: service,
    path: DBusObjectPath('/org/freedesktop/portal/desktop'),
  );
  DBusObjectPath? session;
  StreamSubscription<DBusSignal>? _activation, _changes;
  String state = 'disabled', trigger = '';
  bool _closed = false, _registered = false;
  final String appId;
  GlobalShortcuts(
    this.activated, {
    this.changed,
    DBusClient? client,
    this.appId = 'io.openforesight.App',
    bool? macOS,
    PlatformCapabilities capabilities = const PlatformCapabilities.linux(),
  }) : _client = client,
       macOS = macOS ?? capabilities.usesNativeShortcuts {
    if (this.macOS)
      channel.setMethodCallHandler((call) async {
        if (!_closed && _macEnabled && call.method == 'quick-meeting')
          activated('quick-meeting', null);
      });
  }

  Future<Map<String, DBusValue>> _request(
    String method,
    List<DBusValue> arguments,
    Map<String, DBusValue> options,
  ) async {
    final token =
        'foresight_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(100000)}';
    // Connect before deriving the request path, then subscribe before invoking.
    await client.getId();
    final sender = client.uniqueName.substring(1).replaceAll('.', '_');
    final request = DBusRemoteObject(
      client,
      name: service,
      path: DBusObjectPath(
        '/org/freedesktop/portal/desktop/request/$sender/$token',
      ),
    );
    final completed = Completer<Map<String, DBusValue>>();
    final subscription =
        DBusRemoteObjectSignalStream(
          object: request,
          interface: 'org.freedesktop.portal.Request',
          name: 'Response',
        ).listen((signal) {
          if (completed.isCompleted) return;
          if (signal.values[0].asUint32() != 0) {
            completed.completeError(
              StateError('Desktop shortcut request was cancelled or denied.'),
            );
          } else {
            completed.complete(signal.values[1].asStringVariantDict());
          }
        }, onError: completed.completeError);
    try {
      await portal.callMethod(interface, method, [
        ...arguments,
        DBusDict.stringVariant({'handle_token': DBusString(token), ...options}),
      ]);
      return await completed.future.timeout(const Duration(seconds: 120));
    } finally {
      await subscription.cancel();
    }
  }

  void _readShortcuts(DBusValue? value) {
    if (value == null) return;
    for (final item in value.asArray()) {
      final fields = item.asStruct();
      if (fields[0].asString() == 'quick-meeting') {
        trigger =
            fields[1]
                .asStringVariantDict()['trigger_description']
                ?.asString() ??
            '';
      }
    }
  }

  Future<void> enable({String preferredTrigger = 'CTRL+SHIFT+f'}) async {
    if (_closed) throw StateError('Shortcut service closed');
    if (macOS) {
      try {
        await channel.invokeMethod<void>('shortcut.enable', {
          'trigger': preferredTrigger,
        });
        _macEnabled = true;
        trigger = preferredTrigger;
        state = 'Registered with macOS';
      } catch (error) {
        state = 'Shortcut unavailable: $error';
        rethrow;
      } finally {
        changed?.call();
      }
      return;
    }
    if (session != null) return;
    state = 'Requesting desktop shortcut';
    changed?.call();
    try {
      if (!_registered) {
        await portal.callMethod(
          'org.freedesktop.host.portal.Registry',
          'Register',
          [DBusString(appId), DBusDict.stringVariant({})],
        );
        _registered = true;
      }
      final response = await _request('CreateSession', [], {
        'session_handle_token': DBusString(
          'foresight_${DateTime.now().microsecondsSinceEpoch}',
        ),
      });
      if (_closed) throw StateError('Shortcut service closed');
      if (macOS) {
        try {
          await channel.invokeMethod<void>('shortcut.enable', {
            'trigger': preferredTrigger,
          });
          _macEnabled = true;
          trigger = preferredTrigger;
          state = 'Registered with macOS';
        } catch (error) {
          state = 'Shortcut unavailable: $error';
          rethrow;
        } finally {
          changed?.call();
        }
        return;
      }
      session = DBusObjectPath(response['session_handle']!.asString());
      _activation =
          DBusRemoteObjectSignalStream(
            object: portal,
            interface: interface,
            name: 'Activated',
          ).listen((signal) {
            if (!_closed && signal.values[0].asObjectPath() == session) {
              activated(
                signal.values[1].asString(),
                signal.values[3]
                    .asStringVariantDict()['activation_token']
                    ?.asString(),
              );
            }
          });
      _changes =
          DBusRemoteObjectSignalStream(
            object: portal,
            interface: interface,
            name: 'ShortcutsChanged',
          ).listen((signal) {
            if (!_closed && signal.values[0].asObjectPath() == session) {
              _readShortcuts(signal.values[1]);
              changed?.call();
            }
          });
      final bound = await _request('BindShortcuts', [
        session!,
        DBusArray(DBusSignature('(sa{sv})'), [
          DBusStruct([
            const DBusString('quick-meeting'),
            DBusDict.stringVariant({
              'description': const DBusString(
                'Show Foresight and start a new meeting transcript',
              ),
              'preferred_trigger': DBusString(preferredTrigger),
            }),
          ]),
        ]),
        const DBusString(''),
      ], {});
      _readShortcuts(bound['shortcuts']);
      state = 'Registered with desktop';
      changed?.call();
    } catch (error) {
      state = 'Shortcut unavailable: $error';
      changed?.call();
      await disable();
      rethrow;
    }
  }

  Future<void> configure() async {
    if (macOS)
      throw StateError('Change the meeting shortcut in Foresight settings.');
    if (session == null) throw StateError('Enable global shortcuts first');
    final version = (await portal.getProperty(interface, 'version')).asUint32();
    if (version < 2)
      throw StateError(
        'This desktop configures global shortcuts through its keyboard settings.',
      );
    await portal.callMethod(interface, 'ConfigureShortcuts', [
      session!,
      const DBusString(''),
      DBusDict.stringVariant({}),
    ]);
  }

  Future<void> disable() async {
    if (macOS) {
      if (_macEnabled) await channel.invokeMethod<void>('shortcut.disable');
      _macEnabled = false;
      state = 'disabled';
      changed?.call();
      return;
    }
    await _activation?.cancel();
    await _changes?.cancel();
    _activation = null;
    _changes = null;
    final owned = session;
    session = null;
    if (owned != null) {
      try {
        await DBusRemoteObject(
          client,
          name: service,
          path: owned,
        ).callMethod('org.freedesktop.portal.Session', 'Close', []);
      } catch (_) {}
    }
    if (!state.startsWith('Shortcut unavailable')) state = 'disabled';
    changed?.call();
  }

  Future<void> close() async {
    _closed = true;
    await disable();
    if (macOS) channel.setMethodCallHandler(null);
    await _client?.close();
  }
}
