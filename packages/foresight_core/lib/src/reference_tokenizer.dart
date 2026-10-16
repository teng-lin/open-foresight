import 'dart:async';
import 'generated/rag_service.pbgrpc.dart';

/// Original RemoteTokenizer.encode delegates unchanged text to RagService.
/// The caller owns the client/channel and decides whether a tokenizer is bound.
class ReferenceRemoteTokenizer {
  ReferenceRemoteTokenizer(this.client);
  final RagServiceClient client;

  Future<int> count(String text, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    final call = client.encode(EncodeRequest(text: text));
    final interrupted = Completer<EncodeResponse>();
    final monitor = checkCurrent == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 20), (_) {
            if (interrupted.isCompleted) return;
            try {
              checkCurrent();
            } catch (error, stack) {
              interrupted.completeError(error, stack);
              unawaited(call.cancel());
            }
          });
    try {
      final response = await Future.any([call, interrupted.future]);
      checkCurrent?.call();
      return response.tokens.length;
    } catch (_) {
      checkCurrent?.call();
      rethrow;
    } finally {
      monitor?.cancel();
    }
  }
}
