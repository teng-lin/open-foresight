import 'dart:async';
import 'package:matcher/expect.dart';

/// Poll [predicate] until it holds or [timeout] elapses.
///
/// A timeout says only that the condition was not observed. [label] names what
/// was awaited and [describe] samples the fixture's state at the deadline, so
/// a failure shows which prerequisite was missing instead of one bare timeout.
/// [describe] must be cheap, synchronous and side-effect free; if it throws,
/// only the error type is reported. Neither changes the deadline.
Future<void> eventually(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
  String? label,
  String Function()? describe,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(eventuallyFailureMessage(timeout, label: label, describe: describe));
}

/// The failure text [eventually] reports; the first line is unchanged.
String eventuallyFailureMessage(
  Duration timeout, {
  String? label,
  String Function()? describe,
}) {
  final message = StringBuffer(
    'Condition was not observed before the $timeout deadline',
  );
  if (label != null) message.write('\nawaiting: $label');
  if (describe != null) {
    String observed;
    try {
      observed = describe();
    } catch (error) {
      observed = 'unavailable (${error.runtimeType})';
    }
    message.write('\nobserved at deadline: $observed');
  }
  return message.toString();
}
