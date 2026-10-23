import '../test_support/platform_fixture.dart';
import 'package:open_foresight/features/integrations/audio_access.dart';
import 'package:open_foresight/desktop_environment.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_core/remote.dart' show StoreReader;
import 'store_reader_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/commands.dart';
import 'package:open_foresight/desktop_menu.dart';

import 'package:open_foresight/features/settings/gemma_setup_view.dart';

import 'package:open_foresight/features/settings/speech_setup_view.dart';
import 'package:open_foresight/features/settings/model_terms_dialog.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/features/onboarding/onboarding_view.dart';

import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'quick_start_test.dart' show QuickStartDomain;
import '../test_support/onboarding.dart';

class SetupDomain extends QuickStartDomain {
  bool failNotifications = false;
  SetupDomain(super.store, super.helper);
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (operation == Operation.sourcesDelete) {
      store.tombstone(args['id'] as String);
      helper.changed?.call();
      return null;
    }
    if (operation == Operation.audioCapabilities) {
      return {
        'microphone': 'not_determined',
        'microphone_purpose_present': true,
        'system_audio_purpose_present': true,
      };
    }
    if (operation == Operation.notificationsRequestPermission) {
      if (failNotifications)
        throw StateError('Notification service unavailable');
      return {'granted': true};
    }
    return super.command(operation, args);
  }
}

class ReadOnlyProfileConnection extends TestDesktopConnection {
  final Store reader;
  ReadOnlyProfileConnection(super.application, this.reader);
  @override
  StoreReader get store => fixtureReader(reader);
}

void main() {
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('foresight/window'),
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('foresight/window'),
        null,
      ),
    );
  });
  testWidgets(
    'Gemma and speech terms persist through the service with a read-only desktop profile',
    (tester) async {
      final root = createTestTempDirectorySync('of-terms-reader-');
      final writer = Store('${root.path}/application.db');
      final reader = Store.readOnly(writer.path);
      final domain = SetupDomain(
        writer,
        OfflineHelper('${root.path}/sock', '${root.path}/helper'),
      );
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() {
        writer.close();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        Foresight(
          ReadOnlyProfileConnection(Application(domain), reader),
          deviceLoader: () async => [],
          environment: DesktopEnvironment(
            capabilities: testHostPlatformCapabilities,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      final gemma =
          shell.settingsFeature.gemmaSetup(firstRun: true) as GemmaSetupDialog;
      final speech = shell.settingsFeature.speechSetup() as SpeechSetupDialog;
      for (final (model, save) in [
        (embeddingGemmaModel, gemma.savePreference),
        (speechModels.first, speech.savePreference),
      ]) {
        expect(save, isNotNull);
        final accepted = confirmModelTerms(
          tester.element(find.byType(Workspace)),
          fixtureReader(reader),
          model,
          savePreference: save,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('https://'), findsNothing);
        await tester.tap(find.text('Accept and download'));
        await tester.pumpAndSettle();
        expect(await accepted, isTrue);
        expect(
          reader.preference('modelTerms.${model.repository}.${model.revision}'),
          'accepted',
        );
      }
      expect(
        domain.operations.where((op) => op == 'preferences.set'),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  Future<(Store, SetupDomain, AppCommands)> mount(
    WidgetTester tester, {
    int step = 0,
    bool complete = false,
    bool quick = false,
    bool audioReviewed = false,
  }) async {
    final root = createTestTempDirectorySync('of-first-');
    final store = Store('${root.path}/app.db');
    store.setPreference('onboarding.step', '$step');
    if (complete) store.setPreference('onboarding.complete', 'true');
    if (audioReviewed) store.setPreference('audio.systemSetupReviewed', 'true');
    final domain = SetupDomain(
      store,
      OfflineHelper('${root.path}/sock', '${root.path}/helper'),
    );
    final commands = await tester.runAsync(
      () => AppCommands.bind(
        '${root.path}/cmd',
        environment: DesktopEnvironment.production(),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Foresight(
        TestDesktopConnection(Application(domain)),
        commands: commands!,
        quickOnLaunch: quick,
        deviceLoader: () async => [],
        environment: DesktopEnvironment(
          capabilities: testHostPlatformCapabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => eventually(() => commands.isClosed));
    });
    return (store, domain, commands);
  }

  testWidgets(
    'finishing system audio setup updates the row and persists review without claiming authorization',
    (tester) async {
      final (store, _, _) = await mount(tester, step: 3);
      await tester.tap(find.text('System audio capture'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(
        find.text('Setup complete · Access is checked when recording starts.'),
        findsOneWidget,
      );
      expect(store.preference('audio.systemSetupReviewed'), 'true');
      expect(find.text('Allowed'), findsNothing);
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('System audio capture'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.onTap, isNotNull);
      expect((tile.trailing as Icon).icon, Icons.check_circle_outline);
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'saved system audio setup stays complete after relaunch',
    (tester) async {
      await mount(tester, step: 3, audioReviewed: true);
      expect(
        find.text('Setup complete · Access is checked when recording starts.'),
        findsOneWidget,
      );
      final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      shell.update(
        () => shell.integrationFeature.captureCapabilities =
            AudioAccessPresentation.fromWire({
              'system_audio': 'denied',
              'system_audio_request': 'failed',
            }),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Not allowed · Enable Open Foresight in System Settings.'),
        findsOneWidget,
      );
      expect(
        find.text('Setup complete · Access is checked when recording starts.'),
        findsNothing,
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'production workspace starts setup before quick recording and saves progress',
    (tester) async {
      final (store, domain, commands) = await mount(tester, quick: true);
      expect(find.text('Start Foresight'), findsOneWidget);
      expect(domain.operations, isNot(contains('meetings.create')));
      if (Platform.isMacOS) {
        for (final command in ['settings', 'quick-meeting']) {
          final activation = TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage(
                DesktopMenu.channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(command),
                ),
                (_) {},
              );
          await tester.pumpAndSettle();
          await activation;
        }
        expect(find.text('Start Foresight'), findsOneWidget);
        expect(domain.operations, isNot(contains('meetings.create')));
      }
      await tester.tap(find.text('Start Foresight'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.preference('onboarding.step'), '1');
      expect(find.text('Connecting to the local service…'), findsOneWidget);
      await tester.tap(find.text('Skip for now'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.preference('onboarding.step'), '2');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => eventually(() => commands.isClosed));
    },
  );

  testWidgets(
    'permission actions are explicit and notification failures remain visible',
    (tester) async {
      final (_, domain, commands) = await mount(tester, step: 3);
      expect(domain.operations, isNot(contains('audio.request_microphone')));
      if (Platform.isMacOS) {
        await tester.tap(find.text('Microphone access'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Microphone access was denied.'),
          findsOneWidget,
        );
        await tester.tap(find.text('System audio capture'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(domain.operations, contains('audio.request_system'));
        expect(find.text('Request access'), findsNothing);
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();
        domain.failNotifications = true;
        await tester.tap(find.text('Enable notifications'));
        await tester.pumpAndSettle();
        expect(find.text('Notification service unavailable'), findsOneWidget);
        domain.failNotifications = false;
      } else {
        expect(find.text('Microphone access'), findsNothing);
        expect(
          find.textContaining('This Linux build records through PipeWire.'),
          findsOneWidget,
        );
      }
      await tester.tap(find.text('Enable notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Notifications enabled'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => eventually(() => commands.isClosed));
    },
  );

  testWidgets(
    'manual import page shows real source states, removes documents and completes setup',
    (tester) async {
      final (store, domain, commands) = await mount(tester, step: 5);
      final source = store.importText(
        'Project brief',
        'Project notes',
        'text/plain',
        'fixture',
      );
      store.state(source, 'indexed');
      domain.helper.changed?.call();
      await tester.pumpAndSettle();
      expect(find.text('Project brief'), findsOneWidget);
      expect(find.text('1 sources added · 1 indexed'), findsOneWidget);
      for (final label in [
        'Add files from Drive',
        'Import folder',
        'Import file',
        'Add from URL',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.byTooltip('Remove document'));
      await tester.pumpAndSettle();
      expect(find.text('Documents added (0)'), findsOneWidget);
      await tester.ensureVisible(find.text('Get started'));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(store.preference('onboarding.complete'), 'true');
      expect(find.byType(OnboardingView), findsNothing);
      expect(find.text('Knowledge Sources'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => eventually(() => commands.isClosed));
    },
  );

  testWidgets(
    'large onboarding libraries render lazily and keep the final source reachable',
    (tester) async {
      final (store, domain, commands) = await mount(tester, step: 5);
      for (var i = 0; i < 250; i++) {
        store.importText(
          'Document ${i.toString().padLeft(3, '0')}',
          'Knowledge',
          'text/plain',
          'fixture',
        );
      }
      domain.helper.changed?.call();
      await tester.pumpAndSettle();
      expect(find.text('Documents added (250)'), findsOneWidget);
      expect(
        find
            .byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').startsWith('Document '),
            )
            .evaluate()
            .length,
        lessThan(20),
      );
      await tester.scrollUntilVisible(
        find.text('Document 249'),
        500,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 100,
      );
      expect(find.text('Document 249'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => eventually(() => commands.isClosed));
    },
  );

  testWidgets(
    'saved imports waiting for models show recovery guidance instead of raw gRPC errors',
    (tester) async {
      final (store, domain, _) = await mount(tester, step: 5);
      store.importText('Saved document', 'Content', 'text/plain', 'fixture');
      final legacy = store.importText(
        'Calendar event',
        'Event details',
        'text/plain',
        'fixture',
      );
      store.state(
        legacy,
        'failed',
        'gRPC Error (code: 9, codeName: FAILED_PRECONDITION, message: Pipeline not initialized, details: [])',
      );
      domain.helper.changed?.call();
      await tester.pumpAndSettle();
      expect(find.text('Waiting for model setup'), findsNWidgets(2));
      expect(find.text('Set up indexing model'), findsOneWidget);
      expect(find.textContaining('gRPC Error'), findsNothing);
      expect(find.text('2 sources added · 0 indexed'), findsOneWidget);
      expect(store.sources, hasLength(2));
      store.state(legacy, 'failed', 'gRPC Error: another genuine failure');
      domain.helper.changed?.call();
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Couldn’t index this document. Retry from Knowledge sources.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('gRPC Error'), findsNothing);
    },
  );

  testWidgets(
    'workspace acceptance completes onboarding through visible actions',
    (tester) async {
      final (store, domain, commands) = await mount(tester);
      expect(find.byType(OnboardingView), findsOneWidget);
      await finishOnboarding(tester);
      expect(store.preference('onboarding.complete'), 'true');
      expect(store.preference('onboarding.step'), '5');
      expect(find.byType(OnboardingView), findsNothing);
      expect(find.text('Knowledge Sources'), findsWidgets);
      expect(domain.operations, isNot(contains('audio.request_microphone')));
      expect(domain.operations, isNot(contains('audio.request_system')));
      expect(domain.operations, isNot(contains('google.sign_in')));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => eventually(() => commands.isClosed));
    },
  );

  testWidgets('completed profiles open the workspace without onboarding', (
    tester,
  ) async {
    final (_, _, commands) = await mount(tester, complete: true);
    expect(find.byType(OnboardingView), findsNothing);
    expect(find.text('Start Foresight'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => eventually(() => commands.isClosed));
  });
}
