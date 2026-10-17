import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'grounded', Path(__file__).resolve().parents[2] / 'services/inference/macos/grounded_generation.py')
grounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grounded)


class Tokenizer:
    def tokenize(self, text):
        return list(text)  # Deliberately expensive, exercising budget rejection.


class GroundedGenerationTests(unittest.TestCase):
    def test_shared_citation_and_validation_corpus(self):
        cases = json.loads((Path(__file__).resolve().parents[2] /
                            'tests/inference/grounding_cases.json').read_text())
        for case in cases:
            with self.subTest(text=case['text']):
                self.assertEqual(not grounded.validate_draft(case['text'], case['evidence']), case['valid'])


    def test_numeric_copy_and_citation_attribution(self):
        evidence = {'S1': 'Mira leads Atlas. Montreal consultation: Sept 2019. Duration 12–24 months; dose 100 mg; efficacy >95%; cost <$3.',
                    'S2': 'The planning meeting is Friday.'}
        self.assertEqual(grounded.validate_draft(
            'Mira leads Atlas. Consultation: September 2019. Dose 100 mg; duration 12–24 months; efficacy >95%; cost <$3. [S1]', evidence), [])
        for bad in [
            'Montreal consultation: Sept 207. [S1]',
            'Duration 124 months. [S1]',
            'Duration 12–24 days. [S1]',
            'Duration 24–12 months. [S1]',
            'Efficacy <95%. [S1]',
            'Cost <€3. [S1]',
            'Mira leads Atlas. [S2]',
            'Mira leads Atlas. [S99]',
            'Mira leads Atlas.',
        ]:
            with self.subTest(bad=bad):
                self.assertTrue(grounded.validate_draft(bad, evidence))

    def test_synthesis_keeps_all_range_citations_and_verifies_their_evidence(self):
        request = {'version': 1, 'question': 'Who leads Atlas?', 'sources': [
            {'citation': f'S{i}', 'title': 'Atlas', 'excerpt': 'Mira leads Atlas.'}
            for i in range(1, 4)]}
        with patch.object(grounded, '_generate', side_effect=[
                'S1.1 S2.1 S3.1', 'Mira leads Atlas. [S1-S3]', 'SUPPORTED']) as generate:
            result = grounded.grounded_answer(Tokenizer(), None, request, 512)
        self.assertEqual(result['citations'], ['S1', 'S2', 'S3'])
        self.assertEqual(result['method'], 'verified-synthesis')
        verifier_prompt = generate.call_args_list[-1].args[2]
        self.assertEqual(set(json.loads(verifier_prompt.split('\n')[-1])['evidence']), {'S1', 'S2', 'S3'})

    def test_each_paragraph_needs_its_own_support(self):
        evidence = {'S1': 'Mira leads Atlas.', 'S2': 'Launch 2024.'}
        self.assertTrue(grounded.validate_draft(
            'Mira leads Atlas. [S1]\n\nLaunch 2024. [S1]', evidence))
        self.assertEqual(grounded.validate_draft(
            'Mira leads Atlas. [S1]\n\nLaunch 2024. [S2]', evidence), [])
        self.assertTrue(grounded.validate_draft(
            '| Item | Value |\n|---|---|\n| Launch | 2024 [S1] |\n| Lead | Mira leads Atlas [S2] |', evidence))

    def test_historical_price_caveat_cannot_disappear(self):
        evidence = {'S1': 'Cost <$3. These are historical targets, not current prices.'}
        self.assertTrue(grounded.validate_draft('Cost <$3. [S1]', evidence))
        self.assertEqual(grounded.validate_draft('Historical target cost <$3; not current prices. [S1]', evidence), [])
        self.assertTrue(grounded.validate_draft('Historical cost >$3. [S1]', evidence))

    def test_only_exact_copied_table_rows_receive_automatic_attribution(self):
        table = '| Attribute | Target |\n|---|---|\n| Cost | <$3 |'
        note = 'These are historical 2017 targets, not current prices.'
        evidence = {'S1': table + '\n' + note}
        result = grounded.attribute_source_copies(table, evidence,
            [{'source': 'S1', 'text': note}])
        self.assertIn('<$3  [S1]', result)
        self.assertIn('**Source caveat:** ' + note + ' [S1]', result)
        changed = grounded.attribute_source_copies('| Cost | <$5 |', evidence, [])
        self.assertNotIn('[S1]', changed)
        self.assertTrue(grounded.validate_draft(changed, evidence))

    def test_nested_step_output_keeps_heading_and_citation_together(self):
        text = ('## Instructions\n\n**Step 1: Define the population**\n'
                '* **Output:** A population statement. [S1]\n\n'
                '**Missing information:**\n\nNo numerical thresholds are specified. [S1]')
        evidence = {'S1': 'Step 1: Define the population. Output a population statement. No numerical thresholds are specified.'}
        self.assertEqual(grounded.validate_draft(text, evidence), [])
        self.assertIn('Define the population', grounded.claim_blocks(text)[0])
        self.assertEqual(grounded.validate_draft(
            '## Profile\n\nThe profile contains these attributes:\n\n'
            '* Dose target: 100 mg. [S1]',
            {'S1': 'The profile has a dose target of 100 mg.'}), [])

    def test_retry_rejects_changed_number_and_publishes_only_corrected_draft(self):
        request = {'version': 1, 'question': 'When is launch?', 'sources': [
            {'citation': 'S1', 'title': 'Launch', 'excerpt': 'The launch is in 2024.'}]}
        with patch.object(grounded, '_generate', side_effect=[
                'S1.1', 'The launch is in 204. [S1]', 'The launch is in 2024. [S1]', 'SUPPORTED']):
            result = grounded.grounded_answer(Tokenizer(), None, request, 512)
        self.assertEqual(result['answer'], 'The launch is in 2024. [S1]')
        self.assertEqual(result['grounding']['attempts'], 2)

    def test_failed_drafts_use_explicit_unchanged_source_fallback(self):
        request = {'version': 1, 'question': 'When is launch?', 'sources': [
            {'citation': 'S1', 'title': 'Launch', 'excerpt': 'Launch is in 2024.'}]}
        with patch.object(grounded, '_generate', side_effect=[
                'S1.1', 'Launch is in 204. [S1]', 'Launch is in 207. [S1]']):
            result = grounded.grounded_answer(Tokenizer(), None, request, 512)
        self.assertEqual(result['method'], 'source-fallback')
        self.assertIn('Launch is in 2024.', result['answer'])
        self.assertNotIn('204.', result['answer'])

    def test_unknown_selection_cannot_introduce_a_source(self):
        request = {'version': 1, 'question': 'When is launch?', 'sources': [
            {'citation': 'S1', 'title': 'Launch', 'excerpt': 'Launch is in 2024.'}]}
        with patch.object(grounded, '_generate', return_value='S99.1'):
            result = grounded.grounded_answer(Tokenizer(), None, request, 512)
        self.assertEqual(result['method'], 'source-fallback')
        self.assertEqual(result['citations'], ['S1'])

    def test_unknown_question_remains_insufficient(self):
        request = {'version': 1, 'question': 'Who is Unlisted?', 'sources': [
            {'citation': 'S1', 'title': 'Launch', 'excerpt': 'Launch is in 2024.'}]}
        with patch.object(grounded, '_generate', return_value='NONE'):
            self.assertEqual(grounded.grounded_answer(Tokenizer(), None, request, 512)['citations'], [])

    def test_meaning_verification_rejects_unsupported_and_ambiguous_verdicts(self):
        for verdict in ['UNSUPPORTED', 'Probably supported', '']:
            with patch.object(grounded, '_generate', return_value=verdict):
                self.assertFalse(grounded.verify_support(Tokenizer(), None,
                    'Orion is approved. [S1]', {'S1': 'Orion is not approved.'}))

    def test_context_reserves_output_and_never_slices_a_fact(self):
        units = [{'id': 'S1.1', 'heading': 'Dose', 'text': '100 mg ' * 1000},
                 {'id': 'S1.2', 'heading': 'Duration', 'text': '12–24 months'}]
        selected = grounded.fit_units(Tokenizer(), units, 'Question\n', 1536)
        self.assertEqual(selected, [units[1]])
        self.assertLessEqual(len(Tokenizer().tokenize('Question\n' + '\n\n'.join(map(grounded.unit_text, selected)))) + 1536 + 256, 4096)


if __name__ == '__main__':
    unittest.main()
