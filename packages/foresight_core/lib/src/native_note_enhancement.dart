import 'rpc_error.dart';
import 'native.dart';
import 'reference_note_enhancer.dart';

/// Adapts the owned native conversation protocol to the original incremental
/// note producer. The final native answer repeats cumulative streamed text.
class NativeNoteEnhancementConversation implements NoteEnhancementConversation {
  NativeNoteEnhancementConversation._(
    this.runtime,
    this.requestId,
    this.settings,
  );

  static NativeNoteEnhancementConversation create({
    required NativeRuntime runtime,
    required String requestId,
    required NoteEnhancementConversationSettings settings,
  }) {
    final stops = settings.stopTokenIds;
    if (stops != null &&
        stops.any((sequence) => sequence.isNotEmpty) &&
        runtime.effectiveState['native_stop_token_sequences'] != true) {
      throw StateError(
        'The generation runtime lacks native stop-token sequence support',
      );
    }
    return NativeNoteEnhancementConversation._(runtime, requestId, settings);
  }

  final NativeRuntime runtime;
  final String requestId;
  final NoteEnhancementConversationSettings settings;
  bool _started = false, _closed = false;

  @override
  Stream<String> sendMessageStream(String prompt) async* {
    if (_started || _closed) throw StateError('Conversation is not available');
    _started = true;
    var previous = '', status = 'failed', failure = '';
    await for (final event in runtime.generateConversation(
      requestId,
      prompt,
      maxOutputTokens: null,
      maxInputTokens: settings.maxInputTokens,
      stopTokenIds: settings.stopTokenIds ?? const [],
    )) {
      if (event['type'] == 'preview' || event['type'] == 'delta') {
        final cumulative = event['text'] as String;
        if (!cumulative.startsWith(previous)) {
          throw StateError(
            'Native conversation revised streamed response text',
          );
        }
        final delta = cumulative.substring(previous.length);
        previous = cumulative;
        if (delta.isNotEmpty) yield delta;
      }
      if (event['type'] == 'error') failure = event['message'].toString();
      if (event['type'] == 'done') status = event['status'] as String;
    }
    if (status == 'cancelled') {
      throw RpcError(RpcErrorCode.cancelled, 'Generation $status: $failure');
    }
    if (status != 'completed') throw StateError('Generation $status: $failure');
  }

  @override
  Future<void> cancelProcess() async {
    runtime.cancel(requestId: requestId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    runtime.cancel(requestId: requestId);
  }
}
