import 'package:foresight_core/src/reference_query_detector.dart';
import 'package:test/test.dart';

void main() {
  test(
    'raw completion receives the exact prefix and request ownership',
    () async {
      final requests = <(String, String)>[];
      final detector = ReferenceQueryDetector((prompt, request) async {
        requests.add((prompt, request));
        return 'Who owns this? When is launch?';
      });
      expect(
        await detector.detect('What did we decide?', 'owned-detector-request'),
        ['When is launch?', 'Who owns this?'],
      );
      expect(requests, [
        (' <ctrl1>What did we decide?', 'owned-detector-request'),
      ]);
    },
  );

  test(
    'sanitizer repairs UTF-16 and preserves only printable ASCII and CR/LF',
    () {
      expect(
        sanitizeReferenceQueryOutput(
          'Who\u0000\t owns this?\nNext\r\n\uFFFD\uD800',
        ),
        'Who owns this?\nNext\r\n',
      );
      expect(sanitizeReferenceQueryOutput('谁负责测试？ 😀 café'), '  caf');
    },
  );

  test(
    'splitter keeps punctuation, trims pieces and retains unfinished remainder',
    () {
      expect(splitReferenceQuestions('  First?\n Second?  remainder  '), [
        'First?',
        'Second?',
        'remainder',
      ]);
      expect(splitReferenceQuestions(''), isEmpty);
      expect(splitReferenceQuestions(' \r\n '), isEmpty);
      expect(splitReferenceQuestions('?'), ['?']);
      expect(splitReferenceQuestions('one？two?'), ['one？two?']);
    },
  );

  test('parser reverses, rejects the marker and removes exact duplicates', () {
    expect(parseReferenceQueryOutput('Who? Who? WHO? >> ignored? remainder'), [
      'remainder',
      'WHO?',
      'Who?',
    ]);
    expect(parseReferenceQueryOutput('>> no questions'), isEmpty);
    expect(parseReferenceQueryOutput('谁负责测试？'), isEmpty);
    expect(parseReferenceQueryOutput('First? \uFFFDSecond?'), [
      'Second?',
      'First?',
    ]);
  });

  test(
    'completion failures propagate instead of becoming empty detection',
    () async {
      final detector = ReferenceQueryDetector((_, _) async {
        throw StateError('Dedicated model unavailable');
      });
      await expectLater(
        detector.detect('Who?', 'owned'),
        throwsA(isA<StateError>()),
      );
    },
  );
}
