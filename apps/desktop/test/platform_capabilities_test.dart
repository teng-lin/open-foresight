import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/calendar_auth_links.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/integrations/system_audio_setup_dialog.dart';
import 'controller_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('injected platform selection precedes the production host fallback', () {
    final environment = DesktopEnvironment.production(
      variables: const {},
      macOS: true,
      capabilities: const PlatformCapabilities.linux(),
      runSync: (_, _) => throw StateError('Unexpected account lookup'),
    );
    expect(environment.capabilities.supportsHyprland, isTrue);
    expect(environment.capabilities.requiresAudioPermissions, isFalse);
    expect(environment.homeDirectory, isNull);
  });

  for (final (name, capabilities) in [
    ('Linux', const PlatformCapabilities.linux()),
    ('Mac', const PlatformCapabilities.macOS()),
  ]) {
    testWidgets('$name facts choose keyboard modifiers on either host', (
      tester,
    ) async {
      await ControllerFixture.mount(
        tester,
        environment: DesktopEnvironment(capabilities: capabilities),
      );
      final shortcuts = tester.widget<CallbackShortcuts>(
        find.byType(CallbackShortcuts).first,
      );
      final activators = shortcuts.bindings.keys.whereType<SingleActivator>();
      for (final key in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyO,
      ]) {
        final activator = activators.singleWhere(
          (value) => value.trigger == key,
        );
        expect(activator.meta, name == 'Mac');
        expect(activator.control, name == 'Linux');
      }
    });

    test(
      '$name facts select native calendar delivery without host probing',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final links = CalendarAuthLinks(capabilities: capabilities);
        final delivered = <String>[];
        var readyCalls = 0;
        messenger.setMockMethodCallHandler(CalendarAuthLinks.channel, (
          call,
        ) async {
          expect(call.method, 'ready');
          readyCalls++;
          return ['open-foresight://login-in-progress?fixture=pending'];
        });
        addTearDown(() {
          links.close();
          messenger.setMockMethodCallHandler(CalendarAuthLinks.channel, null);
        });
        await links.start((url) async => delivered.add(url));
        expect(readyCalls, name == 'Mac' ? 1 : 0);
        expect(
          delivered,
          name == 'Mac'
              ? ['open-foresight://login-in-progress?fixture=pending']
              : isEmpty,
        );
        final response = Completer<void>();
        await messenger.handlePlatformMessage(
          CalendarAuthLinks.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(
              'open-url',
              'open-foresight://login-in-progress?fixture=live',
            ),
          ),
          (_) => response.complete(),
        );
        await response.future;
        expect(delivered.length, name == 'Mac' ? 2 : 0);
        links.close();
      },
    );
  }

  test(
    'System Settings action keeps its platform refusal and injected runner',
    () async {
      final calls = <(String, List<String>)>[];
      Future<ProcessResult> run(
        String executable,
        List<String> arguments,
      ) async {
        calls.add((executable, arguments));
        return ProcessResult(0, 0, '', '');
      }

      await expectLater(
        openSystemAudioSettings(
          systemAudioSettingsUri,
          environment: DesktopEnvironment(
            capabilities: const PlatformCapabilities.linux(),
            run: run,
          ),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            'macOS System Settings is unavailable',
          ),
        ),
      );
      expect(calls, isEmpty);
      await openSystemAudioSettings(
        systemAudioSettingsUri,
        environment: DesktopEnvironment(
          capabilities: const PlatformCapabilities.macOS(),
          run: run,
        ),
      );
      expect(calls, hasLength(1));
      expect(calls.single.$1, '/usr/bin/open');
      expect(calls.single.$2, [systemAudioSettingsUri.toString()]);
    },
  );
}
