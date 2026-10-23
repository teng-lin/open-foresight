import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/sources/cluster_rendering.dart';
import '../test_support/core_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('envelope center follows current matching members including depth', () {
    const c = GraphCluster('Group', GraphPoint(900, 800, 0), 90);
    final points = {
      'a': const GraphPoint(10, 20, 30),
      'b': const GraphPoint(30, 40, 50),
      'other': const GraphPoint(500, 500, 500),
    };
    final labels = {
      'a': [const DocumentLabel('a', 'Group', 'user_defined', '#0EBC5F')],
      'b': [const DocumentLabel('b', 'Group', 'propagated', '#0EBC5F')],
    };
    final center = clusterMemberCenter(c, points, labels);
    expect([center.x, center.y, center.z], [20, 30, 40]);
    expect(clusterMemberCenter(c, points, {}), c.center);
  });
  test(
    'fallback-colored and malformed records do not hide later valid color',
    () {
      final labels = {
        'a': [const DocumentLabel('a', 'Group', 'user_defined', 'bad!')],
        'b': [const DocumentLabel('b', 'Group', 'user_defined', '#0EBC5F')],
      };
      expect(
        clusterLabelColor('Group', labels, Colors.blue),
        const Color(0xff0ebc5f),
      );
    },
  );
  test('highlight and dimming change rendered envelope opacity', () async {
    Future<int> sample(String filter) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..translate(-1400, -1400);
      GraphClusterPainter(
        clusters: const [GraphCluster('Group', GraphPoint(0, 0, 0), 90)],
        points: const {'a': GraphPoint(0, 0, 0)},
        labels: const {},
        yaw: 0,
        pitch: 0,
        zoom: 1,
        filter: filter,
        fallback: Colors.red,
      ).paint(canvas, const Size(3000, 3000));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 200);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final alpha = bytes!.getUint8((110 * 200 + 110) * 4 + 3);
      image.dispose();
      picture.dispose();
      return alpha;
    }

    final normal = await sample(''),
        highlight = await sample('Group'),
        dim = await sample('Other');
    expect(highlight, greaterThan(normal));
    expect(normal, greaterThan(dim));
  });
}
