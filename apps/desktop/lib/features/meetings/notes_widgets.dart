import 'package:flutter/material.dart';
import 'meeting_visuals.dart';

/// Composition of note surfaces supplied by the meeting owner.
class MeetingNotesLayout extends StatelessWidget {
  const MeetingNotesLayout({
    super.key,
    required this.wide,
    required this.preview,
    required this.enhancedVisible,
    required this.toolbar,
    required this.editor,
    required this.enhancedPane,
  });
  final bool wide, preview, enhancedVisible;
  final Widget toolbar, editor, enhancedPane;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: MeetingVisuals.panelRadius,
      ),
      child: Column(
        children: [
          toolbar,
          const Divider(height: 1),
          Expanded(
            child: !enhancedVisible
                ? editor
                : preview
                ? Column(
                    children: [
                      Expanded(flex: 3, child: editor),
                      Expanded(flex: 2, child: enhancedPane),
                    ],
                  )
                : wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 11, child: editor),
                      const SizedBox(width: 24),
                      Expanded(flex: 9, child: enhancedPane),
                    ],
                  )
                : DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        const TabBar(
                          tabs: [
                            Tab(text: 'Notes'),
                            Tab(text: 'Enhanced'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(children: [editor, enhancedPane]),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The owner retains its controller and draft-save lifecycle.
class MeetingNotesInput extends StatelessWidget {
  const MeetingNotesInput({
    super.key,
    required this.controller,
    required this.onChanged,
  });
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final editorField = TextField(
      key: const ValueKey('meeting-notes-editor'),
      controller: controller,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: MeetingVisuals.notes,
      onChanged: (_) => onChanged(),
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.all(24),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(label: 'Meeting notes', child: editorField),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, value, _) => value.text.isNotEmpty
              ? const SizedBox.shrink()
              : IgnorePointer(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Enter your notes here. Markdown formatting is supported.\n\nMarkdown guide:\n• # Heading\n• **bold**\n• *italics*\n• - Bullet list\n• 1. Numbered list',
                      style: MeetingVisuals.notes.copyWith(
                        color: const Color(0xff9ba3b3),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
