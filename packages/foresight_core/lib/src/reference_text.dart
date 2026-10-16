import 'dart:convert';

/// Original JsonUtils.sanitizeStringForUtf8: repair UTF-16, remove replacement
/// characters, and retain printable ASCII plus CR/LF. Used on detector output
/// and fetched web content, not on transcripts or web summary text.
String sanitizeReferenceUtf8(String text) => utf8
    .decode(utf8.encode(text), allowMalformed: true)
    .replaceAll('\uFFFD', '')
    .replaceAll(RegExp(r'[^\x20-\x7E\n\r]'), '');
