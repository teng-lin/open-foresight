import 'dart:async';
import 'package:matcher/expect.dart';

Future<void> eventually(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not observed before the $timeout deadline');
}
