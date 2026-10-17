/// Recover original note generation readiness (0x100a2cf98–0x100a2d010).
/// A null/unready result permits exactly one reset and reacquisition. Exceptions
/// from acquisition, readiness checking, or reset propagate without retry.
/// The caller constructs the final error, including the original asynchronous
/// installed-model check when the second acquired service is still unavailable.
Future<T> acquireNoteEnhancementService<T extends Object>({
  required Future<T?> Function() getService,
  required bool Function(T service) isReady,
  required Future<void> Function() abortAndReset,
  required Future<Object> Function() unavailableError,
}) async {
  var service = await getService();
  if (service == null || !isReady(service)) {
    await abortAndReset();
    service = await getService();
  }
  if (service == null || !isReady(service)) {
    throw await unavailableError();
  }
  return service;
}
