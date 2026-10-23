import 'dart:async';

import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

import '../../feature_request_identity.dart';
import '../../shell/ports.dart'
    show
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        MeetingActivity,
        SourceCommands;
import '../../shell/workspace_tab.dart';
import 'ports.dart';
import 'read_model.dart';
import 'widgets.dart';

class ChatController extends ChangeNotifier implements ChatPort {
  ChatController({
    required FeatureHost host,
    required WorkspaceNavigation navigation,
    required OperationGate operations,
    required MeetingActivity meetings,
    required SourceCommands sources,
  }) : _host = host,
       _navigation = navigation,
       _operations = operations,
       _meetings = meetings,
       _sources = sources;
  final FeatureHost _host;
  final WorkspaceNavigation _navigation;
  final OperationGate _operations;
  final MeetingActivity _meetings;
  final SourceCommands _sources;
  DesktopConnection get d => _host.connection;
  BuildContext get context => _host.context;
  bool get mounted => !_disposed && _host.mounted;
  bool _disposed = false;
  @override
  bool asking = false;
  final webSearchScopes = <String>{};
  @override
  double answerFontSize = 16;
  final hiddenAnswers = <int>{};
  String answer = '';
  String? askingScope;
  int _answerGeneration = 0;
  bool Function()? _answerCurrent;
  final questionDrafts = <String, TextEditingController>{};
  final _models = <String, ChatConversationModel>{};
  final _views = <String, int>{}, _producers = <String, int>{};

  void update(VoidCallback action) {
    if (!mounted) return;
    _host.update(() {
      action();
      notifyListeners();
    });
  }

  ChatConversationModel _model(int? meeting) =>
      _models.putIfAbsent(chatConversation(meeting), () {
        final model = ChatConversationModel(d, meeting);
        model.addListener(_modelChanged);
        scheduleMicrotask(() {
          if (mounted && (_views[chatConversation(meeting)] ?? 0) > 0)
            model.start();
        });
        return model;
      });
  void _modelChanged() {
    if (mounted)
      update(() {
        retireChangedAnswer();
      });
  }

  void attach(int? meeting) {
    final scope = chatConversation(meeting);
    _views.update(scope, (count) => count + 1, ifAbsent: () => 1);
    final model = _model(meeting);
    scheduleMicrotask(() {
      if (mounted && (_views[scope] ?? 0) > 0) model.start();
    });
  }

  void detach(int? meeting) {
    final scope = chatConversation(meeting);
    _views.update(scope, (count) => count - 1);
    _release(scope);
  }

  void _release(String scope) {
    if ((_views[scope] ?? 0) > 0 || (_producers[scope] ?? 0) > 0) return;
    _models.remove(scope)?.dispose();
  }

  bool get hasUnsavedDrafts =>
      questionDrafts.values.any((draft) => draft.text.isNotEmpty);
  TextEditingController questionFor(int? meetingScope) => questionDrafts
      .putIfAbsent(chatConversation(meetingScope), TextEditingController.new);
  TextEditingController get question => questionFor(
    _navigation.selectedTab == WorkspaceTab.meetings
        ? _meetings.selectedMeetingId
        : null,
  );
  @override
  void setQuestion(int? meetingScope, String text) =>
      questionFor(meetingScope).text = text;
  @override
  void setAnswerFontSize(double value) => update(() => answerFontSize = value);

  bool retireChangedAnswer() {
    final current = _answerCurrent;
    if (current == null || current()) return false;
    retireAnswer();
    return true;
  }

  void retireAnswer() {
    _answerGeneration++;
    _answerCurrent = null;
    answer = '';
    asking = false;
    askingScope = null;
  }

  void resetWorkspaceViews() {
    retireAnswer();
    hiddenAnswers.clear();
    for (final draft in questionDrafts.values) draft.clear();
    for (final model in _models.values) model.dispose();
    _models.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    retireAnswer();
    for (final model in _models.values) model.dispose();
    _models.clear();
    for (final draft in questionDrafts.values) draft.dispose();
    questionDrafts.clear();
    super.dispose();
  }

  @override
  void citation(Map<String, Object?> citation) =>
      cite(Citation.fromRow(citation));
  void cite(Citation citation) {
    if (citation.kind == 'web') {
      unawaited(_operations.run(() => _openCitation(citation)));
      return;
    }
    // A source dialog remains editable while it is open. Match the original
    // local citation path, and report an asynchronous lookup failure only while
    // this feature still owns it.
    final identity = FeatureRequestIdentity.capture(d);
    unawaited(
      _openCitation(citation).catchError((Object failure) {
        if (identity.isCurrent(d, alive: mounted)) {
          _operations.reportAsyncError(failure);
        }
      }),
    );
  }

  Future<void> _openCitation(Citation citation) async {
    final identity = FeatureRequestIdentity.capture(d);
    if (citation.kind == 'web') {
      final uri = Uri.tryParse(citation.url ?? '');
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw StateError('This citation has no valid web address.');
      }
      await _host.environment.openUri(uri);
      return;
    }
    final opened = await _sources.sourceById(
      citation.documentId,
      expectedRevision: citation.revision,
    );
    if (opened || !identity.isCurrent(d, alive: mounted) || !context.mounted)
      return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archived citation: source changed or deleted'),
        content: SelectableText(citation.excerpt),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Future<void> askQuestion({int? meetingScope}) => _operations.run(() async {
    if (_meetings.meetingEnhancing)
      throw StateError('Wait for note enhancement to finish.');
    final draft = questionFor(meetingScope),
        prompt = questionFor(meetingScope).text;
    if (prompt.trim().isEmpty) throw StateError('Enter a question.');
    final scope = chatConversation(meetingScope);
    _producers.update(scope, (count) => count + 1, ifAbsent: () => 1);
    final model = _model(meetingScope);
    final identity = FeatureRequestIdentity.capture(d);
    final generation = ++_answerGeneration;
    AnswerScopeSnapshot? sourceScope;
    bool current() =>
        generation == _answerGeneration &&
        identity.isCurrent(d, alive: mounted) &&
        (sourceScope == null ||
            model.value.scope?.identity == sourceScope.identity);
    _answerCurrent = current;
    try {
      sourceScope = await model.currentScope();
      if (!current()) return;
      update(() {
        answer = '';
        asking = true;
        askingScope = scope;
      });
      var acknowledged = false;
      void acknowledge() {
        if (acknowledged) return;
        acknowledged = true;
        if (draft.text == prompt) draft.clear();
      }

      final ask = webSearchScopes.contains(scope)
          ? d.askWithWebInConversation
          : d.askInConversation;
      await for (final text in ask(
        prompt,
        scope,
        meetingId: meetingScope,
        current: current,
      )) {
        final fresh = await model.currentScope();
        if (!current() || fresh.identity != sourceScope.identity) break;
        update(() {
          acknowledge();
          answer = text;
        });
      }
      final fresh = await model.currentScope();
      if (current() && fresh.identity == sourceScope.identity)
        update(acknowledge);
    } catch (_) {
      if (current()) rethrow;
    } finally {
      if (mounted && generation == _answerGeneration)
        update(() {
          asking = false;
          askingScope = null;
          _answerCurrent = null;
        });
      _producers.update(scope, (count) => count - 1);
      _release(scope);
    }
  });

  @override
  Widget chat({int? meetingScope, bool compact = false}) =>
      ChatView(controller: this, meetingScope: meetingScope, compact: compact);
  Widget buildConversation({int? meetingScope, bool compact = false}) {
    final scope = meetingScope == null ? 'desktop' : 'meeting:$meetingScope';
    final searchWeb = webSearchScopes.contains(scope);
    final scopeAsking = asking && askingScope == scope;
    final question = questionFor(meetingScope);
    final state = _model(meetingScope).value;
    if (state.error.isNotEmpty) return SelectableText(state.error);
    final history = state.answers
        .where((answer) => !hiddenAnswers.contains(answer.id))
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: EdgeInsets.all(compact ? 20 : 28),
      child: Column(
        children: [
          ChatHistory(
            history: history,
            loading: state.loading,
            scope: scope,
            scopeAsking: scopeAsking,
            searchWeb: searchWeb,
            answer: answer,
            answerFontSize: answerFontSize,
            openLink: _host.environment.openUri,
            onClose: (id) => update(() => hiddenAnswers.add(id)),
            cite: cite,
          ),
          ChatControls(
            history: history,
            compact: compact,
            asking: asking,
            searchWeb: searchWeb,
            webSearchAvailable: d.webSearchAvailable,
            onToggleWeb: () => update(() {
              if (searchWeb) {
                webSearchScopes.remove(scope);
              } else {
                webSearchScopes.add(scope);
              }
            }),
            onSmaller: () =>
                setAnswerFontSize((answerFontSize - 1).clamp(12, 24)),
            onLarger: () =>
                setAnswerFontSize((answerFontSize + 1).clamp(12, 24)),
          ),
          ChatComposer(
            question: question,
            scope: scope,
            compact: compact,
            scopeAsking: scopeAsking,
            busy: _operations.busy,
            enhancing: _meetings.meetingEnhancing,
            onAsk: () => askQuestion(meetingScope: meetingScope),
            onCancel: () => d.generator?.cancel(),
          ),
        ],
      ),
    );
  }
}
