import 'package:flutter/material.dart';

/// Share the verified model installer between Settings and first-run setup.
class ModelSetupSurface extends StatelessWidget {
  final bool embedded;
  final Widget title, content;
  final List<Widget> actions;
  const ModelSetupSurface({
    super.key,
    required this.embedded,
    required this.title,
    required this.content,
    required this.actions,
  });
  @override
  Widget build(BuildContext context) => embedded
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w500),
              child: title,
            ),
            const SizedBox(height: 24),
            content,
            const SizedBox(height: 24),
            Wrap(spacing: 12, runSpacing: 12, children: actions),
          ],
        )
      : AlertDialog(title: title, content: content, actions: actions);
}
