import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:foresight_core/desktop.dart';

import '../../feature_request_identity.dart';

String chatConversation(int? meeting) =>
    meeting == null ? 'desktop' : 'meeting:$meeting';

/// Citation JSON is decoded when accepting a projection, never while building.
final class ChatAnswer {
  ChatAnswer.fromRead(SavedAnswer answer)
    : id = answer.id,
      question = answer.question,
      body = answer.body,
      status = answer.status,
      citations = answer.citations;
  final int id;
  final String question, body, status;
  final List<Citation> citations;
}

/// History and its scope travel together. Unresolved scope freshness hides
/// scoped output without cancelling an answer for an unrelated data change.
final class ChatConversationState {
  const ChatConversationState({
    this.scope,
    this.answers = const [],
    this.loading = true,
    this.error = '',
  });
  final AnswerScopeSnapshot? scope;
  final List<ChatAnswer> answers;
  final bool loading;
  final String error;

  bool equivalent(ChatConversationState other) =>
      scope?.identity == other.scope?.identity &&
      loading == other.loading &&
      error == other.error &&
      _sameAnswers(answers, other.answers);
}

bool _sameAnswers(List<ChatAnswer> left, List<ChatAnswer> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    final a = left[i], b = right[i];
    if ((a.id, a.question, a.body, a.status) !=
        (b.id, b.question, b.body, b.status))
      return false;
    final ac = a.citations, bc = b.citations;
    if (ac.length != bc.length) return false;
    for (var j = 0; j < ac.length; j++) {
      final x = ac[j], y = bc[j];
      if ((
            x.kind,
            x.documentId,
            x.revision,
            x.label,
            x.excerpt,
            x.url,
            x.title,
          ) !=
          (
            y.kind,
            y.documentId,
            y.revision,
            y.label,
            y.excerpt,
            y.url,
            y.title,
          ))
        return false;
    }
  }
  return true;
}

/// One scope query and one history query per mounted/answering conversation.
/// Ordinary revisions never replace their scheduling entries. A changed scope
/// replaces history's identity; owner replacement retires every old callback.
final class ChatConversationModel extends ChangeNotifier {
  ChatConversationModel(this.connection, this.meeting);
  final DesktopConnection connection;
  final int? meeting;
  late final _scopeQuery = StoreReadQueries.answerScope(
    chatConversation(meeting),
    meeting: meeting,
  );
  ChatConversationState _value = const ChatConversationState();
  ChatConversationState get value => _value;
  AnswerScopeSnapshot? _scope;
  List<ChatAnswer> _answers = const [];
  String _scopeRevision = '', _error = '', _historyError = '';
  Object? _scopeFailure;
  bool _uncertain = true, _disposed = false, _started = false;
  int _ownerGeneration = 0, _historyGeneration = 0;
  FeatureRequestIdentity? _identity;
  StreamSubscription<void>? _changes;
  StreamSubscription<ReadResult<AnswerScopeSnapshot>>? _scopeRead;
  StreamSubscription<ReadResult<List<SavedAnswer>>>? _historyRead;
  ReadResult<List<SavedAnswer>>? _pendingHistory;
  final _waiters = <Completer<AnswerScopeSnapshot>>[];
  StreamSubscription<ReadResult<AnswerScopeSnapshot>>? _validationRead;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _changes = connection.changes.listen((_) {
      if (!_current()) {
        _bind();
      } else if (_scopeRevision != connection.store.dataRevision) {
        _uncertain = true;
        _publish();
      }
    });
    _bind();
  }

  bool _current() =>
      !_disposed && (_identity?.isCurrent(connection, alive: true) ?? false);

  void _bind() {
    final generation = ++_ownerGeneration;
    _historyGeneration++;
    unawaited(_scopeRead?.cancel());
    unawaited(_historyRead?.cancel());
    unawaited(_validationRead?.cancel());
    _validationRead = null;
    _cancelWaiters();
    _identity = FeatureRequestIdentity.capture(connection);
    _scope = null;
    _answers = const [];
    _scopeRevision = '';
    _pendingHistory = null;
    _uncertain = true;
    _error = '';
    _historyError = '';
    _scopeFailure = null;
    _publish();
    _scopeRead = connection.store.watch(_scopeQuery).listen((result) {
      if (generation == _ownerGeneration && _current()) _acceptScope(result);
    });
  }

  void _acceptScope(ReadResult<AnswerScopeSnapshot> result) {
    if (result.error != null) {
      _error = result.error.toString();
      _scopeFailure = result.error;
      _uncertain = true;
      _failWaiters(result.error!);
      _publish();
      return;
    }
    if (!result.current || result.value == null) return;
    final scope = result.value!;
    if (_scope?.identity != scope.identity) {
      _scope = scope;
      _answers = const [];
      _pendingHistory = null;
      final generation = ++_historyGeneration;
      unawaited(_historyRead?.cancel());
      _historyRead = connection.store
          .watch(
            StoreReadQueries.answers(
              meeting,
              scope: scope.identity,
              privateScope: scope.mode != 'workspace',
            ),
          )
          .listen((result) {
            if (!_current() || generation != _historyGeneration) return;
            if (result.error != null) {
              _historyError = result.error.toString();
              _publish();
            } else if (result.current && result.value != null) {
              _historyError = '';
              _pendingHistory = result;
              if (!_uncertain &&
                  _scopeRevision == connection.store.dataRevision)
                _acceptHistory();
            }
          });
    }
    _scopeRevision = result.requestTag;
    _uncertain = _scopeRevision != connection.store.dataRevision;
    _error = '';
    _scopeFailure = null;
    if (!_uncertain) {
      _acceptHistory();
      final waiters = _waiters.toList();
      _waiters.clear();
      for (final waiter in waiters) waiter.complete(scope);
    }
    _publish();
  }

  void _acceptHistory() {
    final pending = _pendingHistory;
    if (pending != null) {
      _answers = List.unmodifiable(pending.value!.map(ChatAnswer.fromRead));
      _pendingHistory = null;
      _publish();
    }
  }

  /// Stream publication waits for scope verification after a commit. The same
  /// scope keeps the producer alive; a different identity retires its output.
  Future<AnswerScopeSnapshot> currentScope() {
    start();
    if (!_current()) return Future.error(_cancelled());
    if (_scopeFailure != null) return Future.error(_scopeFailure!);
    if (!_uncertain &&
        _scope != null &&
        _scopeRevision == connection.store.dataRevision) {
      return Future.value(_scope!);
    }
    final waiter = Completer<AnswerScopeSnapshot>();
    _waiters.add(waiter);
    if (!_uncertain && _validationRead == null) {
      // An action can observe a commit before its service event. The temporary
      // subscriber requests freshness on the same key and is owned/cancelled
      // with this session, so a replacement cannot join a retired request.
      final generation = _ownerGeneration;
      late StreamSubscription<ReadResult<AnswerScopeSnapshot>> validation;
      void release() {
        unawaited(validation.cancel());
        if (identical(_validationRead, validation)) _validationRead = null;
      }

      validation = connection.store
          .watch(_scopeQuery)
          .listen(
            (result) {
              if (_current() && generation == _ownerGeneration)
                _acceptScope(result);
              release();
            },
            onError: (Object error) {
              if (_current() && generation == _ownerGeneration)
                _failWaiters(error);
              release();
            },
          );
      _validationRead = validation;
    }

    return waiter.future;
  }

  void _publish() {
    if (_disposed) return;
    final next = ChatConversationState(
      scope: _scope,
      answers: _uncertain ? const [] : _answers,
      loading: _uncertain,
      error: _error.isEmpty ? _historyError : _error,
    );
    if (_value.equivalent(next)) return;
    _value = next;
    notifyListeners();
  }

  RpcError _cancelled() =>
      RpcError(RpcErrorCode.cancelled, 'Chat conversation retired');
  void _failWaiters(Object error) {
    final waiters = _waiters.toList();
    _waiters.clear();
    for (final waiter in waiters) waiter.completeError(error);
  }

  void _cancelWaiters() => _failWaiters(_cancelled());

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ownerGeneration++;
    _historyGeneration++;
    _cancelWaiters();
    unawaited(_changes?.cancel());
    unawaited(_scopeRead?.cancel());
    unawaited(_historyRead?.cancel());
    unawaited(_validationRead?.cancel());
    super.dispose();
  }
}
