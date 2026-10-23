import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsProperties;
import 'package:intl/intl.dart' show NumberFormat;
import 'package:foresight_core/desktop.dart';

class SettingsUsageChart extends CustomPainter {
  final List<int> values;
  final List<OutputStatsWeek> weeks;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;
  SettingsUsageChart(
    this.values, {
    required this.weeks,
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
    if (index >= weeks.length) return 'Week ${index + 1}';
    final week = weeks[index];
    return 'Week of ${week.month}/${week.day}';
  }

  @override
  bool shouldRepaint(SettingsUsageChart oldDelegate) => true;
}
