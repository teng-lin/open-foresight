import 'desktop_fixture_owner.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/chat/widgets.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'controller_fixture.dart';

void main() {
  testWidgets(
    'global operation transitions refresh disabled body controls',
    (tester) async => withDesktopFixtures(tester, () async {
      final fixture = await ControllerFixture.mount(tester);
      fixture.shell.navigate(WorkspaceTab.settings);
      await tester.pumpAndSettle();
      SwitchListTile control() =>
          tester.widget<SwitchListTile>(find.byType(SwitchListTile).first);
      expect(control().onChanged, isNotNull);
      final held = Completer<void>();
      final operation = fixture.shell.run(() => held.future);
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      await tester.pump();
      expect(control().onChanged, isNull);
      fixture.shell.settingsFeature.setState(
        () => fixture.shell.settingsFeature.modelKind = 'speech',
      );
      await tester.pump();
      expect(control().onChanged, isNull);
      held.complete();
      await operation;
      await tester.pumpAndSettle();
      expect(control().onChanged, isNotNull);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'local edits leave unrelated Chat and shell presentation untouched',
    (tester) async => withDesktopFixtures(tester, () async {
      final fixture = await ControllerFixture.mount(tester);
      fixture.shell.navigate(WorkspaceTab.chat);
      await tester.pumpAndSettle();
      final chat = tester.widget<ChatView>(find.byType(ChatView));
      final help = tester.widget<Tooltip>(find.byTooltip('Help'));
      var chatBuilds = 0;
      final old = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        old?.call(element, builtOnce);
        if (element.widget is ChatView || element.widget is ChatHistory)
          chatBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = old);
      fixture.shell.sourceFeature.update(() {
        fixture.shell.sourceFeature.labelFilter = 'local source selection';
      });
      await tester.pumpAndSettle();
      fixture.shell.settingsFeature.setState(() {
        fixture.shell.settingsFeature.modelKind = 'speech';
      });
      await tester.pumpAndSettle();
      expect(tester.widget<ChatView>(find.byType(ChatView)), same(chat));
      expect(tester.widget<Tooltip>(find.byTooltip('Help')), same(help));
      expect(chatBuilds, 0);

      fixture.shell.chatFeature.setAnswerFontSize(22);
      await tester.pumpAndSettle();
      expect(
        chatBuilds,
        greaterThan(0),
        reason: 'the owning feature still refreshes',
      );
      expect(tester.widget<ChatView>(find.byType(ChatView)), isNot(same(chat)));
      expect(tester.widget<Tooltip>(find.byTooltip('Help')), same(help));
      expect(tester.takeException(), isNull);
    }),
  );
}
