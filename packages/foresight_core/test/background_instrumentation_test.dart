import 'dart:async';
import 'dart:io';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/reference_note_transcript_cache.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  for (final discard in ['clear', 'invalidate', 'evict']) {
    test('embedding drain remains computing after $discard', () async {
      final entered = Completer<void>(), release = Completer<void>();
      var settled = 0;
      final cache = ReferenceNoteTranscriptCache(
        computeEmbedding: (_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return [1.0];
        },
        currentIsLive: (_) => false,
        loadSavedTranscript: (_) async => 'text',
        onSettled: () => settled++,
      );
      final work = cache.schedule(1, 'a sentence', isLive: false);
      await entered.future;
      expect(cache.computing, 1);
      if (discard == 'clear') cache.clear();
      if (discard == 'invalidate') cache.invalidate(1);
      if (discard == 'evict') {
        for (var id = 2; id < 8; id++) {
          cache.schedule(id, '', isLive: false).ignore();
        }
      }
      expect(cache.computing, greaterThanOrEqualTo(1));
      release.complete();
      await work;
      expect(cache.computing, 0);
      expect(settled, greaterThanOrEqualTo(1));
    });
  }
  test('helper startup flag clears after a held adoption probe', () async {
    final root = createTestTempDirectorySync('probe-');
    final environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment['FORESIGHT_HELPER'] =
        '/must-not-launch-a-second-helper';
    final rag = HeldPing();
    final server = Server.create(
      services: [rag, AdoptionControl(control.State())],
    );
    final socket = '${root.path}/h.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    final helper = Helper(
      socket,
      root.path,
      startupProbeTimeout: const Duration(seconds: 10),
    );
    addTearDown(() async {
      if (!rag.release.isCompleted) rag.release.complete();
      await helper.close();
      await server.shutdown();
      root.deleteSync(recursive: true);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
    expect(await helper.verifyAdoptedIdentity(), AdoptedIdentity.notAdopted);
    // Invalid compatibility is expected after the held probe; the completion flag must still clear.
    final work = helper.start();
    final failed = expectLater(work, throwsStateError);
    await rag.entered.future;
    expect(helper.starting, true);
    rag.release.complete();
    await failed;
    expect(helper.starting, false);
    helper.snapshot = control.State(instanceId: '0-1');
    expect(await helper.verifyAdoptedIdentity(), AdoptedIdentity.unknown);
  });
}
