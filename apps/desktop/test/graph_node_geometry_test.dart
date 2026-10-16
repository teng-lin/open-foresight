import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/graph_layout.dart';

void main() {
  test(
    'rendering conversion preserves normalized saved coordinates in Mac world units',
    () {
      final point = graphWorldPoint(const GraphPoint(1, -1, .5));
      expect([point.x, point.y, point.z], [240, -240, 216]);
      final sphere = graphWorldPoint(const GraphPoint(0, 0, 1), uniform: true);
      expect(sphere.z, 240);
    },
  );
  test('fit centers unrotated bounds and clamps the scale', () {
    final points = [
      const GraphPoint(-240, -240, 200),
      const GraphPoint(240, 240, -200),
    ];
    final fit = fitGraphCamera(points, 1200, 900);
    expect(fit.scale, 1.5);
    expect(fit.x + 1500 * fit.scale, 600);
    expect(fit.y + 1500 * fit.scale, 450);
    expect(fitGraphCamera(points, 10000, 10000).scale, 5);
    expect(fitGraphCamera(points, 1, 1).scale, .015);
    final empty = fitGraphCamera([], 1200, 900);
    expect([empty.x, empty.y, empty.scale], [-900, -1050, 1]);
    final line = fitGraphCamera(
      [const GraphPoint(0, 2, 0), const GraphPoint(0, 3, 0)],
      1200,
      900,
    );
    expect([line.x, line.y, line.scale], [-900, -1050, 1]);
  });
  test(
    'depth changes painted geometry and opacity without changing selection precedence',
    () {
      expect(graphNodeRadius(0, 1), closeTo(17.8, 1e-12));
      expect(
        graphNodeRadius(0, 1, selected: true, activeMatch: true),
        closeTo(25.81, 1e-12),
      );
      expect(graphNodeRadius(0, 1, activeMatch: true), closeTo(22.25, 1e-12));
      expect(graphNodeRadius(-400, 1), greaterThan(graphNodeRadius(400, 1)));
      expect(graphNodeFillOpacity(-600), .85);
      expect(graphNodeFillOpacity(600), closeTo(.4675, 1e-12));
      expect(graphNodeFillOpacity(0), closeTo(.65875, 1e-12));
      expect(graphNodeFillOpacity(0, dimmed: true), closeTo(.217, 1e-12));
      expect(graphDepthFade(-900), 1);
      expect(graphDepthFade(900), closeTo(.55, 1e-12));
    },
  );

  test(
    'minimum displayed hit target survives zoom while painter radius changes',
    () {
      for (final zoom in [.25, .5, 1.0, 2.0, 4.0]) {
        expect(graphHitRadius(0, zoom) * zoom, greaterThanOrEqualTo(34));
      }
      expect(graphHitRadius(0, .25), 136);
      expect(graphHitRadius(0, 1), 34);
      expect(graphBaseRadius(.25), 10);
      expect(graphBaseRadius(4), 22);
      expect(graphNodeRadius(0, .25) * .25, 2.5);
      expect(graphNodeRadius(0, 4) * 4, 88);
    },
  );

  test(
    'paint perspective clamps while hit geometry retains raw perspective',
    () {
      expect(graphPaintPerspective(-1599), 6);
      expect(graphPerspective(-1599), 1600);
      expect(
        graphHitRadius(-1599, 1),
        greaterThan(graphNodeRadius(-1599, 1) * 1.5),
      );
      expect(graphPaintPerspective(100000), .05);
      expect(graphPerspective(100000), lessThan(.05));
    },
  );
}
