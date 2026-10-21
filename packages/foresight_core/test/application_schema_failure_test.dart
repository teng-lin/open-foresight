import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  for (final withEpoch in [false, true]) {
    test(
      'future writer schema is actionable before dependent SQL ($withEpoch)',
      () async {
        final directory = createTestTempDirectorySync('application-schema-');
        final store = Store('${directory.path}/application.db');
        final helper = Helper(
          '${directory.path}/helper.sock',
          '${directory.path}/helper',
          manageProcess: false,
        );
        final domain = Domain(store, helper);
        final application = Application(domain);
        addTearDown(() async {
          await application.close();
          domain.close();
          await helper.close();
          store.close();
        });
        final arguments = <String, dynamic>{
          'id': 'existing',
          if (withEpoch) 'workspace_epoch': store.workspaceEpoch,
        };
        final request = decodeOperationRequest(Operation.sourcesGet, arguments);
        store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
        store.db.execute('ALTER TABLE sources RENAME TO future_sources');
        store.db.execute(
          'ALTER TABLE preferences RENAME TO future_preferences',
        );
        final unavailable = isA<RpcError>()
            .having((error) => error.code, 'code', RpcErrorCode.unavailable)
            .having(
              (error) => error.message,
              'message',
              contains('Update Open Foresight'),
            );
        if (withEpoch) {
          // Service admission checks the epoch before authorizing/dispatching.
          expect(
            () => application.checkRequestWorkspaceEpoch(request),
            throwsA(unavailable),
          );
        }
        await expectLater(
          application.callRequest(request),
          throwsA(unavailable),
        );
      },
    );
  }
}
