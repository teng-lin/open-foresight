import 'rpc_error.dart';
import 'dart:async';
import 'native.dart';
import 'reference_note_enhancer.dart';

/// Adapts the owned native conversation protocol to the original incremental
/// note producer. The final native answer repeats cumulative streamed text.
class NativeNoteEnhancementConversation implements NoteEnhancementConversation {
  NativeNoteEnhancementConversation._(
    this.runtime,
    this.requestId,
    this.settings,
    this.current,
  );

  static NativeNoteEnhancementConversation create({
    required NativeRuntime runtime,
    required String requestId,
    required NoteEnhancementConversationSettings settings,
    bool Function()? current,
  }) {
    final stops = settings.stopTokenIds;
    if (stops != null &&
        stops.any((sequence) => sequence.isNotEmpty) &&
        runtime.effectiveState['native_stop_token_sequences'] != true) {
      throw StateError(
        'The generation runtime lacks native stop-token sequence support',
      );
    }
    return NativeNoteEnhancementConversation._(
      runtime,
      requestId,
      settings,
      current,
    );
  }

  final NativeRuntime runtime;
  final String requestId;
  final NoteEnhancementConversationSettings settings;
  final bool Function()? current;
  bool _started = false, _closed = false;
  Future<void>? _closing;

  @override
  Stream<String> sendMessageStream(String prompt) async* {
    if (_started || _closed) throw StateError('Conversation is not available');
    _started = true;
    final monitor = current == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 20), (_) {
            if (!current!()) runtime.cancel(requestId: requestId);
          });
    var previous = '', status = 'failed', failure = '';
    try {
      await for (final event in runtime.generateConversation(
        requestId,
        prompt,
        maxOutputTokens: null,
        maxInputTokens: settings.maxInputTokens,
        stopTokenIds: settings.stopTokenIds ?? const [],
      )) {
        if (!(current?.call() ?? true)) {
          throw RpcError(RpcErrorCode.cancelled, 'Note enhancement cancelled');
        }
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
      if (status != 'completed') {
        throw StateError('Generation $status: $failure');
      }
    } finally {
      monitor?.cancel();
    }
  }

  @override
  Future<void> cancelProcess() => runtime.cancelAndDrain(requestId: requestId);

  @override
  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    return _closing = runtime.cancelAndDrain(requestId: requestId);
  }
}
