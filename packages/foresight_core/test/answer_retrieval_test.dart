import 'package:test/test.dart';
import 'package:foresight_core/src/answer_retrieval.dart';

Map<String, Object?> source(String id, String body, {String? title}) => {
  'id': id,
  'title': title ?? id,
  'revision': 1,
  'content': body,
};

void main() {
  for (final precedingParagraphs in [0, 1, 30]) {
    test(
      'short lexical paragraph stays complete at prefix=$precedingParagraphs',
      () {
        const paragraph =
            'Juniper milestones. The launch date is 7 November 2026.';
        final document =
            '${'Earlier unrelated prose. ' * precedingParagraphs}\n\n'
            '$paragraph\n\n${'Trailing unrelated prose. ' * 200}';
        final passages = rankAnswerPassages('Juniper milestones', [
          source('long', document),
        ], []);
        expect(passages.first['excerpt'], paragraph);
      },
    );
  }
  test('lexical title-only fallback expands just its opening paragraph', () {
    const paragraph = 'Opening unrelated context paragraph.';
    final passages = rankAnswerPassages('Juniper', [
      source(
        'long',
        '$paragraph\n\n${'Trailing unrelated prose. ' * 200}',
        title: 'Juniper',
      ),
    ], []);
    expect(passages.single['excerpt'], paragraph);
  });
  test('lexical windows still expand the complete matched paragraph', () {
    final paragraph =
        'Juniper milestones. ${'Context sentence. ' * 41}'
        'The launch date is 7 November 2026.';
    final document =
        '${'Earlier unrelated prose. ' * 30}\n\n$paragraph\n\n'
        '${'Trailing unrelated prose. ' * 160}';
    final passages = rankAnswerPassages('Juniper milestones', [
      source('long', document),
    ], []);
    expect(passages.first['excerpt'], paragraph);
  });
  const juniper =
      'Open Foresight Functional Parity Audit — Project Juniper\n\n'
      'This is a synthetic test document, not a real project.\n'
      'Audit marker: OF-PARITY-20261019.\n'
      'Project Juniper launches on 7 November 2026.\n'
      'The project owner is Mira Chen.\n'
      'The project budget is 8,400 test credits.\n'
      'The launch checklist is: review the checklist, run a rehearsal, and publish the release notes.\n'
      'The rehearsal happens on 3 November 2026.\n'
      'The project status is green.\n';
  for (final question in [
    'In the synthetic Project Juniper parity audit document, what is the launch date and who is the project owner? Use only that document and cite it.',
    'Who owns Project Juniper, and when does it launch?',
  ]) {
    for (final semantic in [false, true]) {
      test(
        'Juniper keeps complementary facts with semantic=$semantic: $question',
        () {
          final passages = rankAnswerPassages(
            question,
            [
              for (var i = 0; i < 30; i++)
                source(
                  'noise$i',
                  'Synthetic project parity audit document launch date owner. Unrelated project $i.',
                ),
              source(
                'juniper',
                juniper,
                title: 'Open Foresight Parity Audit - Project Juniper.txt',
              ),
            ],
            [
              if (semantic)
                {'document_id': 'juniper', 'text': juniper, 'score': .88},
            ],
          );
          final evidence = passages
              .where((p) => p['document_id'] == 'juniper')
              .single;
          expect(evidence['excerpt'], contains('Mira Chen'));
          expect(evidence['excerpt'], contains('7 November 2026'));
          expect(evidence['excerpt'], contains('not a real project'));
          expect(evidence['revision'], 1);
        },
      );
    }
  }
  test('Cedar preserves edited source revision and cited facts', () {
    final passages = rankAnswerPassages(
      "In the Cedar Brief fixture, who is Project Cedar's owner and what is its review date? Cite the source.",
      [
        {
          ...source(
            'cedar',
            'OF Parity Cedar Brief\n\nProject Cedar is owned by Rowan Vale.\nThe review date is 12 November 2026.\n\nAudit revision 2: verified through the UI.',
          ),
          'revision': 2,
        },
      ],
      [],
    );
    expect(passages.single['revision'], 2);
    expect(passages.single['excerpt'], contains('Rowan Vale'));
    expect(passages.single['excerpt'], contains('12 November 2026'));
  });
  test('semantic expansion keeps a bounded hit spanning plain paragraphs', () {
    const hit =
        'Juniper context.\n\nOwner Mira Chen.\n\nLaunch 7 November 2026.';
    final passages = rankAnswerPassages(
      'Juniper owner launch',
      [source('long', '$hit\n\n${'Unrelated trailing paragraph. ' * 200}')],
      [
        {'document_id': 'long', 'text': hit, 'score': .9},
      ],
    );
    expect(passages.first['excerpt'], contains(hit));
  });
  test(
    'bounded lexical discovery retains rare subjects among common distractors',
    () {
      final passages = rankAnswerPassages(
        'Describe Mira Shah and explain the planning targets',
        [
          for (var i = 0; i < 40; i++)
            source(
              'noise$i',
              'Planning targets and general profile guidance. ' * 40,
            ),
          source(
            'person',
            '${'Earlier context. ' * 500}'
                '\n\nMira Shah leads Atlas. She owns the planning targets.',
          ),
        ],
        [],
      );
      expect(passages.first['document_id'], 'person');
      expect(passages.first['excerpt'], contains('Mira Shah leads Atlas'));
    },
  );
  test('semantic hits expand a complete table with its subject headings', () {
    final table =
        '| Attribute | Minimum | Ideal |\n|---|---|---|\n'
        '| Efficacy | >95% at day 28 | >95% at days 42–63 |\n'
        '| Regimen | Two oral doses | One oral dose |\n'
        '${'Clinical targets retain population and historical evidence boundaries. ' * 15}';
    final passages = rankAnswerPassages(
      'Compare malaria efficacy targets',
      [
        source(
          'profiles',
          '# Profiles\n\n## Malaria treatment\n\n'
              '### Clinical targets\n$table\n\n## Another disease\nUnrelated targets.',
        ),
      ],
      [
        {'document_id': 'profiles', 'text': '>95% at day 28', 'score': .9},
      ],
    );
    expect(passages.first['excerpt'], contains('## Malaria treatment'));
    expect(passages.first['excerpt'], contains(table.trim()));
    expect(passages.first['excerpt'], isNot(contains('Another disease')));
  });
  test(
    'markup cleaning preserves numeric comparisons across example tables',
    () {
      const text =
          'eGFR <25 mL/min\n## Second example\n'
          '| Efficacy | >95% |\n| Cost | <\$3 |\n'
          '<b>Evidence</b>\nDuration <3 months; protection >5 years.';
      expect(
        cleanAnswerText(text),
        text.replaceAll('<b>', ' ').replaceAll('</b>', ' '),
      );
    },
  );
  String example(String name, String value) =>
      '## $name\nA published example with its evidence limitations.\n'
      '### Targets\n| Attribute | Minimum | Preferred |\n|---|---|---|\n'
      '| Duration | $value | 2 weeks |\n| Safety | Comparable | Better |\n'
      '${'Evidence boundaries and intended population remain part of the example. ' * 5}\n';

  test(
    'detailed examples expand entries instead of the index or process notes',
    () {
      final first = example('1. Alpha', '12–24 months');
      final second = example('2. Beta', '2019');
      final passages = rankAnswerPassages(
        'Show me two examples of ABC in detail',
        [
          source(
            'library',
            '# ABC Examples\n## Scope\nLabels only.\n'
                '$first$second## Related notes\nUnrelated process.',
            title: 'ABC Examples.md',
          ),
          source(
            'process',
            'ABC examples: 44 experts held a consultation in 2024.',
          ),
        ],
        [
          {
            'document_id': 'process',
            'text': 'ABC examples: 44 experts held a consultation in 2024.',
            'score': .99,
          },
        ],
      );
      expect(passages.length, 2);
      expect(passages.every((p) => p['complete_example'] == true), true);
      expect(passages[0]['excerpt'], first.trim());
      expect(passages[1]['excerpt'], second.trim());
      expect(passages.every((p) => p['document_id'] == 'library'), true);
    },
  );

  test(
    'example expansion respects subject, count, complete boundaries and budget',
    () {
      final entry = example('1. Alpha', '12–24 months');
      for (final library in [
        source('library', entry, title: 'Other Examples'),
        source('library', entry, title: 'ABC Examples'), // only one of two
        source(
          'library',
          '$entry${'padding ' * 3000}\n${example('2. Beta', '2019')}',
          title: 'ABC Examples',
        ),
        source(
          'library',
          '## 1. Alpha\nLink only\n## 2. Beta\nLink only',
          title: 'ABC Examples',
        ),
      ]) {
        final result = rankAnswerPassages('Give two detailed examples of ABC', [
          library,
        ], []);
        expect(result.any((p) => p['complete_example'] == true), false);
      }
      // A precise requested product must not be replaced by arbitrary examples.
      expect(
        rankAnswerPassages('Show two examples of ABC for children', [
          source(
            'library',
            '$entry${example('2. Beta', '2019')}',
            title: 'ABC Examples',
          ),
        ], []).any((p) => p['complete_example'] == true),
        false,
      );
    },
  );
  test('how-to retrieval retains all steps of a matching complete guide', () {
    final guide =
        '# How to Write a Target Product Profile\n\n'
        '${List.generate(10, (i) => '## Step ${i + 1} — Task ${i + 1}\n'
            '${'Relevant instructions and expected output. ' * 15}\n').join('\n')}';
    final passages = rankAnswerPassages(
      'How to write a Target Product Profile. I need step by step instruction',
      [
        source('guide', guide, title: 'How to Write a Target Product Profile'),
        source(
          'deal',
          'Target Product Profile. Preferred deal economics and diligence.',
          title: 'Sell-side workflow',
        ),
      ],
      [
        {
          'document_id': 'deal',
          'text':
              'Target Product Profile. Preferred deal economics and diligence.',
          'score': .99,
        },
      ],
    );
    expect(passages.single['document_id'], 'guide');
    expect(passages.single['complete_procedure'], true);
    expect(passages.single['step_count'], 10);
    expect(passages.single['excerpt'], guide.trim());
    final rendered = renderProcedureGuide(guide, 'S1');
    for (var i = 1; i <= 10; i++) {
      expect(rendered, contains('Step $i — Task $i'));
    }
    expect(RegExp(r'\[S1\]').allMatches(rendered).length, 10);
  });
  test(
    'source procedure preserves ranges and nested tables but omits unrelated sections',
    () {
      const guide =
          '---\nowner: person\n---\n# Guide\nIntroduction\n'
          '## Step 1 — Plan\nPlan the next 12–24 months.\n'
          '### Details\n| Minimum | Preferred |\n| 3 | 5 |\n'
          '## Step 2 — Review\nReview the evidence.\n'
          '## Step 3 — Maintain\n**Output:** A versioned plan.\n'
          '## Related notes\nUnrelated workflow links.';
      final result = renderProcedureGuide(guide, 'S1');
      expect(result, contains('12–24 months'));
      expect(result, contains('| Minimum | Preferred |\n| 3 | 5 |'));
      expect(result, contains('**Output:** A versioned plan.'));
      expect(result, isNot(contains('owner:')));
      expect(result, isNot(contains('Unrelated workflow')));
    },
  );
  test(
    'unrelated and oversized procedures cannot replace semantic evidence',
    () {
      final procedure = List.generate(
        3,
        (i) => '## Step ${i + 1}\nDo the work.',
      ).join('\n');
      for (final unrelated in [
        source('guide', procedure, title: 'How to Bake Bread'),
        source(
          'guide',
          '$procedure\n${'long ' * 4000}',
          title: 'How to Write a Target Product Profile',
        ),
      ]) {
        final passages = rankAnswerPassages(
          'How to write a Target Product Profile?',
          [unrelated, source('fact', 'A profile defines patient needs.')],
          [
            {
              'document_id': 'fact',
              'text': 'A profile defines patient needs.',
              'score': .7,
            },
          ],
        );
        expect(passages.any((p) => p['complete_procedure'] == true), false);
        expect(passages.any((p) => p['document_id'] == 'fact'), true);
      }
    },
  );
  test('short factual semantic excerpts survive boilerplate filtering', () {
    final result = rankAnswerPassages(
      'When is launch?',
      [source('date', 'Tuesday', title: 'Launch date')],
      [
        {'document_id': 'date', 'text': 'Tuesday', 'score': .8},
      ],
    );
    expect(result.single['excerpt'], 'Tuesday');
  });
  test('name passages beat high-cosine image and link boilerplate', () {
    final sources = [
      source(
        'noise',
        r'\n[![Image](images/x.png)](https://example.test/sidebar)\n',
      ),
      source(
        'bio',
        'Mira Shah is a materials researcher. She leads the Atlas laboratory.',
      ),
      source('partial', 'Shah is a common surname in this bibliography.'),
    ];
    final passages = rankAnswerPassages('Who is Mira Shah?', sources, [
      {'document_id': 'noise', 'text': sources.first['content'], 'score': .99},
      {'document_id': 'partial', 'text': sources.last['content'], 'score': .8},
    ]);
    expect(passages.first['document_id'], 'bio');
    expect(passages.first['excerpt'], contains('materials researcher'));
    expect(passages.any((p) => p['document_id'] == 'noise'), false);
  });
  test('semantic paraphrases remain usable without literal term overlap', () {
    final passages = rankAnswerPassages(
      'When is the launch?',
      [source('a', 'The release is scheduled for Tuesday.')],
      [
        {
          'document_id': 'a',
          'text': 'The release is scheduled for Tuesday.',
          'score': .7,
        },
      ],
    );
    expect(passages.single['excerpt'], contains('Tuesday'));
    expect(passages.single['score'], .7);
  });
  test(
    'passages are bounded, deduplicated and never use documents outside scope',
    () {
      final bio = source(
        'bio',
        '${'padding ' * 1000}Mira Shah leads Atlas. ${'end ' * 1000}',
      );
      final passages = rankAnswerPassages(
        'Who is Mira Shah?',
        [bio],
        [
          {
            'document_id': 'deleted',
            'text': 'Mira Shah owns a fictional company.',
            'score': 1.0,
          },
        ],
      );
      expect(passages, isNotEmpty);
      expect(passages.every((p) => p['document_id'] == 'bio'), true);
      expect((passages.first['excerpt'] as String).length, lessThan(1000));
      expect(passages.length, lessThanOrEqualTo(2));
    },
  );
  test(
    'retrieval cleaning preserves visible prose and normalizes exported newlines',
    () {
      expect(
        cleanAnswerText(
          r'Hello\n\n[Research group](https://example.test/a) ![Image](x.png)',
        ),
        'Hello\n\nResearch group',
      );
      expect(answerQueryTerms('Who is Mira Shah? Cite [S1].'), [
        'mira',
        'shah',
      ]);
    },
  );
}
