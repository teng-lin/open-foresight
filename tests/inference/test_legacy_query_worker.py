import io
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from legacy_query_worker import MAX_FRAME, serve


class Executor:
    cache_storage = 'float16'
    def __init__(self):
        self.calls = []

    def generate(self, transcript, limit):
        self.calls.append((transcript, limit))
        if transcript == 'overflow':
            raise ValueError('Prompt exceeds the original 512-token context')
        return {'text': ' Question?\n', 'finish_reason': 'eos', 'cache_storage': self.cache_storage}


class DedicatedWorkerProtocolTest(unittest.TestCase):
    def run_requests(self, requests):
        executor, output = Executor(), io.StringIO()
        serve(executor, io.StringIO(''.join(json.dumps(r) + '\n' for r in requests)), output)
        return executor, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_preserves_raw_output_and_removes_exactly_one_control_prefix(self):
        executor, frames = self.run_requests([
            {'id': 'owned', 'prompt': ' <ctrl1> <ctrl1>Transcript\0tail'}])
        self.assertEqual(executor.calls, [(' <ctrl1>Transcript\0tail', 512)])
        self.assertEqual(frames[1]['text'], ' Question?\n')
        self.assertEqual(frames[1]['id'], 'owned')
        self.assertFalse(frames[1]['original_gpu_parity_verified'])
        self.assertEqual(frames[0]['cache_storage'], 'float16')
        self.assertEqual(frames[1]['cache_storage'], 'float16')

    def test_bad_request_and_context_overflow_do_not_poison_next_request(self):
        executor, frames = self.run_requests([
            {'id': 'chat', 'prompt': 'ordinary chat prompt'},
            {'id': 'overflow', 'prompt': ' <ctrl1>overflow'},
            {'id': 'next', 'prompt': ' <ctrl1>OK', 'max_output_tokens': 3}])
        self.assertEqual([f['type'] for f in frames], ['ready', 'error', 'error', 'result'])
        self.assertEqual(executor.calls, [('overflow', 512), ('OK', 3)])

    def test_invalid_ownership_and_output_limits_never_execute(self):
        executor, frames = self.run_requests([
            {'prompt': ' <ctrl1>Question?'},
            {'id': 'x', 'prompt': ' <ctrl1>Question?', 'max_output_tokens': True},
            {'id': 'x', 'prompt': ' <ctrl1>Question?', 'max_output_tokens': 513}])
        self.assertEqual(executor.calls, [])
        self.assertTrue(all(f['type'] == 'error' for f in frames[1:]))

    def test_oversized_protocol_frame_terminates_before_inference(self):
        executor = Executor()
        with self.assertRaisesRegex(ValueError, '1 MiB'):
            serve(executor, io.StringIO('x' * (MAX_FRAME + 1)), io.StringIO())
        self.assertEqual(executor.calls, [])


if __name__ == '__main__':
    unittest.main()
