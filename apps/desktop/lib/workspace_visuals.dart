part of 'application.dart';

const _blue = workspaceBlue;
const _ink = workspaceInk;

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
