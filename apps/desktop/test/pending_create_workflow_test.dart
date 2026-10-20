import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:foresight_core/remote.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

/// Commits a create, then loses its reply as a dropped connection would.
class LostReplyDomain extends CommandFixtureDomain {
  LostReplyDomain(super.store, super.helper);
  final lose = <Operation>{};
  final sent = <(Operation, Map<String, dynamic>)>[];
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    sent.add((operation, args));
    final result = await super.command(operation, args);
    if (lose.remove(operation)) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
      );
    }
    return result;
  }
}

void main() {
  late Store store;
  late LostReplyDomain domain;
  setUp(() {
    final root = createTestTempDirectorySync('pending-create-');
    store = Store('${root.path}/app.db');
    domain = LostReplyDomain(
      store,
      OfflineHelper('${root.path}/socket', '${root.path}/helper'),
    );
  });

  Future<dynamic> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(Workspace));
  }

  List<Object?> keys(Operation operation) => [
    for (final (sent, args) in domain.sent)
      if (sent == operation) args['idempotency_key'],
  ];

  testWidgets('saving a new note again after a lost reply creates it once', (
    tester,
  ) async {
    final dynamic state = await show(tester);
    state.update(() => state.tab = 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Kept once');
    await tester.enterText(fields.at(1), 'Body');
    domain.lose.add(Operation.notesSave);
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    expect(state.error, contains('disconnected'));
    expect(state.meetingFeature.noteId, isNull);
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    final note = store.rows('SELECT id,title FROM notes').single;
    expect(note['title'], 'Kept once');
    expect(state.meetingFeature.noteId, note['id']);
    final sent = keys(Operation.notesSave);
    expect(sent, hasLength(2));
    expect(sent.toSet(), hasLength(1));
    // The next new note is a different action with its own key.
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(0), 'Second');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    expect(store.rows('SELECT id FROM notes'), hasLength(2));
    expect(keys(Operation.notesSave).toSet(), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pressing New meeting again after a lost reply creates once', (
    tester,
  ) async {
    final dynamic state = await show(tester);
    domain.lose.add(Operation.meetingsCreate);
    await tester.tap(find.text('New meeting'));
    await tester.pumpAndSettle();
    expect(state.error, contains('disconnected'));
    await tester.tap(find.text('New meeting'));
    await tester.pumpAndSettle();
    final meeting = store.rows('SELECT id FROM meetings').single['id'];
    expect(state.meetingFeature.meetingId, meeting);
    expect(keys(Operation.meetingsCreate).toSet(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
