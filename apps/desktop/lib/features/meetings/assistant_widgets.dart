import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart' show Citation, MeetingQuestion;
import '../../generated_content.dart';
import 'meeting_visuals.dart';

class MeetingAssistant extends StatelessWidget {
  MeetingAssistant({
    super.key,
    required this.selectedPanel,
    required List<Widget> panels,
    this.answerScope,
    required this.onPanelSelected,
    required this.onFontSizeChanged,
    required this.onClose,
  }) : panels = List.unmodifiable(panels);
  final String selectedPanel;
  final List<Widget> panels;
  final Widget? answerScope;
  final ValueChanged<String> onPanelSelected;
  final ValueChanged<int> onFontSizeChanged;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: MeetingVisuals.panelRadius,
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        MeetingAssistantHeader(
          selectedPanel: selectedPanel,
          onPanelSelected: onPanelSelected,
          onFontSizeChanged: onFontSizeChanged,
          onClose: onClose,
        ),
        if (answerScope != null) answerScope!,
        Expanded(
          child: IndexedStack(
            index: MeetingAssistantHeader.panels.indexOf(selectedPanel),
            children: panels,
          ),
        ),
      ],
    ),
  );
}

class MeetingQuestionsPanel extends StatelessWidget {
  MeetingQuestionsPanel({
    super.key,
    required this.automatic,
    required this.detectorConfigured,
    required this.queuedAnswers,
    required this.oldestQueueAgeMs,
    required this.waiting,
    this.detectionError,
    required List<Widget> questions,
    required List<String> manual,
    required this.canAnswer,
    required this.onAutomaticChanged,
    required this.onRetryDetection,
    required this.onQuestion,
  }) : questions = List.unmodifiable(questions),
       manual = List.unmodifiable(manual);
  final bool automatic, detectorConfigured, waiting, canAnswer;
  final int queuedAnswers, oldestQueueAgeMs;
  final String? detectionError;
  final List<Widget> questions;
  final List<String> manual;
  final ValueChanged<bool> onAutomaticChanged;
  final VoidCallback onRetryDetection;
  final ValueChanged<String> onQuestion;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (!detectorConfigured)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Set up a dedicated question detector in Settings → Local models. Automatic answers retain queued work while setup is unavailable.',
          ),
        ),
      if (queuedAnswers > 0)
        Text(
          '$queuedAnswers queued · oldest waiting ${(oldestQueueAgeMs / 1000).floor()}s',
        ),
      SwitchListTile(
        dense: true,
        title: const Text('Automatic answers'),
        subtitle: const Text(
          'Detect questions and answer with your local model.',
        ),
        value: automatic,
        onChanged: onAutomaticChanged,
      ),
      if (waiting)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            automatic
                ? 'Waiting for the local model or processing transcript…'
                : 'Automatic answering is off. Queued questions are saved.',
          ),
        ),
      if (detectionError != null)
        ListTile(
          title: Text(detectionError!),
          trailing: TextButton(
            onPressed: onRetryDetection,
            child: const Text('Retry detection'),
          ),
        ),
      Expanded(
        child: questions.isEmpty && manual.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Questions detected during the conversation will be answered here.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ...questions,
                  for (final row in manual)
                    ListTile(
                      title: SelectableText(row),
                      trailing: IconButton(
                        tooltip: 'Answer this question',
                        onPressed: canAnswer ? () => onQuestion(row) : null,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    ),
                ],
              ),
      ),
    ],
  );
}

class MeetingAutomaticQuestion extends StatelessWidget {
  const MeetingAutomaticQuestion({
    super.key,
    required this.item,
    required this.fontSize,
    required this.openLink,
    required this.onCopy,
    required this.onCite,
    required this.onRetry,
  });
  final MeetingQuestion item;
  final double fontSize;
  final Future<void> Function(Uri) openLink;
  final ValueChanged<String> onCopy;
  final ValueChanged<Citation> onCite;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.question,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(switch (item.state) {
            'queued' => 'Automatic · Waiting',
            'answering' => 'Automatic · Answering…',
            'completed' => 'Automatic · Answered',
            'insufficient_context' => 'Automatic · No supporting sources found',
            'failed' => 'Automatic · Could not answer',
            'cancelled' => 'Automatic · Cancelled',
            'superseded' => 'Automatic · Replaced by an updated question',
            _ => 'Automatic · Saved question',
          }),
          if ((item.error).isNotEmpty) Text(item.error),
          if (item.body != null)
            GeneratedContent(
              item.body!,
              openLink: openLink,
              fontSize: fontSize,
            ),
          if (item.body != null)
            IconButton(
              tooltip: 'Copy automatic answer',
              onPressed: () => onCopy(item.body!),
              icon: const Icon(Icons.copy_outlined),
            ),
          if (item.citations.isNotEmpty)
            Wrap(
              children: [
                for (final source in item.citations)
                  TextButton(
                    onPressed: () => onCite(source),
                    child: Text(
                      '[${source.label}] source revision ${source.revision}',
                    ),
                  ),
              ],
            ),
          if ([
            'failed',
            'insufficient_context',
            'cancelled',
          ].contains(item.state))
            TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
