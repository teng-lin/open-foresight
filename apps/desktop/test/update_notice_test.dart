import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/settings/update_notice_view.dart';

List<int> releaseBytes() => utf8.encode(
  jsonEncode({
    'id': 123,
    'tag_name': 'v0.2.0',
    'html_url':
        'https://github.com/teng-lin/open-foresight/releases/tag/v0.2.0',
    'url': 'https://api.github.com/repos/teng-lin/open-foresight/releases/123',
    'draft': false,
    'prerelease': false,
  }),
);

Future<void> mount(
  WidgetTester tester, {
  required UpdateNoticeClient client,
  bool initiallyEnabled = false,
  Future<void> Function(bool)? save,
  Future<void> Function(Uri)? openRelease,
}) async {
  var enabled = initiallyEnabled;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, update) => UpdateNoticeView(
            enabled: enabled,
            client: client,
            currentVersion: '0.1.3',
            setEnabled: (value) async {
              await save?.call(value);
              update(() => enabled = value);
            },
            openRelease: openRelease,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a successful consent retry clears the previous save error', (
    tester,
  ) async {
    var attempts = 0;
    await mount(
      tester,
      client: UpdateNoticeClient(transport: (_, _) async => releaseBytes()),
      save: (_) async {
        if (++attempts == 1) throw StateError('fixture first write failed');
      },
    );
    await tester.tap(find.byKey(const Key('updateNoticeEnabled')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the update setting.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('updateNoticeEnabled')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Could not save the update setting.'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('checkForUpdates')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'opt-in and startup cause no network; only the explicit check does',
    (tester) async {
      var calls = 0;
      final saved = <bool>[];
      Uri? opened;
      final client = UpdateNoticeClient(
        transport: (_, _) async {
          calls++;
          return releaseBytes();
        },
      );
      await mount(
        tester,
        client: client,
        save: (value) async {
          saved.add(value);
        },
        openRelease: (uri) async {
          opened = uri;
        },
      );
      expect(calls, 0);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('checkForUpdates')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('updateNoticeEnabled')));
      await tester.pumpAndSettle();
      expect(saved, [true]);
      expect(calls, 0);
      await tester.tap(find.byKey(const Key('checkForUpdates')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('Version 0.2.0 is available.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('updateReleasePage')));
      await tester.pumpAndSettle();
      expect(
        opened.toString(),
        'https://github.com/teng-lin/open-foresight/releases/tag/v0.2.0',
      );
    },
  );

  testWidgets('a saved opt-in still waits for a click', (tester) async {
    var calls = 0;
    await mount(
      tester,
      initiallyEnabled: true,
      client: UpdateNoticeClient(
        transport: (_, _) async {
          calls++;
          return releaseBytes();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('disabling a held check discards its late notice', (
    tester,
  ) async {
    final held = Completer<List<int>>();
    await mount(
      tester,
      initiallyEnabled: true,
      client: UpdateNoticeClient(transport: (_, _) => held.future),
    );
    await tester.tap(find.byKey(const Key('checkForUpdates')));
    await tester.pump();
    expect(find.text('Checking…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('updateNoticeEnabled')));
    await tester.pumpAndSettle();
    held.complete(releaseBytes());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('updateReleasePage')), findsNothing);
    expect(find.text('Version 0.2.0 is available.'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('checkForUpdates')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a held check has no late widget update', (
    tester,
  ) async {
    final held = Completer<List<int>>();
    await mount(
      tester,
      initiallyEnabled: true,
      client: UpdateNoticeClient(transport: (_, _) => held.future),
    );
    await tester.tap(find.byKey(const Key('checkForUpdates')));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    held.complete(releaseBytes());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports identity rejection without offering a release link', (
    tester,
  ) async {
    await mount(
      tester,
      initiallyEnabled: true,
      client: UpdateNoticeClient(
        transport: (_, _) async => throw const UpdateNoticeException(
          UpdateNoticeProblem.untrustedMetadata,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('checkForUpdates')));
    await tester.pumpAndSettle();
    expect(
      find.text('The release identity could not be verified.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('updateReleasePage')), findsNothing);
  });

  testWidgets('a failed consent save keeps checks disabled', (tester) async {
    await mount(
      tester,
      client: UpdateNoticeClient(transport: (_, _) async => releaseBytes()),
      save: (_) async => throw StateError('fixture write failed'),
    );
    await tester.tap(find.byKey(const Key('updateNoticeEnabled')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the update setting.'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('checkForUpdates')))
          .onPressed,
      isNull,
    );
  });
}
