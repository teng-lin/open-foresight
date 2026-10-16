import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/graph_rendering.dart';

Future<List<int>> render(GraphNodePainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(200, 200));
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 200);
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final pixels = bytes!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return pixels;
}

List<int> pixel(List<int> pixels, int x, int y) =>
    pixels.sublist((y * 200 + x) * 4, (y * 200 + x) * 4 + 4);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'single label uses its color and dimmed fade replaces original alpha',
    () async {
      final normal = await render(
        const GraphNodePainter(
          depth: 0,
          zoom: 1,
          labelColors: [Color(0x20ff0000)],
        ),
      );
      final dimmed = await render(
        const GraphNodePainter(
          depth: 0,
          zoom: 1,
          dimmed: true,
          labelColors: [Color(0x20ff0000)],
        ),
      );
      expect(pixel(normal, 92, 100), [255, 0, 0, 178]);
      expect(pixel(dimmed, 92, 100), [255, 0, 0, 63]);
    },
  );
  test(
    'two label sectors preserve order and cover both semicircles without gaps',
    () async {
      final pixels = await render(
        const GraphNodePainter(
          depth: 0,
          zoom: 1,
          labelColors: [Colors.red, Colors.blue],
        ),
      );
      final bottom = pixel(pixels, 92, 108), top = pixel(pixels, 92, 92);
      for (var channel = 0; channel < 3; channel++) {
        // Raster alpha conversion can move a color component by one byte.
        expect(bottom[channel], closeTo([244, 67, 54][channel], 1));
        expect(top[channel], closeTo([33, 150, 243][channel], 1));
      }
      expect(bottom.last, 182);
      expect(top.last, 182);
    },
  );
  test(
    'selected caption paints beyond the node while normal nodes have no caption',
    () async {
      final normal = await render(
        const GraphNodePainter(depth: 0, zoom: 1, title: 'Apollo'),
      );
      final selected = await render(
        const GraphNodePainter(
          depth: 0,
          zoom: 1,
          selected: true,
          title: 'Apollo',
        ),
      );
      var backing = 0, text = 0;
      for (var y = 138; y < 158; y++) {
        for (var x = 65; x < 135; x++) {
          expect(pixel(normal, x, y).last, 0);
          final p = pixel(selected, x, y);
          if (p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] > 0) backing++;
          if (p[0] > 240 && p[1] > 240 && p[2] > 240 && p[3] > 240) text++;
        }
      }
      expect(backing, greaterThan(20));
      expect(text, greaterThan(5));
    },
  );
}
