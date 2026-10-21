import 'dart:async';

import '../domain.dart';
import '../persistence/conversation_queries.dart';
import '../rpc_error.dart';
import 'answer_coordinator.dart';

/// Owns automatic-answer preparation and its orphaned producers. Cancelling
/// preparation never cancels the shared meeting index request or releases an
/// answer's busy accounting before the producer actually settles.
final class AutomaticAnswerCoordinator {
  AutomaticAnswerCoordinator({
    required this.domain,
    required this.answers,
    required this.indexMeeting,
    required this.cancelDetection,
    required this.changed,
  }) : _queries = ConversationQueries(domain.store);

  final Domain domain;
  final AnswerGateway Function() answers;
  final Future<void> Function(int) indexMeeting;
  final void Function(String) cancelDetection;
  final void Function() changed;
  final ConversationQueries _queries;
  final _preparations = <String, Completer<void>>{};
  final _producers = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;
  int _activeWork = 0;
  int get activeWork => _activeWork;

  /// Queue cancellation stays preemptible; application shutdown separately
  /// joins every actual answer producer, including pre-native retrieval.
  Future<void> close() => _closing ??= Future.sync(() async {
    _closed = true;
    for (final request in _preparations.keys.toList()) {
      cancel(request);
    }
    await Future.wait(_producers.toList());
  });

  void _observeProducer(Future<void> producer) {
    late final Future<void> settled;
    settled = producer
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _producers.remove(settled));
    _producers.add(settled);
  }

  void cancel(String request) {
    final preparation = _preparations[request];
    if (preparation != null && !preparation.isCompleted) {
      preparation.complete();
    }
    cancelDetection(request);
    domain.generator?.cancel(requestId: request);
  }

  Future<int> run(int id, String question, String request) async {
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    final cancelled = Completer<void>();
    _preparations[request] = cancelled;
    Future<Never> cancellation() => cancelled.future.then(
      (_) =>
          throw RpcError(RpcErrorCode.cancelled, 'Automatic answer cancelled'),
    );
    void checkCurrent() {
      if (_closed || cancelled.isCompleted) {
        throw RpcError(RpcErrorCode.cancelled, 'Automatic answer cancelled');
      }
    }

    try {
      await Future.any<void>([indexMeeting(id), cancellation()]);
      checkCurrent();
      _activeWork++;
      final answerWork = answers()
          .ask(
            question,
            'meeting:$id',
            meetingId: id,
            requestId: request,
            current: () => !_closed && !cancelled.isCompleted,
          )
          .drain<void>()
          .whenComplete(() {
            _activeWork--;
            changed();
          });
      _observeProducer(answerWork);
      await Future.any<void>([answerWork, cancellation()]);
      checkCurrent();
      final saved = _queries.savedAnswerId(request);
      if (saved == null) throw StateError('No answer was saved');
      return saved;
    } finally {
      _preparations.remove(request);
    }
  }
}
