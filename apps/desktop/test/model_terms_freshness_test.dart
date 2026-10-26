import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/features/settings/model_terms_dialog.dart';
import '../test_support/core_fixture.dart'
    show
        Store,
        SqliteStoreReader,
        SqliteReadSession,
        ReadWorker,
        ReadWorkerRequest,
        ReadWorkerReply;

const model = GemmaModel(
  'Synthetic terms fixture',
  'fixture/no-license',
  'unit-v1',
  'fixture.bin',
  '0000000000000000000000000000000000000000000000000000000000000000',
  16,
  0,
);
const termsKey = 'modelTerms.fixture/no-license.unit-v1';

class HeldTermsWorker implements ReadWorker {
  HeldTermsWorker(Store store) : session = SqliteReadSession.borrow(store);
  final SqliteReadSession session;
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = true;
  final delivered = Completer<void>();
  final refreshed = Completer<void>();
  int calls = 0;
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) async {
    calls++;
    final reply = session.query(request.projection, request.arguments);
    if (hold &&
        request.projection == 'preference' &&
        request.arguments['key'] == termsKey) {
      hold = false;
      entered.complete();
      await release.future;
      delivered.complete();
    } else if (!refreshed.isCompleted) {
      refreshed.complete();
    }
    return reply;
  }

  @override
  Future<void> close() async => session.close();
}

Future<BuildContext> launcher(WidgetTester tester) async {
  late BuildContext result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          result = context;
          return const Scaffold(body: Text('Owned setup'));
        },
      ),
    ),
  );
  return result;
}

void main() {
  late Store store;
  late HeldTermsWorker worker;
  late SqliteStoreReader reader;
  setUp(() {
    final root = createTestTempDirectorySync('terms-freshness-');
    store = Store('${root.path}/app.db');
    addTearDown(store.close);
  });
  void initialize() {
    worker = HeldTermsWorker(store);
    reader = SqliteStoreReader.borrow(store, worker: worker);
    addTearDown(() async {
      if (!worker.release.isCompleted) worker.release.complete();
      await reader.close();
    });
  }

  for (final previouslyAccepted in [false, true]) {
    testWidgets(
      'terms wait for a current held snapshot after a model commit (previously accepted: $previouslyAccepted)',
      (tester) async {
        initialize();
        if (previouslyAccepted) store.setPreference(termsKey, 'accepted');
        final context = await launcher(tester);
        addTearDown(() => tester.pumpWidget(const SizedBox()));
        Object? problem;
        bool? accepted;
        var writes = 0;
        final work = confirmModelTerms(
          context,
          reader,
          model,
          savePreference: (key, value) async {
            writes++;
            store.setPreference(key, value);
          },
        );
        unawaited(
          work.then<void>(
            (value) => accepted = value,
            onError: (Object error) {
              problem = error;
            },
          ),
        );
        await tester.pump();
        expect(worker.entered.isCompleted, true);
        // Model registration is an ordinary data revision, not a new owner.
        store.db.execute(
          "INSERT INTO models(kind,path,digest,runtime) VALUES('embedding','/synthetic','synthetic','/synthetic')",
        );
        if (previouslyAccepted) store.setPreference(termsKey, '');
        reader.invalidate();
        worker.release.complete();
        await tester.pump();
        expect(worker.delivered.isCompleted, true);
        await tester.pumpAndSettle();
        expect(problem, isNull);
        expect(
          accepted,
          isNull,
          reason: 'Stale acceptance must not authorize the revised terms',
        );
        expect(find.text('Synthetic terms fixture terms'), findsOneWidget);
        expect(writes, 0);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(await work, false);
      },
    );
  }

  testWidgets(
    'workspace replacement during a held terms read cancels the old gesture',
    (tester) async {
      initialize();
      final context = await launcher(tester);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      Object? problem;
      bool? accepted;
      var writes = 0;
      final work = confirmModelTerms(
        context,
        reader,
        model,
        savePreference: (_, _) async {
          writes++;
        },
      );
      unawaited(
        work.then<void>(
          (value) => accepted = value,
          onError: (Object error) {
            problem = error;
          },
        ),
      );
      await tester.pump();
      expect(worker.entered.isCompleted, true);
      store.renewWorkspaceEpoch();
      reader.invalidate();
      worker.release.complete();
      await tester
          .pump(); // Deliver the held reply and enqueue its replacement.
      await tester.pump(); // Dispatch the replacement admission.
      await tester.pumpAndSettle();
      expect(problem, isNull);
      expect(accepted, false);
      expect(find.byType(AlertDialog), findsNothing);
      expect(writes, 0);
    },
  );

  testWidgets(
    'workspace replacement while synthetic consent is visible cannot save into the new owner',
    (tester) async {
      initialize();
      worker.hold = false;
      final context = await launcher(tester);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      var writes = 0;
      final work = confirmModelTerms(
        context,
        reader,
        model,
        savePreference: (_, _) async {
          writes++;
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic terms fixture terms'), findsOneWidget);
      store.renewWorkspaceEpoch();
      reader.invalidate();
      // Fictional fixture consent only; no real publisher terms are accepted.
      await tester.tap(
        find.widgetWithText(FilledButton, 'Accept and download'),
      );
      await tester.pumpAndSettle();
      expect(await work, false);
      expect(writes, 0);
    },
  );
}
