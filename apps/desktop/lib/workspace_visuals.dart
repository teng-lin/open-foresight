part of 'main.dart';

const _blue = Color(0xffbfe8ff);
const _ink = Color(0xff07577b);

/// The reference Sources action uses a dashed pill outline.
class _DashedStadiumBorder extends StadiumBorder {
  const _DashedStadiumBorder({super.side});

  @override
  _DashedStadiumBorder copyWith({BorderSide? side}) =>
      _DashedStadiumBorder(side: side ?? this.side);

  @override
  _DashedStadiumBorder scale(double t) =>
      _DashedStadiumBorder(side: side.scale(t));

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

class _SourceLinks extends CustomPainter {
  final List<Map<String, Object?>> rows;
  final List<Offset> positions;
  final List<GraphEdge> edges;
  final List<double> depths;
  _SourceLinks(this.rows, this.positions, this.edges, this.depths);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final visible = {
      for (var i = 0; i < rows.length; i++) rows[i]['id']: positions[i],
    };
    final depthById = {
      for (var i = 0; i < rows.length; i++) rows[i]['id']: depths[i],
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
  bool shouldRepaint(_SourceLinks oldDelegate) => true;
}

class _UsageChart extends CustomPainter {
  final List<int> values;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;
  _UsageChart(
    this.values, {
    required this.textStyle,
    required this.textScaler,
    required this.textDirection,
  });

  TextPainter label(
    String text,
    double fontSize, {
    double maxWidth = double.infinity,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: textStyle.copyWith(
        fontSize: fontSize,
        color: const Color(0xff50565c),
      ),
    ),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = math.max(4, values.reduce(math.max));
    final ticks = [
      for (var i = 0; i <= 4; i++)
        label(
          NumberFormat.compact().format((maxValue * (4 - i) / 4).round()),
          11,
        ),
    ];
    final gutter = math.min(
      size.width * .3,
      math.max(40.0, ticks.map((t) => t.width).reduce(math.max) + 8),
    );
    final columnWidth = (size.width - gutter) / values.length;
    final labels = [
      for (var i = 0; i < values.length; i++) label(_weekLabel(i), 12),
    ];
    for (var i = 0; i < labels.length; i++) {
      if (labels[i].width > columnWidth - 4) {
        labels[i].dispose();
        labels[i] = label(
          _weekLabel(i).replaceFirst('Week of ', ''),
          12,
          maxWidth: math.max(1, columnWidth - 4),
        );
      }
    }
    final plotHeight = math.max(
      0.0,
      size.height - labels.map((t) => t.height).reduce(math.max) - 10,
    );
    final paint = Paint()..color = const Color(0xffdfe3e9);
    for (var i = 0; i < ticks.length; i++) {
      final y = i * plotHeight / 4;
      canvas.drawLine(Offset(gutter, y), Offset(size.width, y), paint);
      ticks[i].paint(canvas, Offset(0, math.max(0, y - ticks[i].height / 2)));
    }
    paint.color = const Color(0xff75c8ff);
    for (var i = 0; i < values.length; i++) {
      final height = values[i] / maxValue * plotHeight;
      final center = gutter + (i + .5) * columnWidth;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            center - columnWidth * .2,
            plotHeight - height,
            columnWidth * .4,
            height,
          ),
          const Radius.circular(4),
        ),
        paint,
      );
      labels[i].paint(
        canvas,
        Offset(center - labels[i].width / 2, plotHeight + 8),
      );
    }
    for (final painter in [...ticks, ...labels]) {
      painter.dispose();
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (var i = 0; i < values.length; i++)
          CustomPainterSemantics(
            rect: Rect.fromLTWH(
              i * size.width / values.length,
              0,
              size.width / values.length,
              size.height,
            ),
            properties: SemanticsProperties(
              label: '${_weekLabel(i)}: ${values[i]} local output words',
              textDirection: textDirection,
            ),
          ),
      ];

  String _weekLabel(int index) {
    final week = outputWeekStart(DateTime.now(), weeksAgo: 4 - index);
    return 'Week of ${week.month}/${week.day}';
  }

  @override
  bool shouldRepaint(_UsageChart oldDelegate) => true;
}

class _CaptureWaveform extends CustomPainter {
  final List<double> volumes;
  _CaptureWaveform(List<double> levels) : volumes = List.of(levels);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _ink
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final level = volumes.isEmpty ? 0.0 : volumes.reduce(math.max);
    final count = math.max(1, (size.width / 10).floor());
    for (var i = 0; i < count; i++) {
      final x = (i + .5) * size.width / count;
      final amplitude = math.max(0.0, (level * 60).clamp(0, 12).toDouble());
      canvas.drawLine(
        Offset(x, size.height / 2 - amplitude),
        Offset(x + 1, size.height / 2 + amplitude),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_CaptureWaveform old) => true;
}
