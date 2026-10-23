import 'package:open_foresight/platform_capabilities.dart';
import 'dart:async';
import 'dart:io';
import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/integrations/global_shortcuts.dart';
import 'package:open_foresight/features/integrations/hypr_shortcuts.dart';

class Portal extends DBusObject {
  final calls = <DBusMethodCall>[];
  int version = 2;
  String? denied;
  bool failClose = false;
  Portal() : super(DBusObjectPath('/org/freedesktop/portal/desktop'));
  static final owned = DBusObjectPath(
    '/org/freedesktop/portal/desktop/session/fixture',
  );
  DBusArray shortcuts(String trigger) => DBusArray(DBusSignature('(sa{sv})'), [
    DBusStruct([DBusString('unrelated'), DBusDict.stringVariant({})]),
    DBusStruct([
      DBusString('quick-meeting'),
      DBusDict.stringVariant({'trigger_description': DBusString(trigger)}),
    ]),
  ]);
  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      DBusMethodSuccessResponse([DBusVariant(DBusUint32(version))]);
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    calls.add(call);
    if (call.name == 'Register' || call.name == 'ConfigureShortcuts') {
      return DBusMethodSuccessResponse([]);
    }
    final options = call.values.last.asStringVariantDict();
    final sender = call.sender!.substring(1).replaceAll('.', '_');
    final response = DBusObject(
      DBusObjectPath(
        '/org/freedesktop/portal/desktop/request/$sender/${options['handle_token']!.asString()}',
      ),
    );
    await client!.registerObject(response);
    await response.emitSignal('org.freedesktop.portal.Request', 'Response', [
      DBusUint32(denied == call.name ? 1 : 0),
      DBusDict.stringVariant(
        call.name == 'CreateSession'
            ? {'session_handle': DBusString(owned.value)}
            : {'shortcuts': shortcuts('Ctrl+Shift+F')},
      ),
    ]);
    return DBusMethodSuccessResponse([DBusObjectPath(response.path.value)]);
  }
}

class Session extends DBusObject {
  int closed = 0;
  bool fail = false;
  Session() : super(Portal.owned);
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    expect(call.name, 'Close');
    closed++;
    return fail
        ? DBusMethodErrorResponse.failed('session vanished')
        : DBusMethodSuccessResponse([]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('shortcut syntax requires distinct modifiers and a letter or digit', () {
    expect(HyprShortcuts.normalize(' ctrl+ shift +f '), 'CTRL + SHIFT + F');
    expect(HyprShortcuts.normalize('SUPER + ALT + 1'), 'SUPER + ALT + 1');
    for (final value in [
      'CTRL+F',
      'CTRL+CTRL+F',
      'CTRL+SHIFT+F1',
      'CTRL+BAD+F',
      'CTRL+SHIFT+',
    ]) {
      expect(() => HyprShortcuts.normalize(value), throwsStateError);
    }
  });
  group(
    'private shortcut portal',
    () {
      late DBusServer server;
      late DBusClient host;
      late Portal portal;
      late Session session;
      late GlobalShortcuts shortcuts;
      late List<String> activations;
      late int changes;
      setUp(() async {
        server = DBusServer();
        final address = await server.listenAddress(
          DBusAddress.unix(dir: Directory.systemTemp),
        );
        // The private Dart server accepts a fixture identity. Authentication
        // must not depend on the runner's actual user ID.
        host = DBusClient(address, authClient: DBusAuthClient(uid: '1000'));
        await host.requestName(GlobalShortcuts.service);
        portal = Portal();
        session = Session();
        await host.registerObject(portal);
        await host.registerObject(session);
        activations = [];
        changes = 0;
        shortcuts = GlobalShortcuts(
          (id, token) => activations.add('$id:$token'),
          macOS: false,
          client: DBusClient(address, authClient: DBusAuthClient(uid: '1000')),
          changed: () => changes++,
        );
      });
      tearDown(() async {
        await shortcuts.close();
        await host.close();
        await server.close();
      });
      test(
        'registers, binds, receives owned signals, configures and releases session',
        () async {
          await shortcuts.enable(preferredTrigger: 'ALT+SHIFT+f');
          expect(shortcuts.state, 'Registered with desktop');
          expect(shortcuts.trigger, 'Ctrl+Shift+F');
          expect(portal.calls.map((c) => c.name), [
            'Register',
            'CreateSession',
            'BindShortcuts',
          ]);
          final binding = portal.calls.last.values[1]
              .asArray()
              .single
              .asStruct()[1]
              .asStringVariantDict();
          expect(binding['preferred_trigger']!.asString(), 'ALT+SHIFT+f');
          await shortcuts.enable();
          expect(portal.calls, hasLength(3));
          final changed = Completer<void>();
          final signal = DBusRemoteObjectSignalStream(
            object: DBusRemoteObject(
              host,
              name: host.uniqueName,
              path: portal.path,
            ),
            interface: GlobalShortcuts.interface,
            name: 'ShortcutsChanged',
          ).listen((_) => changed.complete());
          await portal.emitSignal(GlobalShortcuts.interface, 'Activated', [
            Portal.owned,
            DBusString('quick-meeting'),
            DBusUint64(0),
            DBusDict.stringVariant({
              'activation_token': DBusString('owned-token'),
            }),
          ]);
          await portal.emitSignal(
            GlobalShortcuts.interface,
            'ShortcutsChanged',
            [Portal.owned, portal.shortcuts('Alt+Shift+F')],
          );
          await changed.future.timeout(const Duration(seconds: 5));
          // A round trip on the consumer connection drains prior ordered signals.
          await shortcuts.client.getId();
          expect(activations, ['quick-meeting:owned-token']);
          expect(shortcuts.trigger, 'Alt+Shift+F');
          await signal.cancel();
          await shortcuts.configure();
          expect(portal.calls.last.name, 'ConfigureShortcuts');
          session.fail = true;
          await shortcuts.disable();
          expect(session.closed, 1);
          expect(shortcuts.session, isNull);
          expect(shortcuts.state, 'disabled');
          expect(changes, greaterThan(2));
          await shortcuts.enable();
          expect(portal.calls.where((c) => c.name == 'Register'), hasLength(1));
        },
      );
      for (final method in ['CreateSession', 'BindShortcuts']) {
        test(
          'denied $method leaves no owned session and preserves error state',
          () async {
            portal.denied = method;
            await expectLater(shortcuts.enable(), throwsStateError);
            expect(shortcuts.session, isNull);
            expect(shortcuts.state, contains('cancelled or denied'));
            expect(session.closed, method == 'BindShortcuts' ? 1 : 0);
          },
        );
      }
      test(
        'configuration requires enabled session and portal version two',
        () async {
          await expectLater(shortcuts.configure(), throwsStateError);
          await shortcuts.enable();
          portal.version = 1;
          await expectLater(
            shortcuts.configure(),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('keyboard settings'),
              ),
            ),
          );
          await shortcuts.close();
          await expectLater(shortcuts.enable(), throwsStateError);
        },
      );
    },
    skip: !Platform.isLinux
        ? 'Linux D-Bus portal protocol requires a private session bus'
        : false,
  );
  test(
    'macOS shortcut registration, failure, activation and cleanup use platform channel',
    () async {
      final calls = <MethodCall>[];
      var rejected = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(GlobalShortcuts.channel, (call) async {
        calls.add(call);
        if (rejected) throw PlatformException(code: 'denied');
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(GlobalShortcuts.channel, null),
      );
      final activated = <String>[];
      final shortcuts = GlobalShortcuts(
        (id, _) => activated.add(id),
        capabilities: const PlatformCapabilities.macOS(),
      );
      Future<void> activate() async {
        await messenger.handlePlatformMessage(
          GlobalShortcuts.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('quick-meeting'),
          ),
          (_) {},
        );
      }

      await activate();
      expect(activated, isEmpty);
      await shortcuts.enable(preferredTrigger: 'SUPER+SHIFT+F');
      expect(calls.single.arguments, {'trigger': 'SUPER+SHIFT+F'});
      await activate();
      expect(activated, ['quick-meeting']);
      await expectLater(shortcuts.configure(), throwsStateError);
      await shortcuts.disable();
      await activate();
      expect(activated, hasLength(1));
      rejected = true;
      await expectLater(shortcuts.enable(), throwsA(isA<PlatformException>()));
      expect(shortcuts.state, contains('Shortcut unavailable'));
      rejected = false;
      await shortcuts.close();
      expect(calls.map((c) => c.method), [
        'shortcut.enable',
        'shortcut.disable',
        'shortcut.enable',
      ]);
    },
  );
}
