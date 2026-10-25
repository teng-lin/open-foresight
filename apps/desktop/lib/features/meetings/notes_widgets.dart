import '../../generated_content.dart';
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

class MeetingEnhancedBody extends StatelessWidget {
  const MeetingEnhancedBody({
    super.key,
    required this.enhancedText,
    required this.preview,
    required this.hasProgress,
    required this.status,
    required this.openLink,
  });
  final String enhancedText, status;
  final bool preview, hasProgress;
  final Future<void> Function(Uri) openLink;
  @override
  Widget build(BuildContext context) => enhancedText.isEmpty && !hasProgress
      ? Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!preview) ...[
                  const Icon(
                    Icons.auto_awesome,
                    color: Color(0xffb8bec8),
                    size: 32,
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  status.isEmpty
                      ? 'Live enhanced notes will appear here as shorthand notes are written.'
                      : status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xff959ba5),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        )
      : SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: GeneratedContent(enhancedText, openLink: openLink),
        );
}

class MeetingNotesToolbar extends StatelessWidget {
  const MeetingNotesToolbar({
    super.key,
    required this.preview,
    required this.live,
    required this.enhancing,
    required this.enhancedVisible,
    required this.noteStyle,
    required this.onFormat,
    required this.onStyle,
    required this.onEnhance,
    required this.onToggleLive,
    required this.onShowEnhanced,
    this.assistantToggle,
  });
  final bool preview, live, enhancing, enhancedVisible;
  final String noteStyle;
  final void Function(String, String) onFormat;
  final ValueChanged<String> onStyle;
  final VoidCallback? onEnhance;
  final VoidCallback onToggleLive, onShowEnhanced;
  final Widget? assistantToggle;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [_formatting(), _actions()],
    ),
  );
  Widget _formatting() => preview
      ? PopupMenuButton<String>(
          tooltip: 'Format notes',
          icon: const Icon(Icons.text_format),
          onSelected: (format) {
            switch (format) {
              case 'Bold':
                onFormat('**', '**');
              case 'Italic':
                onFormat('*', '*');
              case 'Bullet list':
                onFormat('\n- ', '');
              case 'Numbered list':
                onFormat('\n1. ', '');
              case 'Heading':
                onFormat('\n# ', '');
            }
          },
          itemBuilder: (_) => [
            for (final format in [
              'Bold',
              'Italic',
              'Bullet list',
              'Numbered list',
              'Heading',
            ])
              PopupMenuItem(value: format, child: Text(format)),
          ],
        )
      : IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              fixedSize: const Size(40, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Bold',
                onPressed: () => onFormat('**', '**'),
                icon: const Icon(Icons.format_bold),
              ),
              IconButton(
                tooltip: 'Italic',
                onPressed: () => onFormat('*', '*'),
                icon: const Icon(Icons.format_italic),
              ),
              IconButton(
                tooltip: 'Bullet list',
                onPressed: () => onFormat('\n- ', ''),
                icon: const Icon(Icons.format_list_bulleted),
              ),
              IconButton(
                tooltip: 'Numbered list',
                onPressed: () => onFormat('\n1. ', ''),
                icon: const Icon(Icons.format_list_numbered),
              ),
              IconButton(
                tooltip: 'Heading',
                onPressed: () => onFormat('\n# ', ''),
                icon: const Icon(Icons.title),
              ),
            ],
          ),
        );

  Widget _actions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DropdownButton<String>(
        value: noteStyle,
        underline: const SizedBox.shrink(),
        items: [
          'Standard',
          'Concise',
        ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: (style) => onStyle(style!),
      ),
      const SizedBox(width: 18),
      if (preview)
        FilledButton.tonalIcon(
          onPressed: onEnhance,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(enhancing ? 'Enhancing…' : 'Enhance'),
        )
      else
        FilledButton.tonalIcon(
          key: const ValueKey('meeting-live-enhance'),
          onPressed: onToggleLive,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffdce9ff),
            foregroundColor: const Color(0xff254ab5),
          ),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text('Live Enhance ${live ? 'ON' : 'OFF'}'),
        ),
      if (assistantToggle != null) ...[
        const SizedBox(width: 8),
        assistantToggle!,
      ],
      if (!enhancedVisible)
        IconButton(
          tooltip: 'Show enhanced notes',
          onPressed: onShowEnhanced,
          icon: const Icon(Icons.vertical_split),
        ),
    ],
  );
}

/// The owner selects this state while its note snapshot is loading.
class MeetingNotesLoading extends StatelessWidget {
  const MeetingNotesLoading({super.key});
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Loading meeting notes…'));
}
