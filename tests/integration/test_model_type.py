#!/usr/bin/env python3
"""Distribution model type survives probe, one-shot, and persistent workers."""
import ctypes as C
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

LIBRARY = sys.argv.pop(1)


class ModelTypeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / 'model'
        self.model.write_text('fixture')
        self.lib = C.CDLL(LIBRARY)
        for name, args, result in [
            ('fs_engine_create_model_type', [C.c_char_p, C.c_char_p, C.c_int], C.c_void_p),
            ('fs_engine_probe', [C.c_void_p], C.c_int),
            ('fs_engine_destroy', [C.c_void_p], C.c_int),
            ('fs_conversation_create', [C.c_void_p], C.c_void_p),
            ('fs_generate_tools', [C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p, C.c_int], C.c_int),
            ('fs_event_poll', [C.c_void_p, C.c_int], C.c_void_p),
            ('fs_string_free', [C.c_void_p], None),
            ('fs_conversation_destroy', [C.c_void_p, C.c_int], C.c_int),
        ]:
            fn = getattr(self.lib, name)
            fn.argtypes, fn.restype = args, result

    def test_probe_and_both_generation_transports(self):
        for persistent in (False, True):
            with self.subTest(persistent=persistent):
                log = self.root / f'arguments-{persistent}.jsonl'
                worker = self.root / 'worker'
                worker.write_text('''#!/usr/bin/env python3
import json,sys
with open(''' + repr(str(log)) + ''','a') as output: output.write(json.dumps(sys.argv[1:])+'\\n')
assert sys.argv[sys.argv.index('--model-type')+1] == '14'
if '--probe' in sys.argv:
 print(json.dumps({'worker_protocol': ''' + ('1' if persistent else '0') + ''', 'native_stop_token_sequences': True}),flush=True)
elif '--serve' in sys.argv:
 print('ready 1',flush=True)
 for line in sys.stdin:
  if line.strip()=='shutdown': break
  operation,token,payload=line.strip().split(' ',2)
  if operation=='generate':
   print(token+' answer '+json.dumps({'role':'assistant','content':'ok'}),flush=True)
   print(token+' done completed',flush=True)
else:
 print('answer '+json.dumps({'role':'assistant','content':'ok'}),flush=True)
''')
                worker.chmod(0o755)
                engine = self.lib.fs_engine_create_model_type(str(worker).encode(), str(self.model).encode(), 14)
                self.assertTrue(engine)
                conversation = None
                try:
                    self.assertEqual(self.lib.fs_engine_probe(engine), 0)
                    conversation = self.lib.fs_conversation_create(engine)
                    self.assertEqual(self.lib.fs_generate_tools(conversation, b'typed', b'hello', b'[{"name":"test"}]', 64), 0)
                    events = []
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline:
                        pointer = self.lib.fs_event_poll(conversation, 100)
                        if pointer:
                            try: event = json.loads(C.string_at(pointer))
                            finally: self.lib.fs_string_free(pointer)
                            events.append(event)
                            if event['type'] == 'done': break
                    self.assertEqual(events[-1]['status'], 'completed', events)
                finally:
                    if conversation: self.assertEqual(self.lib.fs_conversation_destroy(conversation, 1), 0)
                    self.assertEqual(self.lib.fs_engine_destroy(engine), 0)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(len(calls), 2, calls)
                self.assertIn('--probe', calls[0])
                self.assertIn('--serve' if persistent else '--prompt', calls[1])
                self.assertTrue(all(call[call.index('--model-type') + 1] == '14' for call in calls))

    def test_invalid_types_rejected_without_worker(self):
        for value in (-1, 18, 2**31 - 1):
            self.assertFalse(self.lib.fs_engine_create_model_type(b'/missing', str(self.model).encode(), value))


if __name__ == '__main__':
    unittest.main()
