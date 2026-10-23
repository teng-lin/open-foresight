import 'dart:async';
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import '../../desktop_visuals.dart';
import '../../generated_content.dart';
import '../../presentation/workspace_presentation.dart';
import 'chat_controller.dart';
import 'read_model.dart';

class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.controller,
    this.meetingScope,
    this.compact = false,
  });
  final ChatController controller;
  final int? meetingScope;
  final bool compact;
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  @override
  void initState() {
    super.initState();
    widget.controller.attach(widget.meetingScope);
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.meetingScope != widget.meetingScope) {
      oldWidget.controller.detach(oldWidget.meetingScope);
      widget.controller.attach(widget.meetingScope);
    }
  }

  @override
  void dispose() {
    widget.controller.detach(widget.meetingScope);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (_, _) => widget.controller.buildConversation(
      meetingScope: widget.meetingScope,
      compact: widget.compact,
    ),
  );
}

class ChatHistory extends StatelessWidget {
  const ChatHistory({
    super.key,
    required this.history,
    required this.loading,
    required this.scope,
    required this.scopeAsking,
    required this.searchWeb,
    required this.answer,
    required this.answerFontSize,
    required this.openLink,
    required this.onClose,
    required this.cite,
  });
  final List<ChatAnswer> history;
  final bool loading, scopeAsking, searchWeb;
  final String scope, answer;
  final double answerFontSize;
  final Future<void> Function(Uri) openLink;
  final ValueChanged<int> onClose;
  final ValueChanged<Citation> cite;
  @override
  Widget build(BuildContext context) => Expanded(
    child: loading
        ? const Center(child: CircularProgressIndicator())
        : history.isEmpty && !scopeAsking
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
                              a.question,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close answer',
                            onPressed: () => onClose(a.id),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      GeneratedContent(
                        a.body,
                        openLink: openLink,
                        fontSize: answerFontSize,
                      ),
                      if (a.status != 'completed') Text('Status: ${a.status}'),
                      Wrap(
                        children: a.citations
                            .map(
                              (c) => TextButton(
                                onPressed: () => cite(c),
                                child: Text(
                                  c.kind == 'web'
                                      ? '[${c.label}] ${c.title == '' ? c.url : c.title}'
                                      : '[${c.label}] source revision ${c.revision}',
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
                  openLink: openLink,
                ),
            ],
          ),
  );
}

class ChatControls extends StatelessWidget {
  const ChatControls({
    super.key,
    required this.history,
    required this.compact,
    required this.asking,
    required this.searchWeb,
    required this.webSearchAvailable,
    required this.onToggleWeb,
    required this.onSmaller,
    required this.onLarger,
  });
  final List<ChatAnswer> history;
  final bool compact, asking, searchWeb, webSearchAvailable;
  final VoidCallback onToggleWeb, onSmaller, onLarger;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        key: const ValueKey('chat-web-search'),
        tooltip: webSearchAvailable
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
        onPressed: asking || (!webSearchAvailable && !searchWeb)
            ? null
            : onToggleWeb,
        icon: const Icon(Icons.travel_explore, size: 18),
        selectedIcon: const Icon(
          Icons.travel_explore,
          size: 18,
          color: workspaceInk,
        ),
      ),
      const Spacer(),
      if (history.isNotEmpty && !compact)
        TextButton(onPressed: onSmaller, child: const Text('A−')),
      if (history.isNotEmpty && !compact)
        TextButton(onPressed: onLarger, child: const Text('A+')),
    ],
  );
}

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.question,
    required this.scope,
    required this.compact,
    required this.scopeAsking,
    required this.busy,
    required this.enhancing,
    required this.onAsk,
    required this.onCancel,
  });
  final TextEditingController question;
  final String scope;
  final bool compact, scopeAsking, busy, enhancing;
  final Future<void> Function() onAsk;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) =>
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
            if (!busy && !enhancing && question.text.trim().isNotEmpty)
              unawaited(onAsk());
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(40)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(40),
              borderSide: const BorderSide(color: Color(0xffeeeeee)),
            ),
            suffixIcon: Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton.filled(
                tooltip: scopeAsking ? 'Cancel answer' : 'Ask',
                onPressed: scopeAsking
                    ? onCancel
                    : busy || enhancing || value.text.trim().isEmpty
                    ? null
                    : onAsk,
                style: IconButton.styleFrom(
                  backgroundColor: workspaceBlue,
                  disabledBackgroundColor: workspaceBlue,
                  foregroundColor: workspaceInk,
                  disabledForegroundColor: workspaceInk.withValues(alpha: .5),
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
      );
}
