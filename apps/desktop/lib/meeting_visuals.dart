import 'package:flutter/material.dart';

/// Meetings roles inferred from the original macOS app at 2x display density.
/// Keep content and controls separate; assistant answers retain their own
/// user-adjustable font size and all roles honor the host text scale.
abstract final class MeetingVisuals {
  static const title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const listTitle = TextStyle(fontSize: 16, height: 1.3);
  static const dateHeading = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const sectionTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const control = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const metadata = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: Color(0xff555b62),
  );
  static const notes = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.6,
  );
  static const previewRadius = BorderRadius.all(Radius.circular(16));
  static const panelRadius = BorderRadius.all(Radius.circular(24));
  static const enhancedSurface = Color(0xffeaf0f8);
}

/// Limits meeting control defaults to this workspace, including immersive view.
class MeetingStyleScope extends StatelessWidget {
  const MeetingStyleScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.copyWith(
          labelLarge: theme.textTheme.labelLarge?.merge(MeetingVisuals.control),
          titleMedium: theme.textTheme.titleMedium?.merge(
            MeetingVisuals.sectionTitle,
          ),
        ),
        iconTheme: theme.iconTheme.copyWith(size: 20),
      ),
      child: child,
    );
  }
}

/// The expanded meeting's date and time use the same outlined metadata badge.
class MeetingMetadataBadge extends StatelessWidget {
  const MeetingMetadataBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffd5dce5)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: MeetingVisuals.metadata),
  );
}

/// Keeps assistant actions at the right edge and the active panel in the tab
/// strip. Transcript gets a direct tab whenever space permits.
class MeetingAssistantHeader extends StatelessWidget {
  const MeetingAssistantHeader({
    super.key,
    required this.selectedPanel,
    required this.onPanelSelected,
    required this.onFontSizeChanged,
    required this.onClose,
  });

  final String selectedPanel;
  final ValueChanged<String> onPanelSelected;
  final ValueChanged<int> onFontSizeChanged;
  final VoidCallback onClose;

  static const panels = [
    'Chat',
    'Live Q&A',
    'Summary',
    'Transcript',
    'Action items',
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final style = Theme.of(
          context,
        ).textTheme.labelLarge!.merge(MeetingVisuals.control);
        final widths = <String, double>{};
        for (final panel in panels) {
          final painter = TextPainter(
            text: TextSpan(text: panel, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          widths[panel] = (painter.width + 20).ceilToDouble().clamp(
            64.0,
            double.infinity,
          );
          painter.dispose();
        }

        // Reserve the font controls, close button and overflow menu before
        // choosing tabs, so resizing cannot push actions onto another line.
        final tabWidth = constraints.maxWidth - 80;
        final allFit = widths.values.fold(0.0, (a, b) => a + b) <= tabWidth;
        var remaining = tabWidth - (allFit ? 0 : 32);
        final visible = <String>{};
        for (final panel in {selectedPanel, 'Transcript', ...panels}) {
          if (visible.isEmpty || widths[panel]! <= remaining) {
            visible.add(panel);
            remaining -= widths[panel]!;
          }
        }
        final overflow = panels.where((panel) => !visible.contains(panel));
        return Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  for (final panel in panels.where(visible.contains))
                    SizedBox(
                      width: widths[panel]!.clamp(
                        0,
                        tabWidth - (overflow.isEmpty ? 0 : 32),
                      ),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          minimumSize: const Size(64, 48),
                          textStyle: style,
                          backgroundColor: selectedPanel == panel
                              ? const Color(0xffbfe8ff)
                              : null,
                          foregroundColor: selectedPanel == panel
                              ? const Color(0xff07577b)
                              : const Color(0xff4d5358),
                        ),
                        onPressed: () => onPanelSelected(panel),
                        child: Semantics(
                          selected: selectedPanel == panel,
                          child: Text(
                            panel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  if (overflow.isNotEmpty)
                    SizedBox(
                      width: 32,
                      child: PopupMenuButton<String>(
                        tooltip: 'More meeting panels',
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                        onSelected: onPanelSelected,
                        itemBuilder: (_) => [
                          for (final panel in overflow)
                            PopupMenuItem(value: panel, child: Text(panel)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            for (final delta in [-1, 1])
              SizedBox(
                width: 24,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(24, 32),
                  ),
                  onPressed: () => onFontSizeChanged(delta),
                  child: Text(
                    delta < 0 ? 'A−' : 'A+',
                    style: MeetingVisuals.metadata,
                  ),
                ),
              ),
            SizedBox(
              width: 32,
              child: IconButton(
                tooltip: 'Close assistant',
                padding: EdgeInsets.zero,
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Keeps the heading readable when a narrow pane or larger text needs another
/// row for actions. Buttons retain their normal focus and pointer targets.
class MeetingPanelHeading extends StatelessWidget {
  const MeetingPanelHeading({
    super.key,
    required this.title,
    required this.actions,
  });
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final label = Row(
        children: [
          const Icon(Icons.auto_awesome, size: 19, color: Color(0xff556272)),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: MeetingVisuals.sectionTitle)),
        ],
      );
      if (constraints.maxWidth < MediaQuery.textScalerOf(context).scale(320)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            label,
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: label),
          ...actions,
        ],
      );
    },
  );
}
