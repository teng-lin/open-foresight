import 'package:foresight_core/src/google_connections.dart';
import 'package:test/test.dart';

void main() {
  test('invitation HTML decodes entities and discards scripts', () async {
    final text = await calendarDescriptionText(
      '<b>Planning &amp; review</b><script>secret</script>',
    );
    expect(text, contains('Planning & review'));
    expect(text, isNot(contains('secret')));
  });
  test('80 KB malformed invitation is bounded', () async {
    final watch = Stopwatch()..start();
    await calendarDescriptionText('<a' * 40000);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
