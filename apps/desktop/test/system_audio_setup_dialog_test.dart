import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/system_audio_setup_dialog.dart';

void main() {
  testWidgets(
    'pending consent refreshes to completion without another permission request',
    (tester) async {
      var requests = 0, reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SystemAudioSetupDialog(
              requestAccess: () async {
                requests++;
                return {
                  'system_audio_request': 'requesting',
                  'system_audio': 'pending',
                };
              },
              readCapabilities: () async {
                reads++;
                return {
                  'system_audio_request': 'completed',
                  'system_audio': 'unknown',
                  'permission_verified': false,
                };
              },
              openSettings: (_) async {},
              capabilitiesChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(reads, 1);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Allowed'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(reads, 1);
    },
  );

  testWidgets(
    'returning from System Settings refreshes status without requesting access again',
    (tester) async {
      var requests = 0, reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SystemAudioSetupDialog(
              requestAccess: () async {
                requests++;
                return {
                  'system_audio_request': 'completed',
                  'system_audio': 'unknown',
                };
              },
              readCapabilities: () async {
                reads++;
                return {
                  'system_audio_request': 'completed',
                  'system_audio': 'unknown',
                  'permission_verified': false,
                };
              },
              openSettings: (_) async {},
              capabilitiesChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open System Settings'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(requests, 1);
      expect(find.text('Allowed'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('dedicated Settings opener rejects other destinations', () async {
    await expectLater(
      openSystemAudioSettings(Uri.parse('https://example.test')),
      throwsArgumentError,
    );
    await expectLater(
      openSystemAudioSettings(
        Uri.parse(
          'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles',
        ),
      ),
      throwsArgumentError,
    );
  });
  testWidgets(
    'opening setup immediately requests system audio once; cancellation safely ignores a late result',
    (tester) async {
      var requests = 0, updates = 0;
      final gate = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SystemAudioSetupDialog(
                  requestAccess: () {
                    requests++;
                    return gate.future;
                  },
                  capabilitiesChanged: (_) => updates++,
                  openSettings: (_) async {},
                ),
              ),
              child: const Text('System audio +'),
            ),
          ),
        ),
      );
      expect(requests, 0);
      await tester.tap(find.text('System audio +'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests, 1);
      expect(find.text('Request access'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Retry request'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      gate.complete({'system_audio_request': 'completed'});
      await tester.pumpAndSettle();
      expect(updates, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed requests can retry and completed requests preserve unknown authorization',
    (tester) async {
      var requests = 0;
      Map<String, dynamic>? updated;
      Uri? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SystemAudioSetupDialog(
              requestAccess: () async {
                if (++requests == 1)
                  throw StateError('Audio device unavailable');
                return {
                  'system_audio_request': 'completed',
                  'system_audio': 'unknown',
                  'permission_verified': false,
                  // A retained native library's legacy hint must not replace
                  // the Settings extension link used by the desktop.
                  'settings_url':
                      'x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture',
                };
              },
              capabilitiesChanged: (value) => updated = value,
              openSettings: (uri) async => opened = uri,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Audio device unavailable'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Retry request'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(updated!['system_audio'], 'unknown');
      expect(updated!['permission_verified'], false);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Allowed'), findsNothing);
      await tester.tap(find.text('Open System Settings'));
      await tester.pumpAndSettle();
      expect(
        opened.toString(),
        'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
