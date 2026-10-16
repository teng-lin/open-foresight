import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'graph_clusters.dart';
import 'graph_labels.dart';
import 'graph_layout.dart';
import 'graph_rendering.dart';

GraphPoint clusterMemberCenter(
  GraphCluster cluster,
  Map<String, GraphPoint> points,
  Map<String, List<DocumentLabel>> labels,
) {
  var x = 0.0, y = 0.0, z = 0.0, count = 0;
  for (final entry in points.entries) {
    if (!(labels[entry.key] ?? const []).any(
      (label) => label.name == cluster.label,
    ))
      continue;
    x += entry.value.x;
    y += entry.value.y;
    z += entry.value.z;
    count++;
  }
  return count == 0
      ? cluster.center
      : GraphPoint(x / count, y / count, z / count);
}

Color clusterLabelColor(
  String name,
  Map<String, List<DocumentLabel>> labels,
  Color fallback,
) {
  var color = fallback;
  for (final list in labels.values) {
    for (final label in list) {
      if (label.name == name && label.colorHex != null) {
        color = graphLabelColor(label.colorHex, fallback);
        break;
      }
    }
    if (color != fallback) break;
  }
  return color;
}

class GraphClusterPainter extends CustomPainter {
  final List<GraphCluster> clusters;
  final Map<String, GraphPoint> points;
  final Map<String, List<DocumentLabel>> labels;
  final double yaw, pitch, zoom;
  final String filter;
  final Color fallback;
  final String? fontFamily;
  const GraphClusterPainter({
    required this.clusters,
    required this.points,
    required this.labels,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    this.filter = '',
    required this.fallback,
    this.fontFamily,
  });
  Offset project(GraphPoint point) {
    final p = rotateGraphPoint(point, yaw: yaw, pitch: pitch);
    final k = graphPaintPerspective(p.z);
    return Offset(graphSceneOrigin + p.x * k, graphSceneOrigin + p.y * k);
  }

  Color opacity(Color c, double value) => c.withAlpha((value * 255).round());

  // Bounds in the same fixed canvas coordinates used by paint. Fit includes
  // the largest caption state so selecting a filter does not clip its title.
  Iterable<Rect> paintedBounds() sync* {
    if (points.isEmpty) return;
    for (final cluster in clusters) {
      final mean = clusterMemberCenter(cluster, points, labels);
      final p = graphPaintPerspective(
        rotateGraphPoint(mean, yaw: yaw, pitch: pitch).z,
      );
      final center = project(mean), radius = cluster.radius * p;
      yield Rect.fromCircle(center: center, radius: radius + 1.25);
      final u = (1 / zoom).clamp(.3, 8) * p;
      final text = TextPainter(
        text: TextSpan(
          text: '  ${cluster.label}  ',
          style: TextStyle(
            fontSize: 16 * u,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      yield Rect.fromCenter(
        center: Offset(
          center.dx,
          center.dy - radius - 24 * p - text.height / 2,
        ),
        width: text.width + 14 * u,
        height: text.height + 8 * u,
      );
      text.dispose();
      final r = .9 * cluster.radius;
      for (var ring = 0; ring < 3; ring++) {
        for (var i = 0; i <= 16; i++) {
          final t = 2 * math.pi * i / 16,
              c = r * math.cos(t),
              s = r * math.sin(t);
          final point = project(
            ring == 0
                ? GraphPoint(mean.x + c, mean.y, mean.z + s)
                : ring == 1
                ? GraphPoint(mean.x + c, mean.y + s, mean.z)
                : GraphPoint(mean.x, mean.y + s, mean.z + c),
          );
          yield Rect.fromCircle(center: point, radius: .5);
        }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    for (final cluster in clusters) {
      final mean = clusterMemberCenter(cluster, points, labels);
      final depth = rotateGraphPoint(mean, yaw: yaw, pitch: pitch).z;
      final p = graphPaintPerspective(depth), u = (1 / zoom).clamp(.3, 8) * p;
      final center = project(mean), radius = cluster.radius * p;
      final highlight = filter.isNotEmpty && filter == cluster.label;
      final dim = filter.isNotEmpty && filter != cluster.label;
      final color = clusterLabelColor(cluster.label, labels, fallback);
      final rect = Rect.fromCircle(center: center, radius: radius);
      final paint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.35, -.35),
          radius: .85,
          colors: [
            opacity(
              color,
              highlight
                  ? .35
                  : dim
                  ? .05
                  : .16,
            ),
            opacity(
              color,
              highlight
                  ? .08
                  : dim
                  ? .01
                  : .04,
            ),
          ],
        ).createShader(rect);
      canvas.drawCircle(center, radius, paint);
      paint
        ..shader = null
        ..style = PaintingStyle.stroke
        ..strokeWidth = (highlight ? 2.5 : 1.5)
        ..color = opacity(
          color,
          highlight
              ? .95
              : dim
              ? .15
              : .45,
        );
      canvas.drawCircle(center, radius, paint);
      paint
        ..strokeWidth = 1
        ..color = opacity(color, dim ? .05 : .28);
      final wireRadius = .9 * cluster.radius;
      for (var ring = 0; ring < 3; ring++) {
        final path = Path();
        for (var i = 0; i <= 16; i++) {
          final t = 2 * math.pi * i / 16,
              c = wireRadius * math.cos(t),
              s = wireRadius * math.sin(t);
          final vertex = ring == 0
              ? GraphPoint(mean.x + c, mean.y, mean.z + s)
              : ring == 1
              ? GraphPoint(mean.x + c, mean.y + s, mean.z)
              : GraphPoint(mean.x, mean.y + s, mean.z + c);
          final point = project(vertex);
          if (i == 0)
            path.moveTo(point.dx, point.dy);
          else
            path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }
      final text = TextPainter(
        text: TextSpan(
          text: '  ${cluster.label}  ',
          style: TextStyle(
            color: opacity(Colors.white, dim ? .35 : 1),
            fontSize: (highlight ? 16 : 13.5) * u,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final top = center.dy - radius - 24 * p;
      final box = Rect.fromCenter(
        center: Offset(center.dx, top - text.height / 2),
        width: text.width + 14 * u,
        height: text.height + 8 * u,
      );
      paint
        ..style = PaintingStyle.fill
        ..color = opacity(color, (dim ? .3 : .92) * graphDepthFade(depth));
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(14 * u)),
        paint,
      );
      text.paint(canvas, Offset(box.left + 7 * u, box.top + 4 * u));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(GraphClusterPainter old) => true;
}
