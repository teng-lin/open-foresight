import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class WebDomain extends Domain {
  WebDomain(super.store, super.helper);
  bool available = true;
  final requests = <(bool, String, int?)>[];
  @override
  bool get webSearchAvailable => available;
  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    requests.add((false, conversation, meetingId));
    yield 'Local answer';
  }

  @override
  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    requests.add((true, conversation, meetingId));
    yield 'Web answer';
  }
}

Finder webToggle([String tooltip = 'Search the web']) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void main() {
  late Directory directory;
  late Store store;
  late WebDomain domain;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('web-ui-');
    store = Store('${directory.path}/app.db');
    domain = WebDomain(
      store,
      OfflineHelper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      ),
    );
  });
  tearDown(() {
    domain.close();
    store.close();
    directory.deleteSync(recursive: true);
  });

  Future<dynamic> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
    final dynamic state = tester.state(find.byType(Workspace));
    state.update(() => state.tab = 1);
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets(
    'web toggle routes Ask explicitly and switching it off restores local Ask',
    (tester) async {
      final state = await mount(tester);
      final toggle = webToggle();
      expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.controller == state.question,
      );
      await tester.enterText(input, 'Current facts?');
      await tester.pump();
      await tester.tap(find.byTooltip('Ask'));
      await tester.pumpAndSettle();
      expect(domain.requests, [(true, 'desktop', null)]);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.enterText(input, 'Local question');
      await tester.pump();
      await tester.tap(find.byTooltip('Ask'));
      await tester.pumpAndSettle();
      expect(domain.requests.last, (false, 'desktop', null));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('web mode is isolated between Ask and individual meeting chats', (
    tester,
  ) async {
    final alpha = store.meeting('Alpha'), beta = store.meeting('Beta');
    final state = await mount(tester);
    await tester.tap(find.byTooltip('Search the web'));
    await tester.pumpAndSettle();
    state.update(() {
      state.tab = 3;
      state.meetingId = alpha;
      state.meetingPanel = 'Chat';
    });
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(webToggle()).isSelected, isFalse);
    await tester.tap(find.byTooltip('Search the web'));
    await tester.pumpAndSettle();
    state.update(() {
      state.meetingId = beta;
      state.meetingPanel = 'Chat';
    });
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(webToggle()).isSelected, isFalse);
    state.update(() {
      state.tab = 3;
      state.meetingId = alpha;
      state.meetingPanel = 'Chat';
    });
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(webToggle()).isSelected, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unavailable builds expose no project setup and web citations avoid local revision labels',
    (tester) async {
      domain.available = false;
      store.answer(
        'Question',
        'Answer [Source:1]',
        'completed',
        [
          {
            'kind': 'web',
            'citation': 'Source:1',
            'title': 'Web result',
            'url': 'file:///private/fixture',
            'excerpt': 'Captured summary',
          },
        ],
        'fixture',
        conversation: 'desktop',
      );
      await mount(tester);
      expect(
        tester
            .widget<IconButton>(
              webToggle('Web search is unavailable in this build'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('[Source:1] Web result'), findsOneWidget);
      expect(find.textContaining('revision null'), findsNothing);
      await tester.tap(find.text('[Source:1] Web result'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This citation has no valid web address.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
