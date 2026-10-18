import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/answer_contract.dart';
import 'package:test/test.dart';

void main() {
  final cases =
      (jsonDecode(
                File(
                  '../../tests/inference/grounding_cases.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  test('every shared corpus case declares its validation dimension', () {
    for (final entry in cases) {
      expect(entry['kind'], isIn(['syntax', 'fidelity']));
    }
    expect(cases.where((entry) => entry['kind'] == 'syntax'), isNotEmpty);
    expect(cases.where((entry) => entry['kind'] == 'fidelity'), isNotEmpty);
  });
  for (final entry in cases.where((entry) => entry['kind'] == 'syntax')) {
    test('shared citation syntax: ${entry['text']}', () {
      final evidence = (entry['evidence'] as Map).cast<String, String>();
      var accepted = false;
      try {
        final ids = citationIds(entry['text'] as String, evidence.length);
        accepted = ids.every(evidence.containsKey);
      } on FormatException {
        accepted = false;
      }
      expect(accepted, entry['valid']);
    });
  }
}
