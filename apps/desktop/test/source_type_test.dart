import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/source_type.dart';

void main() {
  test('exported Drive formats retain their original display categories', () {
    final exported = {
      'mime': 'text/plain',
      'provenance': 'google-drive:account:file',
    };
    expect(
      sourceType(
        exported,
        originalMime: 'application/vnd.google-apps.presentation',
      ),
      SourceType.presentation,
    );
    expect(
      sourceType(
        exported,
        originalMime: 'application/vnd.google-apps.document',
      ),
      SourceType.document,
    );
    expect(
      sourceType({
        'mime': 'text/csv',
      }, originalMime: 'application/vnd.google-apps.spreadsheet'),
      SourceType.spreadsheet,
    );
  });
  test(
    'editing preserves origin categories; file extension cannot spoof PDF type',
    () {
      expect(
        sourceType({
          'mime': 'text/plain',
          'provenance': 'user edit; url:https://example.invalid',
        }),
        SourceType.url,
      );
      expect(
        sourceType({
          'mime': 'text/plain',
          'provenance': 'user edit; meeting:42',
        }),
        SourceType.meeting,
      );
      expect(
        sourceType({
          'mime': 'text/plain',
          'provenance': 'google-calendar:account:event',
        }),
        SourceType.calendar,
      );
      expect(
        sourceType({'mime': 'text/plain', 'title': 'pretend.pdf'}),
        SourceType.text,
      );
      expect(sourceType({'mime': 'application/pdf'}), SourceType.pdf);
    },
  );
}
