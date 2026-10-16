import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:foresight_core/foresight_core.dart' show openPlatformUri;

/// A formatted, selectable view of generated Markdown. Persisted content and
/// copy/edit actions continue to use the original Markdown source.
class GeneratedContent extends StatelessWidget {
  const GeneratedContent(
    this.markdown, {
    super.key,
    this.fontSize = 15,
    this.openLink = openPlatformUri,
  });

  final String markdown;
  final double fontSize;
  final Future<void> Function(Uri) openLink;

  @override
  Widget build(BuildContext context) {
    final text = TextStyle(fontSize: fontSize, height: 1.6);
    return SelectionArea(
      child: MarkdownBody(
        data: markdown,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: text,
          listBullet: text,
          tableBody: text,
          tableColumnWidth: const FlexColumnWidth(),
          code: TextStyle(fontSize: fontSize, fontFamily: 'monospace'),
        ),
        // Generated URLs must never fetch images merely by displaying a result.
        imageBuilder: (_, _, alt) =>
            Text(alt?.isNotEmpty == true ? alt! : 'Image'),
        onTapLink: (_, href, _) async {
          final uri = href == null ? null : Uri.tryParse(href);
          if (uri == null ||
              !uri.hasAuthority ||
              !['https', 'http'].contains(uri.scheme))
            return;
          try {
            await openLink(uri);
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text('Could not open link: $error')),
              );
            }
          }
        },
      ),
    );
  }
}
