import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_catalog.dart';
import 'package:foresight_core/src/speech_model_catalog.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public budgets cover slow productive transfer and five disk passes',
    () {
      final dynamic downloader = PublicModelFileDownloader();
      for (final model in [
        ...gemmaModels,
        embeddingGemmaModel,
        ...speechModels,
      ]) {
        final policy =
            downloader.deadlinesFor(model) as ModelTransportDeadlines;
        final transfer = Duration(seconds: (model.bytes / (256 * 1024)).ceil());
        final io = Duration(seconds: (model.bytes * 5 / (1024 * 1024)).ceil());
        expect(policy.attempt, greaterThanOrEqualTo(transfer + io));
        expect(policy.total, greaterThan(policy.attempt));
        expect(policy.connect, const Duration(seconds: 30));
        expect(policy.headers, const Duration(seconds: 30));
        expect(policy.bodyIdle, const Duration(seconds: 30));
      }
      expect(
        (downloader.deadlinesFor(gemmaModels.first) as ModelTransportDeadlines)
            .attempt,
        greaterThan(const Duration(hours: 12)),
      );
      // Question-model policy retains exactly its existing bounds.
      const question = ModelTransportDeadlines();
      expect(question.attempt, const Duration(minutes: 5));
      expect(question.total, const Duration(minutes: 15));
    },
  );

  test(
    'caller asserted model sizes cannot extend or shrink pinned budgets',
    () {
      final dynamic downloader = PublicModelFileDownloader();
      final pinned = gemmaModels.first;
      for (final bytes in [1, 1 << 60]) {
        final claimed = GemmaModel(
          pinned.name,
          pinned.repository,
          pinned.revision,
          pinned.filename,
          pinned.digest,
          bytes,
          pinned.minimumMemoryGb,
        );
        final real = downloader.deadlinesFor(pinned) as ModelTransportDeadlines;
        final fake =
            downloader.deadlinesFor(claimed) as ModelTransportDeadlines;
        expect(fake.attempt, real.attempt);
        expect(fake.total, real.total);
      }
    },
  );
}
