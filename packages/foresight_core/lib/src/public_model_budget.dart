import 'model_catalog.dart';
import 'speech_model_catalog.dart';

/// Public assets can be several GB. Allow a 256 KiB/s productive connection and
/// five full disk passes at 1 MiB/s (cache reads, assembly and authentication),
/// in addition to startup/phase headroom. Each retry has a finite whole-file
/// budget. Only independently pinned catalog sizes influence these limits.
Duration publicModelAttemptBudget(GemmaModel requested) {
  final pinned = [
    ...gemmaModels,
    embeddingGemmaModel,
    ...speechModels,
  ].where((model) => model.digest == requested.digest).firstOrNull;
  // Explicit source/cache fixtures do not control a production size budget.
  final bytes = pinned?.bytes ?? 0;
  int secondsFor(int size, int rate) => (size + rate - 1) ~/ rate;
  return const Duration(minutes: 5) +
      Duration(
        seconds:
            secondsFor(bytes, 256 * 1024) + secondsFor(bytes * 5, 1024 * 1024),
      );
}
