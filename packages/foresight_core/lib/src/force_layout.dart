import 'dart:math' as math;
import 'dart:isolate';
import 'graph_layout.dart';
import 'graph_clusters.dart';

GraphPoint _add(GraphPoint a, GraphPoint b) =>
    GraphPoint(a.x + b.x, a.y + b.y, a.z + b.z);
GraphPoint _sub(GraphPoint a, GraphPoint b) =>
    GraphPoint(a.x - b.x, a.y - b.y, a.z - b.z);
GraphPoint _mul(GraphPoint p, double k) =>
    GraphPoint(p.x * k, p.y * k, p.z * k);
double _norm(GraphPoint p) => math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
const _zero = GraphPoint(0, 0, 0);

// Explicit seeded Mac route: unsigned 64-bit mix and multiply-with-carry.
class ForceRandom42 {
  static final _mask = (BigInt.one << 64) - BigInt.one;
  static final _low = (BigInt.one << 32) - BigInt.one;
  BigInt state = BigInt.from(42);
  ForceRandom42() {
    state = (~state + (state << 21)) & _mask;
    state ^= state >> 24;
    state = (state * BigInt.from(265)) & _mask;
    state ^= state >> 14;
    state = (state * BigInt.from(21)) & _mask;
    state ^= state >> 28;
    state = (state + (state << 31)) & _mask;
    if (state == BigInt.zero) state = BigInt.from(0x5a17);
    for (var i = 0; i < 4; i++) {
      _next();
    }
  }
  void _next() => state =
      (((state & _low) * BigInt.from(0xffffda61)) + (state >> 32)) & _mask;
  double nextDouble() {
    _next();
    final a = (state & BigInt.from((1 << 26) - 1)).toInt();
    _next();
    final b = (state & BigInt.from((1 << 27) - 1)).toInt();
    return (a * 134217728.0 + b) / 9007199254740992.0;
  }
}

GraphPoint forceLabelTarget(String name) {
  var hash = 5381;
  for (final unit in name.toLowerCase().trim().codeUnits) {
    hash = (hash * 33 + unit) & 0xffffffff;
  }
  final j = hash & 31,
      y = .85 - 1.7 * j / 31,
      r = math.sqrt(1 - y * y),
      t = j * 2.399963229728653;
  return GraphPoint(240 * r * math.cos(t), 240 * y, 240 * r * math.sin(t));
}

double forceLabelRadius(Iterable<double> distances) {
  final values = distances.toSet().toList()..sort();
  if (values.isEmpty) return 90;
  final q = (.4 * values.length).floor();
  var retained = values[q];
  for (var j = q + 1; j <= (.75 * values.length).floor(); j++) {
    final previous = values[j - 1], value = values[j];
    if (previous > 0 && value - previous > 25 && value / previous > 1.12) break;
    retained = value;
  }
  final median = values[(.5 * values.length).floor()];
  final base = median > 0 ? math.min(retained, 1.35 * median) : retained;
  return math.min(160, math.max(90, 1.1 * base + 12));
}

({Map<String, GraphPoint> points, List<GraphCluster> clusters})
forceLabelLayout(
  Map<String, GraphPoint> initial,
  List<GraphEdge> edges,
  Map<String, List<String>> labels,
  List<String> outputNames, {
  int iterations = 45,
}) {
  final points = Map<String, GraphPoint>.from(initial),
      ids = initial.keys.toList();
  final random = ForceRandom42();
  final flat = points.values.every((p) => p.z.abs() < .001);
  for (final id in ids) {
    final p = points[id]!;
    if (p.x == 0 && p.y == 0 && p.z == 0) {
      points[id] = GraphPoint(
        (random.nextDouble() - .5) * 50,
        (random.nextDouble() - .5) * 50,
        (random.nextDouble() - .5) * 50,
      );
    } else if (flat) {
      points[id] = GraphPoint(p.x, p.y, (random.nextDouble() - .5) * 60);
    }
  }
  bool member(String id, String label) =>
      (labels[id] ?? const []).contains(label);
  final unique = <GraphEdge>[], pairs = <String>{};
  for (final edge in edges) {
    final a = edge.source.compareTo(edge.target) <= 0
        ? edge.source
        : edge.target;
    final b = a == edge.source ? edge.target : edge.source;
    if (pairs.add('$a|$b')) unique.add(edge);
  }
  Map<String, GraphPoint> sums() {
    final result = <String, GraphPoint>{};
    for (final id in ids) {
      for (final name in labels[id] ?? const <String>[]) {
        result[name] = _add(result[name] ?? _zero, points[id]!);
      }
    }
    return result;
  }

  final counts = <String, int>{};
  for (final id in ids) {
    for (final name in labels[id] ?? const <String>[]) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  for (var iteration = 0; iteration < iterations; iteration++) {
    final forces = {for (final id in ids) id: _zero};
    void push(String id, GraphPoint force) =>
        forces[id] = _add(forces[id]!, force);
    for (var a = 0; a < ids.length; a++) {
      for (var b = a + 1; b < ids.length; b++) {
        final left = ids[a],
            right = ids[b],
            delta = _sub(points[left]!, points[right]!);
        final distance = math.max(_norm(delta), 25.0);
        final shared = (labels[left] ?? const []).any(
          (name) => member(right, name),
        );
        final force = _mul(
          delta,
          (shared ? 5400 : 18000) / (distance * distance * distance),
        );
        push(left, force);
        push(right, _mul(force, -1));
      }
    }
    for (final edge in unique) {
      if (!points.containsKey(edge.source) ||
          !points.containsKey(edge.target)) {
        continue;
      }
      final delta = _sub(points[edge.target]!, points[edge.source]!),
          distance = _norm(delta);
      final force = _mul(
        delta,
        .04 *
            edge.similarity *
            (distance - 140) /
            (distance == 0 ? 1 : distance),
      );
      push(edge.source, force);
      push(edge.target, _mul(force, -1));
    }
    final centers = sums(), names = centers.keys.toList()..sort();
    for (final name in names) {
      final mean = _mul(centers[name]!, 1 / counts[name]!);
      centers[name] = _add(_mul(mean, .35), _mul(forceLabelTarget(name), .65));
    }
    final radii = {
      for (final name in centers.keys)
        name: forceLabelRadius([
          for (final id in ids)
            if (member(id, name)) _norm(_sub(points[id]!, centers[name]!)),
        ]),
    };
    final t = iteration / (iterations == 0 ? 1 : iterations);
    for (final id in ids) {
      final names = labels[id] ?? const <String>[];
      if (names.length == 1 && centers.containsKey(names.single)) {
        push(id, _mul(_sub(centers[names.single]!, points[id]!), .15 + .5 * t));
      } else if (names.length > 1) {
        var total = _zero, count = 0;
        for (final name in names) {
          if (centers.containsKey(name)) {
            total = _add(total, centers[name]!);
            count++;
          }
        }
        if (count > 0) {
          push(
            id,
            _mul(_sub(_mul(total, 1 / count), points[id]!), .1 + .35 * t),
          );
        }
      }
      for (final name in centers.keys) {
        if (member(id, name)) continue;
        final delta = _sub(points[id]!, centers[name]!),
            distance = _norm(delta);
        if (distance > .001 && distance < radii[name]!) {
          push(id, _mul(delta, .85 * (radii[name]! - distance) / distance));
        }
      }
    }
    final ordered = centers.keys.toList();
    for (var a = 0; a < ordered.length; a++) {
      for (var b = a + 1; b < ordered.length; b++) {
        final left = ordered[a], right = ordered[b];
        var count = 0, both = 0;
        for (final id in ids) {
          if (member(id, left)) {
            count++;
            if (member(id, right)) both++;
          }
        }
        if (count > 0 && both / count >= .45) continue;
        final delta = _sub(centers[left]!, centers[right]!),
            distance = math.max(_norm(delta), 25.0);
        final desired = 120 + 2.05 * (radii[left]! + radii[right]!);
        if (distance >= desired) continue;
        final force = _mul(delta, .65 * (desired - distance) / distance);
        for (final id in ids) {
          final l = member(id, left), r = member(id, right);
          if (l && !r) {
            push(id, force);
          } else if (r && !l) {
            push(id, _mul(force, -1));
          }
        }
      }
    }
    for (final id in ids) {
      final f = forces[id]!;
      points[id] = _add(
        points[id]!,
        GraphPoint(
          .2 * f.x.clamp(-45.0, 45.0),
          .2 * f.y.clamp(-45.0, 45.0),
          .2 * f.z.clamp(-45.0, 45.0),
        ),
      );
    }
    for (var a = 0; a < ids.length; a++) {
      for (var b = a + 1; b < ids.length; b++) {
        final left = ids[a],
            right = ids[b],
            delta = _sub(points[left]!, points[right]!),
            distance = _norm(delta);
        if (distance > .001 && distance < 82) {
          final correction = _mul(delta, .5 * (82 - distance) / distance);
          points[left] = _add(points[left]!, correction);
          points[right] = _sub(points[right]!, correction);
        }
      }
    }
  }
  final finalSums = sums();
  final clusters = <GraphCluster>[];
  for (final name in outputNames) {
    final count = counts[name] ?? 0,
        mean = count > 0 ? _mul(finalSums[name]!, 1 / count) : _zero;
    var radius = 90.0;
    if (count > 1) {
      radius =
          ([
            for (final id in ids)
              if (member(id, name)) _norm(_sub(points[id]!, mean)),
          ].reduce(math.max)) +
          50;
    }
    clusters.add(GraphCluster(name, mean, radius));
  }
  return (points: points, clusters: clusters);
}

Future<
  ({
    Map<String, GraphPoint> points,
    List<GraphEdge> edges,
    List<GraphCluster> clusters,
  })
>
organizeForceGraphSceneInBackground(
  Map<String, List<double>> vectors,
  Map<String, List<String>> labels,
  List<String> names,
  Map<String, GraphPoint> existing, {
  List<String>? documents,
}) => Isolate.run(() {
  final ids = documents ?? vectors.keys.toList();
  final initial = initialGraphLayout(ids, vectors),
      edges = semanticGraphEdges(vectors);
  final world = <String, GraphPoint>{};
  for (final id in ids) {
    final old = existing[id];
    world[id] = old != null && (old.x != 0 || old.y != 0 || old.z != 0)
        ? graphWorldPoint(old)
        : initial[id]!;
  }
  final result = forceLabelLayout(world, edges, labels, names);
  return (
    points: {
      for (final entry in result.points.entries)
        entry.key: GraphPoint(
          entry.value.x / 240,
          entry.value.y / 240,
          entry.value.z / 432,
        ),
    },
    edges: edges,
    clusters: result.clusters,
  );
});
