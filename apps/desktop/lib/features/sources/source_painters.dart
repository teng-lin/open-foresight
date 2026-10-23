import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

/// The reference Sources action uses a dashed pill outline.
class DashedStadiumBorder extends StadiumBorder {
  const DashedStadiumBorder({super.side});

  @override
  DashedStadiumBorder copyWith({BorderSide? side}) =>
      DashedStadiumBorder(side: side ?? this.side);

  @override
  DashedStadiumBorder scale(double t) =>
      DashedStadiumBorder(side: side.scale(t));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(side.width / 2),
          Radius.circular(rect.shortestSide / 2),
        ),
      );
    final paint = side.toPaint();
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 8) {
        canvas.drawPath(
          metric.extractPath(offset, math.min(offset + 4, metric.length)),
          paint,
        );
      }
    }
  }
}

class SourceLinks extends CustomPainter {
  final List<SourceSummary> rows;
  final List<Offset> positions;
  final List<GraphEdge> edges;
  final List<double> depths;
  SourceLinks(this.rows, this.positions, this.edges, this.depths);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final visible = {
      for (var i = 0; i < rows.length; i++) rows[i].id: positions[i],
    };
    final depthById = {
      for (var i = 0; i < rows.length; i++) rows[i].id: depths[i],
    };
    for (final edge in edges) {
      final source = visible[edge.source], target = visible[edge.target];
      if (source != null && target != null) {
        final meanDepth =
            (depthById[edge.source]! + depthById[edge.target]!) / 2;
        final perspective = graphPaintPerspective(meanDepth);
        paint
          ..color = const Color(
            0xff455a64,
          ).withValues(alpha: .85 * graphDepthFade(meanDepth))
          ..strokeWidth = 2.4 * perspective;
        final delta = target - source;
        final distance = delta.distance;
        if (distance == 0) continue;
        final direction = delta / distance;
        for (var start = 0.0; start < distance; start += 8 * perspective) {
          canvas.drawLine(
            source + direction * start,
            source + direction * math.min(start + 3 * perspective, distance),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(SourceLinks oldDelegate) => true;
}
