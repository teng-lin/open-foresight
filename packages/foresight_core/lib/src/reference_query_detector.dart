import 'reference_text.dart';

/// The reference detector sends this prefix to its dedicated model, without
/// adding a chat template or a JSON response schema.
const referenceQueryPrefix = ' <ctrl1>';

String referenceQueryPrompt(String preparedTranscript) =>
    '$referenceQueryPrefix$preparedTranscript';

/// JsonUtils.sanitizeStringForUtf8 in the reference first repairs invalid
/// UTF-16 via a UTF-8 round trip, removes replacement characters, then removes
/// everything except printable ASCII and CR/LF. This applies to detector
/// output, not to the captured transcript or stored answer bodies.
String sanitizeReferenceQueryOutput(String output) =>
    sanitizeReferenceUtf8(output);

/// Reference splitIntoQuestions keeps ASCII question marks on each piece and
/// retains a final nonempty remainder even if it has no question mark.
List<String> splitReferenceQuestions(String output) {
  final questions = <String>[];
  var start = 0;
  while (start < output.length) {
    final mark = output.indexOf('?', start);
    if (mark < 0) break;
    final question = output.substring(start, mark + 1).trim();
    if (question.isNotEmpty) questions.add(question);
    start = mark + 1;
  }
  final remainder = output.substring(start).trim();
  if (remainder.isNotEmpty) questions.add(remainder);
  return questions;
}

List<String> parseReferenceQueryOutput(String output) {
  final result = <String>[];
  final seen = <String>{};
  for (final question in splitReferenceQuestions(
    sanitizeReferenceQueryOutput(output),
  ).reversed) {
    if (!question.startsWith('>>') && seen.add(question)) {
      result.add(question);
    }
  }
  return result;
}

/// Protocol adapter for the reference's dedicated completion model. A backend
/// must supply raw text completion; the generic chat/JSON path is not equivalent.
class ReferenceQueryDetector {
  const ReferenceQueryDetector(this.complete);
  final Future<String> Function(String prompt, String requestId) complete;

  Future<List<String>> detect(
    String preparedTranscript,
    String requestId,
  ) async {
    final output = await complete(
      referenceQueryPrompt(preparedTranscript),
      requestId,
    );
    return parseReferenceQueryOutput(output);
  }
}
