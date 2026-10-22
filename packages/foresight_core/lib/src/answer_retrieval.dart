export 'answer_passage_reader.dart' show retrieveAnswerPassages;
import 'dart:convert';
import 'dart:math' as math;

/// Clean retrieval copies only; source documents and the helper index stay intact.
String cleanAnswerText(String text) {
  text = text.replaceAll(r'\r\n', '\n').replaceAll(r'\n', '\n');
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\(([^)]*)\)'),
    (m) => m[1]!,
  );
  // Angle brackets also express numeric targets. A broad <...> matcher can
  // erase everything between "<25" and a later ">95%", including headings.
  text = text.replaceAll(
    RegExp(r'</?[A-Za-z][A-Za-z0-9:-]*(?:\s[^<>]*?)?\s*/?>'),
    ' ',
  );
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  return text.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n').trim();
}

String _words(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'https?://\S+'), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

List<String> answerQueryTerms(String question) {
  const stop = {
    'a',
    'an',
    'the',
    'is',
    'are',
    'was',
    'were',
    'who',
    'what',
    'when',
    'where',
    'why',
    'how',
    'do',
    'does',
    'did',
    'can',
    'could',
    'would',
    'should',
    'of',
    'to',
    'for',
    'in',
    'on',
    'at',
    'and',
    'or',
    'with',
    'about',
    'tell',
    'me',
    'please',
    'cite',
    'i',
    'you',
    'my',
    'need',
    'want',
    'give',
    'explain',
    'detail',
    'details',
    'detailed',
    'step',
    'steps',
    'by',
    'instruction',
    'instructions',
  };
  return _words(
    question.replaceAll(RegExp(r'\[S\d+\]'), ''),
  ).split(' ').where((s) => s.isNotEmpty && !stop.contains(s)).toSet().toList();
}

/// Expand a strongly title-matched procedure instead of treating its individual
/// steps as independent search hits. Only complete, bounded documents qualify;
/// never present a truncated guide as the whole procedure.
Map<String, Object?>? _completeProcedure(
  String question,
  List<String> terms,
  List<Map<String, Object?>> sources,
) {
  if (!RegExp(
        r'\b(how|steps?|instructions?|procedure|walkthrough)\b',
        caseSensitive: false,
      ).hasMatch(question) ||
      terms.length < 2) {
    return null;
  }
  Map<String, Object?>? best;
  var bestScore = 0.0;
  for (final source in sources) {
    final title = ' ${_words(source['title'] as String)} ';
    final matched = terms.where((term) => title.contains(' $term ')).length;
    if (matched < 2 || matched / terms.length < .75) continue;
    final text = cleanAnswerText(source['content'] as String);
    if (utf8.encode(text).length > 16000) continue;
    final steps = RegExp(
      r'^#{1,6}\s+Step\s+(\d+)\b',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(text).map((m) => int.parse(m[1]!)).toList();
    if (steps.length < 3 ||
        steps.asMap().entries.any((e) => e.value != e.key + 1)) {
      continue;
    }
    final score = matched / terms.length;
    if (score <= bestScore) continue;
    bestScore = score;
    best = {
      'document_id': source['id'],
      'revision': source['revision'],
      'title': source['title'],
      'excerpt': text,
      'rank_score': score,
      'score': null,
      'complete_procedure': true,
      'step_count': steps.length,
    };
  }
  return best;
}

bool _useful(String text) {
  final words = _words(text).split(' ').where((s) => s.isNotEmpty).toList();
  if (words.length >= 3) return true;
  final normalized = _words(text);
  if ({
    'image',
    'images',
    'n',
    'redirect',
    'png',
    'jpg',
    'svg',
  }.contains(normalized)) {
    return false;
  }
  // Short real facts such as a date, name, or "Tuesday" remain usable.
  // Encoded URL tails and long hex hashes are not prose evidence.
  return RegExp(r"^[\p{L}\p{N}\s.,:'’\-–]+$", unicode: true).hasMatch(text) &&
      RegExp(r'\p{L}{2}', unicode: true).hasMatch(text) &&
      !RegExp(r'^[0-9a-f]{12,}$', caseSensitive: false).hasMatch(normalized);
}

double _lexical(String text, List<String> terms) {
  if (terms.isEmpty) return 0;
  final normalized = ' ${_words(text)} ';
  final present = terms.where((word) => normalized.contains(' $word ')).length;
  final phrase =
      terms.length > 1 && normalized.contains(' ${terms.join(' ')} ');
  return present / terms.length * 2 + (phrase ? 3 : 0);
}

String _evidenceSection(
  String text,
  int offset,
  String fallback,
  List<RegExpMatch> headings, {
  bool allowSemanticExpansion = false,
}) {
  // Short documents are already bounded evidence. Starting at a title or the
  // first paragraph must not discard complementary facts later in the document.
  if (headings.isEmpty &&
      text.length <= 4000 &&
      utf8.encode(text).length <= 4000) {
    return text;
  }
  RegExpMatch? start;
  final ancestors = <RegExpMatch>[];
  for (final heading in headings) {
    if (heading.start > offset) break;
    ancestors.removeWhere((h) => h[1]!.length >= heading[1]!.length);
    ancestors.add(heading);
    start = heading;
  }
  if (start != null) {
    var end = text.length;
    for (final heading in headings) {
      if (heading.start > start.start &&
          heading[1]!.length <= start[1]!.length) {
        end = heading.start;
        break;
      }
    }
    final parent = ancestors
        .take(ancestors.length - 1)
        .map((h) => h.group(0))
        .join('\n\n');
    if (end - start.start + parent.length + 2 <= 4000) {
      final section = [
        parent,
        text.substring(start.start, end).trim(),
      ].where((s) => s.isNotEmpty).join('\n\n');
      if (utf8.encode(section).length <= 4000) return section;
    }
  }
  // A full paragraph is preferable to a byte window through a sentence.
  final before = text.lastIndexOf('\n\n', offset);
  final after = text.indexOf('\n\n', offset);
  final paragraphStart = before < 0 ? 0 : before + 2;
  final paragraphEnd = after < 0 ? text.length : after;
  if (paragraphEnd - paragraphStart > 4000) return fallback;
  final paragraph = text.substring(paragraphStart, paragraphEnd).trim();
  // A semantic hit can span several paragraphs. Expansion may add context,
  // but must not reduce that hit to only its opening paragraph.
  if (allowSemanticExpansion &&
      text.startsWith(fallback, offset) &&
      fallback.length > paragraph.length &&
      fallback.length <= 4000 &&
      fallback.contains(paragraph) &&
      utf8.encode(fallback).length <= 4000) {
    return fallback;
  }
  return utf8.encode(paragraph).length <= 4000 ? paragraph : fallback;
}

/// Example libraries need complete entries, not windows around the word
/// "example" in their index. Return authored entries only when the subject,
/// requested count and complete section boundaries are unambiguous.
List<Map<String, Object?>>? _completeExamples(
  String question,
  List<Map<String, Object?>> sources,
) {
  final request = RegExp(
    r'\b(one|two|three|four|five|six|[1-6])\s+(?:detailed\s+)?examples?\b',
    caseSensitive: false,
  ).firstMatch(question);
  if (request == null) return null;
  const counts = {
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
  };
  final count = counts[request[1]!.toLowerCase()] ?? int.parse(request[1]!);
  final terms = answerQueryTerms(question)
      .where(
        (t) => !{
          'show',
          'provide',
          'examples',
          'example',
          'one',
          'two',
          'three',
          'four',
          'five',
          'six',
          '1',
          '2',
          '3',
          '4',
          '5',
          '6',
        }.contains(t),
      )
      .toList();
  if (terms.isEmpty) return null;
  for (final source in sources) {
    final title = ' ${_words(source['title'] as String)} ';
    if (!RegExp(r'\bexamples?\b').hasMatch(title) ||
        !terms.every((t) => title.contains(' $t '))) {
      continue;
    }
    final text = cleanAnswerText(source['content'] as String);
    final headings = RegExp(
      r'^(#{1,6})\s+([^\n]+)',
      multiLine: true,
    ).allMatches(text).toList();
    final entries = <Map<String, Object?>>[];
    var bytes = 0;
    for (var i = 0; i < headings.length; i++) {
      final h = headings[i];
      if (!RegExp(r'^\d+[.)]\s+').hasMatch(h[2]!)) continue;
      var end = text.length;
      for (var j = i + 1; j < headings.length; j++) {
        if (headings[j][1]!.length <= h[1]!.length) {
          end = headings[j].start;
          break;
        }
      }
      final entry = text.substring(h.start, end).trim();
      // Reject a numbered index, short link list, or incomplete/oversized entry.
      if (entry.length < 400 ||
          RegExp(r'^\|', multiLine: true).allMatches(entry).length < 4) {
        continue;
      }
      bytes += utf8.encode(entry).length;
      if (bytes > 16000) break;
      entries.add({
        'document_id': source['id'],
        'revision': source['revision'],
        'title': source['title'],
        'excerpt': entry,
        'score': null,
        'rank_score': 1.0,
        'complete_example': true,
      });
      if (entries.length == count) return entries;
    }
  }
  return null;
}

/// Fuse semantic candidates with bounded passages matching the query's words.
/// Exact multiword names outrank unrelated high-cosine boilerplate.
List<Map<String, Object?>> rankAnswerPassages(
  String question,
  List<Map<String, Object?>> sources,
  List<Map<String, Object?>> semantic,
) {
  final terms = answerQueryTerms(question);
  final procedure = _completeProcedure(question, terms, sources);
  if (procedure != null) return [procedure];
  final examples = _completeExamples(question, sources);
  if (examples != null) return examples;
  final current = {
    for (final source in sources) source['id'] as String: source,
  };
  final candidates = <String, Map<String, Object?>>{};
  final cleanedDocuments = <Object?, String>{};
  final documentHeadings = <Object?, List<RegExpMatch>>{};
  String cleaned(Map<String, Object?> source) => cleanedDocuments.putIfAbsent(
    source['id'],
    () => cleanAnswerText(source['content'] as String),
  );
  String section(
    Map<String, Object?> source,
    String text,
    int offset,
    String fallback, {
    bool allowSemanticExpansion = false,
  }) => _evidenceSection(
    text,
    offset,
    fallback,
    documentHeadings.putIfAbsent(
      source['id'],
      () => RegExp(
        r'^(#{1,6})\s+[^\n]+',
        multiLine: true,
      ).allMatches(text).toList(),
    ),
    allowSemanticExpansion: allowSemanticExpansion,
  );
  void add(
    Map<String, Object?> source,
    String text,
    double semanticBonus, {
    double? similarity,
    bool expand = true,
    bool allowSemanticExpansion = false,
  }) {
    if (expand) {
      text = cleanAnswerText(text);
      final document = cleaned(source);
      final offset = document.indexOf(text);
      if (offset >= 0) {
        text = section(
          source,
          document,
          offset,
          text,
          allowSemanticExpansion: allowSemanticExpansion,
        );
      }
    }
    if (!_useful(text)) return;
    final canonical = _words(text);
    final score = _lexical(text, terms) + semanticBonus;
    final previous = candidates[canonical];
    if (previous != null && (previous['rank_score'] as double) >= score) return;
    candidates[canonical] = {
      'document_id': source['id'],
      'revision': source['revision'],
      'title': source['title'],
      'excerpt': text,
      'rank_score': score,
      'score': similarity,
    };
  }

  for (var i = 0; i < semantic.length; i++) {
    final candidate = semantic[i];
    final source = current[candidate['document_id']];
    if (source != null) {
      add(
        source,
        candidate['text'] as String,
        .25 / (1 + i),
        similarity: (candidate['score'] as num?)?.toDouble(),
        allowSemanticExpansion: true,
      );
    }
  }
  if (terms.isNotEmpty) {
    RegExp patternFor(Iterable<String> terms) => RegExp(
      '(?<![\\p{L}\\p{N}])(?:${terms.map(RegExp.escape).join('|')})(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
    final pattern = patternFor(terms);
    final matches = <Object?, Set<String>>{};
    final frequencies = <String, int>{};
    // Cheap document discovery precedes section expansion. Broad words such
    // as "targets" must not trigger hundreds of full-document rescans.
    for (final source in sources) {
      // Substring discovery deliberately over-recalls; exact boundaries and
      // passage scoring are applied only to the bounded shortlist.
      final raw = '${source['title']}\n${source['content']}'.toLowerCase();
      final found = terms.where(raw.contains).toSet();
      if (found.isEmpty) continue;
      matches[source['id']] = found;
      for (final term in found) {
        frequencies[term] = (frequencies[term] ?? 0) + 1;
      }
    }
    double weight(String term) =>
        1 + math.log((sources.length + 1) / ((frequencies[term] ?? 0) + 1));
    double documentScore(Map<String, Object?> source) =>
        matches[source['id']]!.fold<double>(0, (s, t) => s + weight(t)) +
        _lexical(source['title'] as String, terms);
    final discovered =
        sources.where((s) => matches.containsKey(s['id'])).toList()
          ..sort((a, b) => documentScore(b).compareTo(documentScore(a)));
    final rareTerms = terms.where((t) => (frequencies[t] ?? 0) > 0).toList()
      ..sort((a, b) => weight(b).compareTo(weight(a)));
    for (final source in discovered.take(16)) {
      final text = cleaned(source);
      final windows = <int>{};
      final sections = <String>{};
      final focusPattern = patternFor(
        rareTerms.where(matches[source['id']]!.contains).take(2),
      );
      final focused = focusPattern.hasMatch(text) ? focusPattern : pattern;
      for (final match in focused.allMatches(text).take(64)) {
        final start = math.max(0, match.start - 260);
        if (!windows.add(start ~/ 200)) continue;
        final end = math.min(text.length, match.end + 650);
        final excerpt = section(
          source,
          text,
          match.start,
          text.substring(start, end),
        );
        if (sections.add(excerpt)) add(source, excerpt, 0, expand: false);
      }
      if (windows.isEmpty && _lexical(source['title'] as String, terms) > 0) {
        add(source, text.substring(0, math.min(text.length, 900)), 0);
      }
    }
  }
  final ranked = candidates.values.toList()
    ..sort(
      (a, b) =>
          (b['rank_score'] as double).compareTo(a['rank_score'] as double),
    );
  final counts = <Object?, int>{};
  final selected = <Map<String, Object?>>[];
  for (final passage in ranked) {
    final id = passage['document_id'];
    if ((counts[id] ?? 0) >= 2) continue;
    counts[id] = (counts[id] ?? 0) + 1;
    selected.add(passage);
    if (selected.length == 6) break;
  }
  return selected;
}

/// Return the authored steps, not a model paraphrase. Exclude YAML/prologue and
/// trailing unrelated sections; retain all nested tables, notes and outputs.
String renderProcedureGuide(String document, String citation) {
  final steps = RegExp(
    r'^(#{1,6})\s+Step\s+\d+\b[^\n]*',
    multiLine: true,
    caseSensitive: false,
  ).allMatches(document).toList();
  if (steps.isEmpty) throw const FormatException('No source procedure found');
  final sections = <String>[];
  for (var i = 0; i < steps.length; i++) {
    final start = steps[i].start;
    var end = i + 1 < steps.length ? steps[i + 1].start : document.length;
    if (i == steps.length - 1) {
      final boundary = RegExp(
        '^#{1,${steps[i][1]!.length}}\\s+',
        multiLine: true,
      ).firstMatch(document.substring(steps[i].end));
      if (boundary != null) end = steps[i].end + boundary.start;
    }
    sections.add('${document.substring(start, end).trim()}\n\n[$citation]');
  }
  return 'From your source guide:\n\n${sections.join('\n\n')}';
}
