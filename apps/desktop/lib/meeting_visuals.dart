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
