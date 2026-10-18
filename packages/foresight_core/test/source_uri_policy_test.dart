import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';

void main() {
  test(
    'source links allow web and local files and reject executable schemes',
    () {
      for (final value in [
        'https://example.test/source',
        'http://example.test',
        'file:///tmp/notes.md',
      ]) {
        expect(allowedSourceUri(Uri.parse(value)), isTrue, reason: value);
      }
      for (final value in [
        'javascript:alert(1)',
        'data:text/html,payload',
        'shell:command',
        'mailto:recipient@example.test',
        '/tmp/relative',
        'file://attacker/share',
        'https://user:password@example.test',
        'file:///tmp/a?command=run',
      ]) {
        expect(allowedSourceUri(Uri.parse(value)), isFalse, reason: value);
      }
    },
  );
}
