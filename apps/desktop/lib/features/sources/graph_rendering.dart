import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

// The reference removes all '#' characters, prefixes six-digit RGB with FF,
// and falls back only for absent/empty values or integer parsing failure.
Color graphLabelColor(String? value, Color fallback) {
  if (value == null || value.isEmpty) return fallback;
  var hex = value.replaceAll('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  try {
    return Color(int.parse(hex, radix: 16) & 0xffffffff);
  } on FormatException {
    return fallback;
  }
}

// Colors arrive in stored label order; missing colorHex uses the caller's theme
// fallback. The native reference's omitted typography defaults remain unknown.
class GraphNodePainter extends CustomPainter {
  final double depth, zoom;
  final bool selected, activeMatch, dimmed;
  final List<Color> labelColors;
  final Color matchColor;
  final String title;
  final String? fontFamily;
  final TextDirection textDirection;
  const GraphNodePainter({
    required this.depth,
    required this.zoom,
    this.selected = false,
    this.activeMatch = false,
    this.dimmed = false,
    this.labelColors = const [],
    this.matchColor = Colors.white,
    this.title = '',
    this.fontFamily,
    this.textDirection = TextDirection.ltr,
  });

  double get radius => graphNodeRadius(
    depth,
    zoom,
    selected: selected,
    activeMatch: activeMatch,
  );
  double get extent =>
      radius +
      ((selected || activeMatch) ? 8 : .7) * graphPaintPerspective(depth);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final p = graphPaintPerspective(depth), fade = graphDepthFade(depth);
    final paint = Paint();
    if (labelColors.length > 1) {
      final angle = 2 * math.pi / labelColors.length;
      final bounds = Rect.fromCircle(center: center, radius: radius);
      for (var i = 0; i < labelColors.length; i++) {
        paint.color = labelColors[i].withGraphOpacity(
          (dimmed ? .35 : .92) * fade,
        );
        canvas.drawArc(bounds, i * angle, angle, true, paint);
      }
    } else {
      paint.color = labelColors.isEmpty
          ? const Color(
              0xff455a64,
            ).withGraphOpacity(graphNodeFillOpacity(depth, dimmed: dimmed))
          : labelColors.first.withGraphOpacity((dimmed ? .32 : .9) * fade);
      canvas.drawCircle(center, radius, paint);
    }
    if (!dimmed) {
      paint.color = Colors.white.withGraphOpacity(
        (labelColors.length > 1 ? .4 : .55) * fade,
      );
      canvas.drawCircle(
        center + Offset(.3 * radius, -.3 * radius),
        .25 * radius,
        paint,
      );
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 * p
      ..color = labelColors.length == 1
          ? labelColors.first.withGraphOpacity((dimmed ? .45 : .95) * fade)
          : Colors.white.withGraphOpacity(
              graphNodeOutlineOpacity(depth, dimmed: dimmed),
            );
    canvas.drawCircle(center, radius, paint);
    if (selected || activeMatch) {
      final color = selected ? const Color(0xffffd54f) : matchColor;
      paint
        ..color = color
        ..strokeWidth = (selected ? 3.8 : 3.2) * p;
      canvas.drawCircle(center, radius + 3.5 * p, paint);
      paint
        ..color = color.withGraphOpacity(.35 * fade)
        ..strokeWidth = 2 * p;
      canvas.drawCircle(center, radius + 7 * p, paint);
    }
    if (selected && title.isNotEmpty) {
      final u = (1 / zoom).clamp(.35, 6) * p;
      final text = TextPainter(
        text: TextSpan(
          text: '  $title  ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13 * u,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: textDirection,
      )..layout();
      final box = Rect.fromCenter(
        center: center + Offset(0, radius + 4 * u + text.height / 2),
        width: text.width + 8 * u,
        height: text.height + 4 * u,
      );
      paint
        ..style = PaintingStyle.fill
        ..color = Colors.black.withGraphOpacity(fade);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(10 * u)),
        paint,
      );
      text.paint(canvas, Offset(box.left + 4 * u, center.dy + radius + 4 * u));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(GraphNodePainter old) =>
      depth != old.depth ||
      zoom != old.zoom ||
      selected != old.selected ||
      activeMatch != old.activeMatch ||
      dimmed != old.dimmed ||
      !listEquals(labelColors, old.labelColors) ||
      matchColor != old.matchColor ||
      title != old.title ||
      fontFamily != old.fontFamily ||
      textDirection != old.textDirection;
}

// Mac Color.withOpacity replaces alpha using round(opacity * 255).
extension _MacGraphOpacity on Color {
  Color withGraphOpacity(double opacity) => withAlpha((opacity * 255).round());
}
