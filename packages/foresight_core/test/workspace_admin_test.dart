import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/application_services/workspace_admin.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/proactive_questions.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class HeldWorkspaceReset extends ProactiveQuestions {
  HeldWorkspaceReset(Store store)
    : super(
        store: store,
        detect: (_, _) async => [],
        answer: (_, _, _) async => 1,
        busy: () => false,
        cancel: (_) {},
        changed: () {},
      );
  final settled = Completer<void>();
  @override
  Future<void> reset() => settled.future;
}

class ObservedAccountCleanup implements WorkspaceAccountCleanup {
  ObservedAccountCleanup(this.onForget);
  final void Function() onForget;
  int calls = 0;
  @override
  void forgetWorkspaceAccounts() {
    calls++;
    onForget();
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory directory;
  late Store store;
  late Helper helper;
  late HeldWorkspaceReset reset;
  late ObservedAccountCleanup accounts;
  late WorkspaceAdmin admin;

  setUp(() {
    directory = createTestTempDirectorySync('workspace-admin-');
    store = Store('${directory.path}/app.db');
    helper = Helper('${directory.path}/socket', '${directory.path}/helper');
    reset = HeldWorkspaceReset(store);
    accounts = ObservedAccountCleanup(() {
      expect(store.sources, isEmpty);
      expect(store.rows('SELECT * FROM notes'), isEmpty);
    });
    admin = WorkspaceAdmin(
      domain: AdapterDomain(store, helper),
      persistence: WorkspacePersistence(store),
      proactive: reset,
      accounts: accounts,
    );
    addTearDown(() async {
      if (!reset.settled.isCompleted) reset.settled.complete();
      await reset.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  test(
    'commits before account cleanup and waits for actual reset settlement',
    () async {
      store.importText('Private', 'secret', 'text/plain', 'fixture');
      final before = store.workspaceEpoch;
      var completed = false;
      final pending = admin.clear().whenComplete(() => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(accounts.calls, 1);
      expect(store.workspaceEpoch, isNot(before));
      expect(admin.clearing, isTrue);
      expect(completed, isFalse);
      await expectLater(
        admin.clear(),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      reset.settled.complete();
      final cleared = await pending;
      expect(cleared.epoch, store.workspaceEpoch);
      expect(admin.clearing, isFalse);
    },
  );

  test(
    'failed transaction keeps accounts and releases admission after reset',
    () async {
      final source = store.importText(
        'Private',
        'secret',
        'text/plain',
        'fixture',
      );
      final epoch = store.workspaceEpoch;
      store.db.execute(
        "CREATE TRIGGER refuse_clear BEFORE DELETE ON sources "
        "BEGIN SELECT RAISE(FAIL,'held source'); END",
      );
      final pending = expectLater(admin.clear(), throwsA(isA<Exception>()));
      await Future<void>.delayed(Duration.zero);
      expect(admin.clearing, isTrue);
      expect(accounts.calls, 0);
      expect(store.workspaceEpoch, epoch);
      expect(store.sources.single['id'], source);
      reset.settled.complete();
      await pending;
      expect(admin.clearing, isFalse);
      store.db.execute('DROP TRIGGER refuse_clear');
      await admin.clear();
      expect(accounts.calls, 1);
      expect(store.sources, isEmpty);
    },
  );
}
