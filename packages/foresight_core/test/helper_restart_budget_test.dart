import 'package:foresight_core/src/helper.dart';
import 'package:test/test.dart';

void main() {
  test('helper crash budget resets after a quiet ten-minute window', () {
    var now = DateTime.utc(2026);
    final budget = HelperRestartBudget(now: () => now);
    for (var i = 0; i < 3; i++) {
      expect(budget.reserve(), isTrue);
    }
    expect(budget.reserve(), isFalse);
    now = now.add(const Duration(minutes: 9));
    expect(budget.reserve(), isFalse);
    now = now.add(const Duration(minutes: 1));
    expect(budget.reserve(), isTrue);
    expect(budget.attempts, 1);
    budget.reset();
    expect(budget.attempts, 0);
    expect(budget.reserve(), isTrue);
  });
}
