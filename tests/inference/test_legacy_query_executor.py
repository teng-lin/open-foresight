import os
import math
from pathlib import Path
import sys
import unittest

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
try:
    import sentencepiece
    from legacy_query_executor import LegacyQueryExecutor, proto_fields, rms_norm, rope
except ModuleNotFoundError:
    sentencepiece = None


@unittest.skipIf(sentencepiece is None, 'Requires the isolated sentencepiece dependency')
class LegacyExecutorMathTest(unittest.TestCase):
    def test_zero_stored_norm_scale_is_identity_scale(self):
        value = np.array([[3, 4]], dtype=np.float32)
        np.testing.assert_allclose(rms_norm(value, np.zeros(2)), value / np.sqrt(12.5 + 1e-6))
        np.testing.assert_array_equal(rms_norm(np.zeros(2)), np.zeros(2))

    def test_original_gpu_epsilon_is_added_before_inverse_square_root(self):
        value = np.array([[1e-8, 0]], dtype=np.float32)
        expected = np.array([[1e-8 / math.sqrt(5e-17 + 1e-6), 0]])
        np.testing.assert_allclose(rms_norm(value), expected, rtol=1e-6, atol=0)

    def test_rope_rotates_first_and_second_halves(self):
        value = np.array([[[1, 2, 3, 4]]], dtype=np.float32)
        np.testing.assert_array_equal(rope(value, np.array([0]), 10000), value)
        rotated = rope(value, np.array([np.pi / 2]), 10000)
        self.assertAlmostEqual(rotated[0, 0, 0], -3, places=5)
        self.assertAlmostEqual(rotated[0, 0, 2], 1, places=5)

    def test_rotary_timescale_matches_original_planar_kernel_formula(self):
        value = np.zeros((1, 1, 256), dtype=np.float32)
        value[0, 0, 1] = value[0, 0, 129] = 1
        for maximum in [10000, 1000000]:
            # Original kernel: fraction=2*channel/head_dim, timescale=
            # min*(max/min)^fraction, with min=1 and position=3.
            phase = 3 / math.pow(maximum, 2 / 256)
            actual = rope(value, np.array([3], dtype=np.float32), maximum)
            self.assertAlmostEqual(actual[0, 0, 1], math.cos(phase) - math.sin(phase), places=5)
            self.assertAlmostEqual(actual[0, 0, 129], math.sin(phase) + math.cos(phase), places=5)

    def test_truncated_metadata_rejects_incomplete_field(self):
        with self.assertRaisesRegex(ValueError, 'Truncated'):
            list(proto_fields(bytes([10, 5, 1])))


@unittest.skipUnless(sentencepiece is not None and os.environ.get('FORESIGHT_ORIGINAL_QUERY_MODEL'),
                     'Opt-in execution of the authenticated original detector')
class OriginalDetectorExecutionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = LegacyQueryExecutor(os.environ['FORESIGHT_ORIGINAL_QUERY_MODEL'])

    def test_batch_prefill_and_incremental_cache_agree(self):
        ids = [2] + self.model.tokenizer.encode(' <ctrl1>What time?')
        self.model.cache = [None] * 18
        batch = self.model.forward(ids, 0)
        self.model.cache = [None] * 18
        for position, token in enumerate(ids):
            incremental = self.model.forward([token], position)
        np.testing.assert_allclose(batch, incremental, rtol=2e-4, atol=5e-4)

    def test_original_question_output_and_statement_negative(self):
        positive = self.model.generate(
            'The launch is scheduled for Friday. What risks could delay it?', 64)
        self.assertEqual(positive['text'], 'What risks could delay the launch?')
        self.assertEqual(positive['finish_reason'], 'eos')
        negative = self.model.generate('The meeting starts at three.', 64)
        self.assertEqual(negative['text'], '')
        self.assertEqual(negative['finish_reason'], 'eos')


if __name__ == '__main__':
    unittest.main()
