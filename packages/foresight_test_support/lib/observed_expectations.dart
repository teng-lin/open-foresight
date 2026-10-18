import 'package:matcher/expect.dart' as matcher;

/// The report is produced by the expectation operation itself. Removing a named
/// expectation also removes its observation, which the external gate requires.
class ObservedExpectations {
  final _observations = <Map<String, Object?>>[];

  void expect(String name, Object? actual, Object? expected) {
    matcher.expect(actual, expected);
    _observations.add({
      'name': name,
      'actual':
          actual is num || actual is bool || actual is String || actual == null
          ? actual
          : actual.runtimeType.toString(),
      'expected':
          expected is num ||
              expected is bool ||
              expected is String ||
              expected == null
          ? expected
          : expected.toString(),
      'passed': true,
    });
  }

  Map<String, Object> toJson() => {
    'schema': 1,
    'expectations': List<Map<String, Object?>>.unmodifiable(_observations),
  };
}
