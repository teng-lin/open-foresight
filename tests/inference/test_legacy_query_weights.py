import importlib.util
from pathlib import Path
import unittest

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'legacy_query_weights', ROOT / 'tools/legacy_query_weights.py')
weights = importlib.util.module_from_spec(spec)
spec.loader.exec_module(weights)


class LegacyWeightPackingTest(unittest.TestCase):
    def test_known_gpu_interleave_and_unsigned_zero_point(self):
        # Two 4-output blocks, each with two 4-input blocks. Construct packed
        # bytes independently from the decoder's reshape/transpose operation.
        matrix = np.arange(-32, 32, dtype=np.int8).reshape(8, 8)
        raw = bytes(int(matrix[o, i]) + 128
                    for ib in range(2) for ob in range(2)
                    for i in range(ib * 4, ib * 4 + 4)
                    for o in range(ob * 4, ob * 4 + 4))
        actual = weights.unpack_gpu_matrix(raw, 8, 8, matrix.sum(axis=1))
        np.testing.assert_array_equal(actual, matrix)

    def test_corruption_and_dimension_mismatch_are_rejected(self):
        sums = np.zeros(8, dtype=np.int32)
        with self.assertRaisesRegex(ValueError, 'row checksums'):
            weights.unpack_gpu_matrix(bytes([129]) * 64, 8, 8, sums)
        with self.assertRaisesRegex(ValueError, 'dimensions'):
            weights.unpack_gpu_matrix(bytes(64), 8, 7, sums)
        with self.assertRaisesRegex(ValueError, 'checksum dimensions'):
            weights.unpack_gpu_matrix(bytes(64), 8, 8, np.zeros(4))

    def test_flatbuffer_bounds_are_checked(self):
        reader = weights.FlatBuffer(bytes(8))
        for offset in [-1, 6, 100]:
            with self.assertRaisesRegex(ValueError, 'outside'):
                reader.unpack('<I', offset)


if __name__ == '__main__':
    unittest.main()
