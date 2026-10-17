import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/google_connections.dart';
import 'package:open_foresight/google_picker.dart';

class PendingDrive extends Fake implements GoogleConnections {
  final requests = <Completer<List<Map<String, dynamic>>>>[];
  final queries = <String>[];
  @override
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  }) {
    queries.add(query);
    final request = Completer<List<Map<String, dynamic>>>();
    requests.add(request);
    return request.future;
  }
}

Map<String, dynamic> file(String id) => {
  'id': id,
  'name': id,
  'mimeType': 'text/plain',
};

void main() {
  testWidgets('latest Drive search wins over a late older response or error', (
    tester,
  ) async {
    final drive = PendingDrive();
    await tester.pumpWidget(MaterialApp(home: GoogleDrivePicker(drive)));
    await tester.enterText(find.byType(TextField), 'new query');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(drive.queries, ['', 'new query']);
    drive.requests[1].complete([file('Latest file')]);
    await tester.pumpAndSettle();
    expect(find.text('Latest file'), findsOneWidget);
    drive.requests[0].complete([file('Stale file')]);
    await tester.pumpAndSettle();
    expect(find.text('Stale file'), findsNothing);
    expect(find.text('Latest file'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'older query');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'newest query');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    drive.requests[3].complete([file('Newest file')]);
    await tester.pumpAndSettle();
    drive.requests[2].completeError(StateError('Stale error'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stale error'), findsNothing);
    expect(find.text('Newest file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Drive error can be retried and cancellation returns no selection',
    (tester) async {
      tester.view.physicalSize = const Size(640, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final drive = PendingDrive();
      List<String>? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selection = await showDialog<List<String>>(
                  context: context,
                  builder: (_) => GoogleDrivePicker(drive),
                );
              },
              child: const Text('Open Drive'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open Drive'));
      await tester.pump();
      drive.requests[0].completeError(StateError('Temporary connection error'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Temporary connection error'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      drive.requests[1].complete([]);
      await tester.pumpAndSettle();
      expect(find.text('No matching files.'), findsOneWidget);
      expect(find.textContaining('Temporary connection error'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(selection, isNull);
      expect(find.byType(GoogleDrivePicker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
