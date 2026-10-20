import 'dart:async';
import 'package:test/test.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';

void main() {
  test(
    'cancelled parked index settles and leaves durable pending source',
    () async {
      final temporary = createTestTempDirectorySync('cancel-source-');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper)..pauseSources();
      final id = store.importText('one', 'body', 'text/plain', 'fixture');
      var current = true;
      final work = domain.index(id, current: () => current);
      final cancelled = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await Future<void>.value();
      expect(domain.cancellationWatchCount, 1);
      current = false;
      domain.checkCancellations();
      await cancelled;
      expect(domain.cancellationWatchCount, 0);
      expect(
        store.rows('SELECT state FROM sources WHERE id=?', [
          id,
        ]).single['state'],
        'pending',
      );
      domain.close();
      await helper.close();
      store.close();
      temporary.deleteSync(recursive: true);
    },
  );
}
