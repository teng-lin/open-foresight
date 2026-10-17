import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/service_edit_dialog.dart';

void main() {
  for (final label in ['Save edit', 'Save and index']) {
    testWidgets('$label retains failed edits and offers a successful retry', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'My unsaved edit');
      addTearDown(controller.dispose);
      var calls = 0;
      Completer<void>? gate;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => ServiceEditDialog(
                  title: 'Edit',
                  controller: controller,
                  saveLabel: label,
                  onSave: () async {
                    calls++;
                    if (calls == 1) throw StateError('Service disconnected');
                    await gate!.future;
                  },
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.textContaining('Service disconnected'), findsOneWidget);
      expect(controller.text, 'My unsaved edit');
      expect(tester.takeException(), isNull);
      gate = Completer<void>();
      await tester.tap(find.text(label));
      await tester.pump();
      expect(find.text('Saving…'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    });
  }
}
