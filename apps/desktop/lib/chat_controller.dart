part of 'main.dart';

class _ChatController extends _FeatureController {
  _ChatController(super.shell);

  bool asking = false;

  final webSearchScopes = <String>{};

  double answerFontSize = 16;

  final hiddenAnswers = <int>{};

  String answer = '';

  String? askingScope;

  int _answerGeneration = 0;
  bool Function()? _answerCurrent;

  AnswerScopeSnapshot _sourceScope(int? meeting) {
    final conversation = meeting == null ? 'desktop' : 'meeting:$meeting';
    return AnswerScopeSnapshot.fromPreferences(
      mode: d.store.preference('answerScope.$conversation', 'workspace'),
      selectedJson: d.store.preference('answerSources.$conversation', '[]'),
      meeting: meeting,
    );
  }

  /// A feature session is distinct from a retained SQLite reader or pathname.
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

  final questionDrafts = <String, TextEditingController>{};

  TextEditingController questionFor(int? meetingScope) =>
      questionDrafts.putIfAbsent(
        meetingScope == null ? 'desktop' : 'meeting:$meetingScope',
        TextEditingController.new,
      );

  TextEditingController get question =>
      questionFor(shell.tab == 3 ? meetingFeature.meetingId : null);

  void citation(Map c) {
    if (c['kind'] == 'web') {
      unawaited(
        shell.run(() async {
          final uri = Uri.tryParse(c['url'] as String? ?? '');
          if (uri == null ||
              !['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty) {
            throw StateError('This citation has no valid web address.');
          }
          await widget.environment.openUri(uri);
        }),
      );
      return;
    }
    final s = d.store.sourceById(
      c['document_id'] as String,
      includeDeleted: true,
    );
    if (s == null || s.deleted || s.revision != c['revision']) {
      // The callback intentionally schedules work owned by its controller.
      // ignore: discarded_futures
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Archived citation: source changed or deleted'),
          content: SelectableText(c['excerpt'] as String),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      // The callback intentionally schedules work owned by its controller.
      // ignore: discarded_futures
      sourceFeature.source(s.toRow());
    }
  }

  Future<void> askQuestion({int? meetingScope}) => shell.run(() async {
    if (meetingFeature.meetingEnhancing)
      throw StateError('Wait for note enhancement to finish.');
    final draft = questionFor(meetingScope);
    final prompt = draft.text;
    if (prompt.trim().isEmpty) throw StateError('Enter a question.');
    final scope = meetingScope == null ? 'desktop' : 'meeting:$meetingScope';
    final sourceScope = _sourceScope(meetingScope);
    final identity = FeatureRequestIdentity.capture(d);
    final generation = ++_answerGeneration;
    bool current() {
      if (generation != _answerGeneration ||
          !identity.isCurrent(d, alive: mounted)) {
        return false;
      }
      try {
        return sourceScope.identity == _sourceScope(meetingScope).identity;
      } catch (_) {
        // An invalid or retired read boundary cannot authorize publication.
        return false;
      }
    }

    _answerCurrent = current;
    shell.update(() {
      answer = '';
      asking = true;
      askingScope = scope;
    });
    try {
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
        if (!current()) break;
        if (mounted)
          shell.update(() {
            // The first accepted response acknowledges submission. Preserve a
            // replacement draft typed while the request was being accepted.
            acknowledge();
            answer = text;
          });
      }
      if (current()) shell.update(acknowledge);
    } catch (_) {
      if (current()) rethrow;
    } finally {
      if (mounted && generation == _answerGeneration)
        shell.update(() {
          asking = false;
          askingScope = null;
          _answerCurrent = null;
        });
    }
  });

  Widget chat({int? meetingScope, bool compact = false}) {
    final scope = meetingScope == null ? 'desktop' : 'meeting:$meetingScope';
    final searchWeb = webSearchScopes.contains(scope);
    final scopeAsking = asking && askingScope == scope;
    final question = questionFor(meetingScope);
    AnswerScopeSnapshot sourceScope;
    try {
      sourceScope = _sourceScope(meetingScope);
    } catch (error) {
      return SelectableText(failureText(error));
    }
    final history = readRows(d.store.conversationAnswers(meetingScope))
        .where(
          (a) =>
              !hiddenAnswers.contains(a['id']) &&
              (sourceScope.mode == 'workspace' ||
                  d.store.preference('answerScope.v1.${a['id']}') ==
                      sourceScope.identity),
        )
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: EdgeInsets.all(compact ? 20 : 28),
      child: Column(
        children: [
          Expanded(
            child: history.isEmpty && !scopeAsking
                ? const Center(
                    child: Text(
                      'Get answer from your personalized\nknowledge sources.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, color: Color(0xff87a8b7)),
                    ),
                  )
                : ListView(
                    key: ValueKey('chat-history:$scope'),
                    children: [
                      for (final a in history)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      a['question'] as String,
                                      style: const TextStyle(
                                        fontSize: 21,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Close answer',
                                    onPressed: () => shell.update(
                                      () => hiddenAnswers.add(a['id'] as int),
                                    ),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                              GeneratedContent(
                                a['body'] as String,
                                openLink: widget.environment.openUri,
                                fontSize: answerFontSize,
                              ),
                              if (a['status'] != 'completed')
                                Text('Status: ${a['status']}'),
                              Wrap(
                                children: (jsonDecode(a['citations'] as String) as List)
                                    .map(
                                      (c) => TextButton(
                                        onPressed: () => citation(c as Map),
                                        child: Text(
                                          c['kind'] == 'web'
                                              ? '[${c['citation']}] ${c['title'] == '' ? c['url'] : c['title']}'
                                              : '[${c['citation']}] source revision ${c['revision']}',
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                              const Divider(),
                            ],
                          ),
                        ),
                      if (scopeAsking)
                        GeneratedContent(
                          answer.isEmpty
                              ? searchWeb
                                    ? 'Preparing your answer…'
                                    : 'Searching your knowledge…'
                              : answer,
                          fontSize: answerFontSize,
                          openLink: widget.environment.openUri,
                        ),
                    ],
                  ),
          ),
          Row(
            children: [
              IconButton(
                key: const ValueKey('chat-web-search'),
                tooltip: d.webSearchAvailable
                    ? searchWeb
                          ? 'Answer include web search result'
                          : 'Answer does not use web search'
                    : 'Web search is unavailable in this build',
                isSelected: searchWeb,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffeeeeee),
                  foregroundColor: const Color(0xff757575),
                  minimumSize: const Size(36, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: asking || (!d.webSearchAvailable && !searchWeb)
                    ? null
                    : () => shell.update(() {
                        if (searchWeb) {
                          webSearchScopes.remove(scope);
                        } else {
                          webSearchScopes.add(scope);
                        }
                      }),
                icon: const Icon(Icons.travel_explore, size: 18),
                selectedIcon: const Icon(
                  Icons.travel_explore,
                  size: 18,
                  color: _ink,
                ),
              ),
              const Spacer(),
              if (history.isNotEmpty && !compact)
                TextButton(
                  onPressed: () => shell.update(
                    () => answerFontSize = (answerFontSize - 1).clamp(12, 24),
                  ),
                  child: const Text('A−'),
                ),
              if (history.isNotEmpty && !compact)
                TextButton(
                  onPressed: () => shell.update(
                    () => answerFontSize = (answerFontSize + 1).clamp(12, 24),
                  ),
                  child: const Text('A+'),
                ),
            ],
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: question,
            builder: (_, value, __) => TextField(
              key: ValueKey('chat-input:$scope'),
              controller: question,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              style: DesktopVisuals.field,
              onSubmitted: (_) {
                if (!shell.busy &&
                    !meetingFeature.meetingEnhancing &&
                    question.text.trim().isNotEmpty)
                  unawaited(askQuestion(meetingScope: meetingScope));
              },
              decoration: InputDecoration(
                hintText: compact
                    ? 'Ask Foresight AI...'
                    : 'Ask Foresight about your meetings',
                hintStyle: const TextStyle(color: Color(0xffaaaaaa)),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                  borderSide: const BorderSide(color: Color(0xffeeeeee)),
                ),
                suffixIcon: Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton.filled(
                    tooltip: scopeAsking ? 'Cancel answer' : 'Ask',
                    onPressed: scopeAsking
                        ? () => d.generator?.cancel()
                        : shell.busy ||
                              meetingFeature.meetingEnhancing ||
                              value.text.trim().isEmpty
                        ? null
                        : () => askQuestion(meetingScope: meetingScope),
                    style: IconButton.styleFrom(
                      backgroundColor: _blue,
                      disabledBackgroundColor: _blue,
                      foregroundColor: _ink,
                      disabledForegroundColor: _ink.withValues(alpha: .5),
                      minimumSize: const Size(40, 40),
                      maximumSize: const Size(40, 40),
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    icon: Icon(scopeAsking ? Icons.stop : Icons.arrow_upward),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatView extends StatelessWidget {
  final _ChatController controller;
  const _ChatView(this.controller);
  @override
  Widget build(BuildContext context) => controller.chat();
}
