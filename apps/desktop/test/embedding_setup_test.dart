import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/generated/rag_service.pbgrpc.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class EmbeddingSetupService extends RagServiceBase {
  final requests = <UpdateModelPathsRequest>[];
  bool accept = false;
  @override
  Future<UpdateModelPathsResponse> updateModelPaths(
    ServiceCall call,
    UpdateModelPathsRequest request,
  ) async {
    requests.add(request);
    return UpdateModelPathsResponse(
      success: accept,
      errorMessage: accept ? '' : 'GPU unavailable',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('GPU registration persists only after helper acceptance', (
    tester,
  ) async {
    final temporary = Directory.systemTemp.createTempSync(
      'foresight-embedding-setup-',
    );
    final original = File('${temporary.path}/old.model')
      ..writeAsStringSync('old registration');
    final candidate = File('${temporary.path}/candidate.litertlm')
      ..writeAsStringSync('candidate registration');
    final store = Store('${temporary.path}/app.db');
    await tester.runAsync(() => store.register('embedding', original.path, ''));
    final previous = store
        .rows("SELECT * FROM models WHERE kind='embedding'")
        .single;
    final service = EmbeddingSetupService();
    final server = Server.create(services: [service]);
    final socket = '${temporary.path}/helper.sock';
    await tester.runAsync(
      () => server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      ),
    );
    final helper = OfflineHelper(socket, '${temporary.path}/helper');
    try {
      await tester.pumpWidget(
        Foresight(Domain(store, helper), deviceLoader: () async => []),
      );
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() {
        state.tab = 4;
      });
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), candidate.path);
      await tester.tap(find.text('Use GPU for EmbeddingGemma 2'));
      await tester.pumpAndSettle();
      Future<void> register() async {
        await tester.runAsync(() async {
          await tester.tap(find.text('Register and load'));
          for (var i = 0; i < 100 && state.busy == true; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(state.busy, false);
        });
        await tester.pumpAndSettle();
      }

      await register();
      expect(service.requests.single.useGpu, true);
      expect(find.text('GPU unavailable'), findsOneWidget);
      expect(
        store.rows("SELECT * FROM models WHERE kind='embedding'").single,
        previous,
      );
      service.accept = true;
      await register();
      final installed = store
          .rows("SELECT * FROM models WHERE kind='embedding'")
          .single;
      expect(installed['path'], candidate.absolute.path);
      expect(installed['backend'], 'litert_lm_embedding_gpu');
      expect(service.requests.length, 2);
      expect(tester.takeException(), isNull);
    } finally {
      // Disposal initiates real gRPC I/O; keep its completion callbacks outside
      // Flutter's fake clock, just like the explicit channel/server cleanup.
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.runAsync(() async {
        await helper.close();
        await server.shutdown();
      });
      temporary.deleteSync(recursive: true);
    }
  });
}
