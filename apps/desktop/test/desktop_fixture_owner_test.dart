import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';

import '../test_support/core_fixture.dart' hide State;
import 'desktop_connection_fixture.dart';
import 'desktop_fixture_owner.dart';
import 'pump_until.dart';

class _Store extends Store {
  _Store(super.path);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

class _Domain extends Domain {
  _Domain(super.store, super.helper);
  final draining = Completer<void>();
  Completer<void>? release;
  bool failDrain = false;
  @override
  Future<void> drain() async {
    if (!draining.isCompleted) draining.complete();
    await release?.future;
    if (failDrain) throw StateError('Fixture Domain drain failed');
    await super.drain();
  }
}

class _Mounted extends StatefulWidget {
  const _Mounted(this.disposed);
  final void Function() disposed;
  @override
  State<_Mounted> createState() => _MountedState();
}

class _MountedState extends State<_Mounted> {
  @override
  Widget build(BuildContext context) => const SizedBox();
  @override
  void dispose() {
    widget.disposed();
    super.dispose();
  }
}

Future<Object> failureOf(Future<void> Function() work) async {
  try {
    await work();
  } catch (error) {
    return error;
  }
  throw TestFailure('Expected the fixture failure');
}

Future<void> expectFixtureFailure(
  Future<void> Function() work,
  Matcher matcher,
) async {
  final error = await failureOf(work);
  expect(error, matcher);
}

void main() {
  (_Store, _Domain) owner() {
    final root = createTestTempDirectorySync('desktop-owner-proof-');
    final store = _Store('${root.path}/app.db');
    final domain = _Domain(
      store,
      Helper(
        '${root.path}/helper.sock',
        '${root.path}/helper',
        manageProcess: false,
      ),
    );
    addTearDown(() async {
      if (domain.release?.isCompleted == false) domain.release!.complete();
      if (store.closes == 0) {
        domain.close();
        await domain.helper.close();
        store.close();
      }
      root.deleteSync(recursive: true);
    });
    return (store, domain);
  }

  testWidgets(
    'callback assertion failure unmounts and joins its actual Store owner',
    (tester) async {
      final (store, domain) = owner();
      var disposed = false;
      late TestDesktopConnection connection;
      await expectFixtureFailure(
        () => withDesktopFixtures(tester, () async {
          connection = TestDesktopConnection(Application(domain));
          await tester.pumpWidget(_Mounted(() => disposed = true));
          throw TestFailure('Original callback assertion');
        }),
        isA<TestFailure>().having(
          (e) => e.message,
          'message',
          'Original callback assertion',
        ),
      );
      await connection.closed;
      expect(disposed, true);
      expect(domain.closed, true);
      expect(domain.draining.isCompleted, true);
      expect(store.closes, 1);
    },
  );

  testWidgets(
    'cleanup failure is reported while the original assertion survives',
    (tester) async {
      final (store, domain) = owner();
      domain.failDrain = true;
      final reports = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reports.add;
      try {
        await expectFixtureFailure(
          () => withDesktopFixtures(tester, () async {
            TestDesktopConnection(Application(domain));
            throw TestFailure('Original callback assertion');
          }),
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            'Original callback assertion',
          ),
        );
      } finally {
        FlutterError.onError = previous;
      }
      expect(reports, hasLength(1));
      expect(
        reports.single.exception,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Fixture Domain drain failed',
        ),
      );
      expect(store.closes, 1);
    },
  );

  testWidgets(
    'held owner fails bounded cleanup without pretending Store is closed',
    (tester) async {
      final (store, domain) = owner();
      domain.release = Completer<void>();
      late TestDesktopConnection connection;
      final elapsed = Stopwatch()..start();
      try {
        await expectFixtureFailure(
          () => withDesktopFixtures(tester, () async {
            connection = TestDesktopConnection(Application(domain));
          }, closeTimeout: const Duration(milliseconds: 100)),
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            contains('deadline'),
          ),
        );
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(domain.draining.isCompleted, true);
        expect(domain.release!.isCompleted, false);
        expect(
          store.closes,
          0,
          reason:
              'Held owner retains its real Store/maintenance timer until settlement',
        );
      } finally {
        domain.release!.complete();
        await pumpUntilCompleted(tester, connection.closed);
      }
      expect(store.closes, 1);
    },
  );

  testWidgets('callback scopes do not reuse or retain prior registrations', (
    tester,
  ) async {
    var closes = 0;
    for (var index = 0; index < 2; index++) {
      await withDesktopFixtures(tester, () async {
        registerDesktopFixtureOwner(
          close: () => closes++,
          settled: () async {},
        );
      });
      expect(closes, index + 1);
    }
  });
}
