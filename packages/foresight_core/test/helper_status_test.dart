import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/helper_status.dart';
import 'package:test/test.dart';

void main() {
  test(
    'immutable helper view preserves service status and exact graph identity',
    () {
      final model = control.ModelIdentity(
        modelDigest: 'digest',
        tokenizerDigest: 'tokens',
        preprocessing: 'text',
        backend: 'litert-lm-embedding-cpu',
        dimensions: 768,
        modalities: ['text'],
        path: '/model.litertlm',
      );
      final source = control.State(
        model: model,
        pipeline: 'ready',
        index: 'indexed',
        tokenizerReady: true,
        buildId: 'build',
        referenceVersion: 'protocol',
        instanceId: 'owner-1',
        activeGeneration: Int64.parseInt('9007199254740993'),
        lastError: '',
      );
      final status = HelperStatus.fromEvent({'helper': source.toProto3Json()});
      final snapshot = status.snapshot!;
      expect(status.state, 'live (service)');
      expect(snapshot.instanceId, 'owner-1');
      expect(snapshot.pipeline, 'ready');
      expect(snapshot.tokenizerReady, isTrue);
      expect(snapshot.activeGeneration, '9007199254740993');
      expect(snapshot.model.dimensions, 768);
      expect(snapshot.model.writeToJson(), model.writeToJson());
      model.backend = 'replacement';
      source.pipeline = 'failed';
      expect(snapshot.model.backend, 'litert-lm-embedding-cpu');
      expect(snapshot.pipeline, 'ready');
    },
  );

  test(
    'disconnected and failed service states contain no helper capability',
    () {
      const empty = HelperStatus();
      expect(empty.snapshot, isNull);
      expect(empty.state, 'disconnected');
      final failed = HelperStatus.fromEvent({
        'helper_state': 'failed to connect',
      });
      expect(failed.state, 'failed to connect');
      expect(failed.snapshot, isNull);
    },
  );
}
