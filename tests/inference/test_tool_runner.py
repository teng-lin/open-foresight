"""Exercise the packaged Mac runner protocol without loading a model/library."""
import contextlib
import importlib.util
import io
import json
import queue
import sys
from pathlib import Path
import types
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runner', ROOT / 'services/inference/macos/litert_runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class StreamResponse:
    def __init__(self, chunks):
        self.chunks = chunks


class Lib:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.messages = []
        self.chunks = {}
        self.next_pointer = 10
        self.start_status = 0

    def litert_lm_conversation_send_message_stream(self, ptr, message, context, optional, callback, data):
        self.messages.append(json.loads(message))
        if self.start_status:
            return self.start_status
        response = next(self.responses)
        chunks = response.chunks if isinstance(response, StreamResponse) else [
            (json.dumps(response, ensure_ascii=False), False, None), (None, True, None)]
        for raw, final, error in chunks:
            self.next_pointer += 1
            self.chunks[self.next_pointer] = (raw, final, error)
            callback(data, self.next_pointer)
            # The worker must have copied bytes before callback ownership ends.
            del self.chunks[self.next_pointer]
        return 0

    def litert_lm_stream_chunk_get_text(self, pointer):
        value = self.chunks[pointer][0]
        return value.encode() if value is not None else None

    def litert_lm_stream_chunk_is_final(self, pointer):
        return self.chunks[pointer][1]

    def litert_lm_stream_chunk_get_error(self, pointer):
        value = self.chunks[pointer][2]
        return value.encode() if value is not None else None


class Conversation:
    def __init__(self, responses):
        self._lib = Lib(responses)
        self._ptr = 1
        self.options = []
        self.deleted_options = []
        self.closed = False

    def __enter__(self): return self
    def __exit__(self, *args): self.closed = True
    def _create_optional_args(self, **kwargs):
        self.options.append(kwargs)
        return 2
    def _delete_optional_args(self, ptr): self.deleted_options.append(ptr)


class Engine:
    def __init__(self, responses):
        self.conversation = Conversation(responses)
        self.creations = 0

    def create_conversation(self, **kwargs):
        self.creations += 1
        self.config = kwargs
        return self.conversation

    def tokenize(self, text): return []


def options(**kwargs): return kwargs
API = types.SimpleNamespace(Tool=type('Tool', (), {}), SamplerConfig=options,
    ThinkingConfig=options, RepetitionPenaltyConfig=options)


class RawDetectorLib:
    def __init__(self):
        self.calls = []
        self.next_id = 10
        self.prefill_status = 0
        self.candidates = 1
        self.text = 'When is the review?'.encode()

    def __getattr__(self, name):
        def invoke(*args):
            self.calls.append((name, args))
            if name.endswith('_create') or name == 'litert_lm_engine_create_session':
                self.next_id += 1
                return self.next_id
            if name == 'litert_lm_session_run_prefill':
                return self.prefill_status
            if name == 'litert_lm_session_run_decode':
                self.next_id += 1
                return self.next_id
            if name == 'litert_lm_responses_get_num_candidates':
                return self.candidates
            if name == 'litert_lm_responses_get_response_text_at':
                return self.text
        return invoke


class RawDetectorTest(unittest.TestCase):
    def test_raw_input_sampler_and_owned_buffers(self):
        lib = RawDetectorLib()
        engine = types.SimpleNamespace(_lib=lib, _engine_ptr=5)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            runner.run_query_detector(engine, ' <ctrl1>中文?\0discard')
        self.assertEqual(output.getvalue(), 'When is the review?')
        calls = dict(lib.calls)
        self.assertEqual(calls['litert_lm_input_data_create'][1:],
                         (' <ctrl1>中文?'.encode(), len(' <ctrl1>中文?'.encode())))
        self.assertEqual(calls['litert_lm_sampler_params_create'], (2,))
        self.assertEqual(calls['litert_lm_sampler_params_set_top_p'][1], 1.0)
        self.assertEqual(calls['litert_lm_sampler_params_set_top_k'][1], 1)
        self.assertEqual(calls['litert_lm_sampler_params_set_temperature'][1], 0.3)
        self.assertFalse(calls['litert_lm_session_config_set_apply_prompt_template'][1])
        self.assertEqual(calls['litert_lm_session_config_set_max_output_tokens'][1], 512)
        self.assertEqual([n for n, _ in lib.calls if n.endswith('_delete')], [
            'litert_lm_responses_delete', 'litert_lm_input_data_delete',
            'litert_lm_session_delete', 'litert_lm_sampler_params_delete',
            'litert_lm_session_config_delete'])

    def test_prefill_failure_releases_all_created_native_objects(self):
        lib = RawDetectorLib()
        lib.prefill_status = 1
        with self.assertRaisesRegex(RuntimeError, 'prefill failed'):
            runner.run_query_detector(types.SimpleNamespace(_lib=lib, _engine_ptr=5), ' <ctrl1>Question?')
        self.assertFalse(any(n == 'litert_lm_session_run_decode' for n, _ in lib.calls))
        self.assertEqual(sum(n.endswith('_delete') for n, _ in lib.calls), 4)

    def test_empty_output_is_valid_but_missing_candidate_is_an_error(self):
        lib = RawDetectorLib()
        lib.text = b''
        engine = types.SimpleNamespace(_lib=lib, _engine_ptr=5)
        with contextlib.redirect_stdout(io.StringIO()):
            runner.run_query_detector(engine, ' <ctrl1>Statement.')
        lib.candidates = 0
        with self.assertRaisesRegex(RuntimeError, 'no candidates'):
            runner.run_query_detector(engine, ' <ctrl1>Statement.')
        lib.candidates = 1
        lib.text = None
        with self.assertRaisesRegex(RuntimeError, 'null candidate'):
            runner.run_query_detector(engine, ' <ctrl1>Statement.')


class ToolRunnerTest(unittest.TestCase):
    def test_stream_emits_unicode_before_final_and_reads_control_only_after_final(self):
        ready = threading.Event()
        finished = threading.Event()

        class LiveOutput(io.StringIO):
            def flush(self):
                if self.getvalue().startswith('delta '):
                    ready.set()

        class Control(io.StringIO):
            def readline(self, *args):
                self_test.assertTrue(finished.is_set())
                return super().readline(*args)

        class AsyncLib(Lib):
            def litert_lm_conversation_send_message_stream(self, ptr, message, context, optional, callback, data):
                self.messages.append(json.loads(message))
                def emit(value, final=False, error=None):
                    self.next_pointer += 1
                    pointer = self.next_pointer
                    self.chunks[pointer] = (json.dumps(value, ensure_ascii=False) if value is not None else None, final, error)
                    callback(data, pointer)
                    del self.chunks[pointer]
                def produce():
                    emit({'role': 'assistant', 'content': [{'type': 'text', 'text': '蓝🧭\n'}]})
                    if not ready.wait(2):
                        emit(None, True, 'Preview was buffered until completion')
                        return
                    emit({'content': [{'type': 'text', 'text': 'Complete'}]})
                    finished.set()
                    emit({'usage': {'output_tokens': 2}}, True)
                self.thread = threading.Thread(target=produce)
                self.thread.start()
                return 0

        self_test = self
        engine = Engine([])
        engine.conversation._lib = AsyncLib([])
        output = LiveOutput()
        try:
            with patch('sys.stdin', Control('{"finish":true}\n')), contextlib.redirect_stdout(output):
                runner.run_tool_conversation(engine, API, 'Question', {
                    'tools': [{'name': 'google_search'}], 'system_message': 'Instructions',
                    'delegate_tool_detection': True}, 256)
        finally:
            ready.set()
            engine.conversation._lib.thread.join(timeout=3)
        frames = [(line.split(' ', 1)[0], json.loads(line.split(' ', 1)[1])) for line in output.getvalue().splitlines()]
        self.assertEqual([kind for kind, _ in frames], ['delta', 'delta', 'delta', 'model', 'answer'])
        self.assertEqual(frames[-1][1], {
            'role': 'assistant', 'content': [{'type': 'text', 'text': '蓝🧭\nComplete'}],
            'usage': {'output_tokens': 2}})
        self.assertEqual(engine.conversation.deleted_options, [2])
        self.assertTrue(engine.conversation.closed)

    def test_stream_errors_and_start_failure_release_options_without_final_answer(self):
        for response, start_status, expected in [
                (StreamResponse([(None, False, 'CANCELLED')]), 0, 'CANCELLED'),
                ({'content': 'unused'}, 1, 'failed to start'),
                (StreamResponse([('123', True, None)]), 0, 'Invalid streamed')]:
            engine = Engine([response])
            engine.conversation._lib.start_status = start_status
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                with self.assertRaisesRegex((RuntimeError, ValueError), expected):
                    runner.run_tool_conversation(engine, API, 'Question', [{'name': 'google_search'}], 256)
            self.assertNotIn('answer ', output.getvalue())
            self.assertEqual(engine.conversation.deleted_options, [2])
            self.assertTrue(engine.conversation.closed)
            self.assertIsNotNone(engine.conversation._current_callback)

    def test_stream_merges_channels_and_preserves_text_part_metadata_and_calls(self):
        calls = [{'function': {'name': 'google_search', 'arguments': '{"query":"nested"}'}}]
        response = StreamResponse([
            (json.dumps({'role': 'assistant', 'content': [{'type': 'text', 'text': 'A', 'language': 'en'}], 'channels': {'analysis': 'first'}}), False, None),
            (json.dumps({'content': [{'type': 'text', 'text': 'B', 'language': 'en'}], 'channels': {'analysis': ' second'}}), False, None),
            (json.dumps({'tool_calls': calls}), True, None),
        ])
        final = {'role': 'assistant', 'content': 'Done'}
        engine, frames = self.run_protocol([response, final], '{"role":"user","content":"Result"}\n')
        self.assertEqual([kind for kind, _ in frames], ['delta', 'delta', 'delta', 'tool', 'delta', 'answer'])
        self.assertEqual(frames[3][1], calls)
        self.assertEqual(frames[-1][1], final)
        self.assertEqual(len(engine.conversation.deleted_options), 2)
        direct = Conversation([response])
        with direct, contextlib.redirect_stdout(io.StringIO()):
            assembled = runner.stream_tool_response(direct, API, {'role': 'user', 'content': 'Question'}, 256)
        self.assertEqual(assembled['channels'], {'analysis': 'first second'})
        self.assertEqual(assembled['content'], [{'type': 'text', 'text': 'AB', 'language': 'en'}])
        self.assertEqual(assembled['tool_calls'], calls)

    def test_chat_input_does_not_reserve_the_entire_output_budget(self):
        engine = Engine([{'role': 'assistant', 'content': 'Short answer'}])
        engine.tokenize = lambda text: list(text)
        with contextlib.redirect_stdout(io.StringIO()):
            runner.run_tool_conversation(engine, API, 'X' * 3500, [{'name': 'google_search'}], 1024)
        self.assertEqual(engine.creations, 1)
        self.assertEqual(engine.config['max_output_tokens'], 1024)

    def test_plain_summary_conversation_has_no_tools_history_or_system_preface(self):
        engine = Engine([{'role': 'assistant', 'content': 'Memo'}])
        output = io.StringIO()
        with patch('sys.stdin', io.StringIO('{"finish":true}\n')), contextlib.redirect_stdout(output):
            runner.run_tool_conversation(engine, API, 'Summary prompt', {
                'tools': [], 'system_message': '', 'delegate_tool_detection': True}, 1024)
        self.assertEqual(engine.config['tools'], [])
        self.assertEqual(engine.config['system_message'], '')
        self.assertIsNone(engine.config['messages'])
        self.assertEqual(engine.conversation._lib.messages, [{'role': 'user', 'content': 'Summary prompt'}])
        self.assertTrue(output.getvalue().endswith('answer {"role": "assistant", "content": "Memo"}\n'))

    def test_history_is_installed_as_messages_without_flattening_or_decoding(self):
        history = [
            {'role': 'user', 'content': [{'type': 'text', 'text': 'Earlier query 中文'}]},
            {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Earlier answer [Source:8]'}]},
        ]
        engine = Engine([{'role': 'assistant', 'content': 'Next answer'}])
        with contextlib.redirect_stdout(io.StringIO()):
            runner.run_tool_conversation(engine, API, 'New query', {
                'tools': [{'name': 'google_search'}], 'system_message': 'Instructions',
                'messages': history}, 256)
        self.assertEqual(engine.config['messages'], history)
        self.assertEqual(engine.conversation._lib.messages, [{'role': 'user', 'content': 'New query'}])
        engine.tokenize = lambda text: list(text)
        history[0]['content'][0]['text'] = 'X' * 4096
        with self.assertRaisesRegex(ValueError, '4096-token context'):
            runner.run_tool_conversation(engine, API, 'New query', {
                'tools': [{'name': 'google_search'}], 'system_message': 'Instructions',
                'messages': history}, 256)

    def test_delegated_detection_retains_conversation_and_waits_for_finish(self):
        value = {'content': [{'type': 'text', 'text': 'textual tool request'}]}
        answer = {'content': [{'type': 'text', 'text': 'Final answer'}]}
        message = {'role': 'user', 'content': 'Tool result'}
        engine = Engine([value, answer])
        output = io.StringIO()
        controls = json.dumps({'message': message}) + '\n' + json.dumps({'finish': True}) + '\n'
        with patch('sys.stdin', io.StringIO(controls)), contextlib.redirect_stdout(output):
            runner.run_tool_conversation(engine, API, 'Question', {
                'tools': [{'name': 'google_search'}], 'system_message': 'Instructions',
                'delegate_tool_detection': True}, 256)
        frames = [(line.split(' ', 1)[0], json.loads(line.split(' ', 1)[1])) for line in output.getvalue().splitlines()]
        self.assertEqual(frames, [('delta', value), ('model', value), ('delta', answer), ('model', answer), ('answer', answer)])
        self.assertEqual(engine.conversation._lib.messages, [{'role': 'user', 'content': 'Question'}, message])
        self.assertEqual(engine.creations, 1)
        self.assertTrue(engine.conversation.closed)

    def test_delegated_error_finishes_without_another_generation(self):
        engine = Engine([{'tool_calls': [{'function': {'name': 'google_search'}}]}])
        output = io.StringIO()
        with patch('sys.stdin', io.StringIO('{"finish":true,"error":"Max turns reached after tool call detection"}\n')), contextlib.redirect_stdout(output):
            runner.run_tool_conversation(engine, API, 'Question', {
                'tools': [{'name': 'google_search'}], 'system_message': 'Instructions',
                'delegate_tool_detection': True}, 256)
        self.assertIn('Max turns reached after tool call detection', output.getvalue())
        self.assertEqual(len(engine.conversation._lib.messages), 1)

    def test_system_instructions_are_distinct_from_the_user_message(self):
        engine = Engine([{'role': 'assistant', 'content': 'Answer'}])
        request = {'tools': [{'name': 'google_search'}], 'system_message': 'Exact original instructions'}
        with contextlib.redirect_stdout(io.StringIO()):
            runner.run_tool_conversation(engine, API, 'Question', request, 256)
        self.assertEqual(engine.config['system_message'], request['system_message'])
        self.assertEqual(engine.conversation._lib.messages, [{'role': 'user', 'content': 'Question'}])

    def test_system_and_tool_tokens_count_toward_context_limit(self):
        engine = Engine([])
        engine.tokenize = lambda text: list(text)
        with self.assertRaisesRegex(ValueError, '4096-token context'):
            runner.run_tool_conversation(engine, API, 'Question', {
                'tools': [{'name': 'google_search'}], 'system_message': 'X' * 4096}, 256)
        self.assertEqual(engine.creations, 0)

    def run_protocol(self, responses, replies):
        engine = Engine(responses)
        output = io.StringIO()
        with patch('sys.stdin', io.StringIO(replies)), contextlib.redirect_stdout(output):
            runner.run_tool_conversation(engine, API, 'Question', [{'name': 'google_search'}], 256)
        frames = [(line.split(' ', 1)[0], json.loads(line.split(' ', 1)[1])) for line in output.getvalue().splitlines()]
        return engine, frames

    def test_retains_one_conversation_and_string_arguments_without_json_decoding(self):
        calls = [{'function': {'name': 'google_search', 'arguments': '{"query":"nested"}'}}]
        reply = {'role': 'user', 'content': [{'type': 'text', 'text': 'Result 中文'}]}
        answer = {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Answer [Source:1]'}]}
        engine, frames = self.run_protocol([{'tool_calls': calls}, answer], json.dumps(reply) + '\n')
        self.assertEqual(frames, [('delta', {'tool_calls': calls}), ('tool', calls), ('delta', answer), ('answer', answer)])
        self.assertEqual(engine.creations, 1)
        self.assertFalse(engine.config['automatic_tool_calling'])
        self.assertEqual(engine.config['tools'][0].get_tool_description(), {'type': 'function', 'function': {'name': 'google_search'}})
        self.assertEqual(engine.conversation._lib.messages, [{'role': 'user', 'content': 'Question'}, reply])
        self.assertEqual(len(engine.conversation.deleted_options), 2)
        self.assertTrue(engine.conversation.closed)

    def test_twentieth_turn_does_not_execute_another_tool_batch(self):
        calls = [{'function': {'name': 'google_search', 'arguments': {'query': 'q'}}}]
        replies = (json.dumps({'role': 'user', 'content': 'result'}) + '\n') * 19
        engine, frames = self.run_protocol([{'tool_calls': calls}] * 20, replies)
        self.assertEqual([kind for kind, _ in frames], ['delta', 'tool'] * 19 + ['delta', 'answer'])
        self.assertEqual(frames[-1][1], {'error': 'Max turns reached after tool call detection'})
        self.assertEqual(len(engine.conversation._lib.messages), 20)
        self.assertEqual(len(engine.conversation.deleted_options), 20)

    def test_owner_disconnect_and_invalid_reply_close_conversation(self):
        for reply in ['', '{}\n']:
            engine = Engine([{'tool_calls': [{'function': {'name': 'google_search'}}]}])
            with patch('sys.stdin', io.StringIO(reply)), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises((RuntimeError, ValueError)):
                    runner.run_tool_conversation(engine, API, 'Question', [{'name': 'google_search'}], 256)
            self.assertTrue(engine.conversation.closed)
            self.assertEqual(len(engine.conversation.deleted_options), 1)



class QueueInput:
    def __init__(self): self.lines = queue.Queue()
    def send(self, text): self.lines.put(text + '\n')
    def __iter__(self): return self
    def __next__(self):
        line = self.lines.get(timeout=5)
        if line is None: raise StopIteration
        return line


class QueueOutput:
    def __init__(self): self.lines, self.pending = queue.Queue(), ''
    def write(self, text):
        self.pending += text
        while '\n' in self.pending:
            line, self.pending = self.pending.split('\n', 1)
            self.lines.put(line)
    def flush(self): pass
    def read(self): return self.lines.get(timeout=5)


class PersistentTest(unittest.TestCase):
    definitions = {'tools': [{'name': 'search'}], 'system_message': 'System',
                   'delegate_tool_detection': True, 'messages': []}

    def start(self, engine, cache=None):
        input_stream, output = QueueInput(), QueueOutput()
        worker = runner.PersistentWorker(engine, API, input_stream, output, cache)
        thread = threading.Thread(target=worker.serve)
        thread.start()
        self.assertEqual(output.read(), 'ready 1')
        self.addCleanup(lambda: (input_stream.send('shutdown'), thread.join(5)))
        return input_stream, output, thread

    def request(self, input_stream, token, definitions=None):
        input_stream.send('generate ' + str(token) + ' ' + json.dumps({
            'prompt': 'Question', 'tools': definitions or self.definitions, 'max_output_tokens': 256}))

    def finish(self, input_stream, output, token):
        self.assertTrue(output.read().startswith(str(token) + ' delta '))
        self.assertTrue(output.read().startswith(str(token) + ' model '))
        # A stale reply must never resolve this request's control wait.
        input_stream.send('reply ' + str(token - 1) + ' {"finish":true,"error":"stale"}')
        input_stream.send('reply ' + str(token) + ' {"finish":true}')
        self.assertTrue(output.read().startswith(str(token) + ' answer '))
        self.assertEqual(output.read(), str(token) + ' done completed')

    def test_reuses_only_matching_empty_history_base_and_closes_before_done(self):
        events = []
        class CloneFunction:
            def __call__(self, pointer):
                events.append(('clone', pointer))
                return pointer + 100
        clone = CloneFunction()
        class TrackingConversation(Conversation):
            def __init__(self, lib, ptr, **kwargs):
                super().__init__([{'role': 'assistant', 'content': 'Answer'}])
                self._ptr = ptr
                self._lib.litert_lm_conversation_clone = clone
            def close(self):
                if self.closed: raise AssertionError('double close')
                events.append(('close', self._ptr)); self.closed = True
        class TrackingEngine:
            def __init__(self): self.creations = []
            def tokenize(self, text): return []
            def create_conversation(self, **config):
                self.creations.append(config)
                return TrackingConversation(None, len(self.creations))
        engine = TrackingEngine()
        module = types.ModuleType('litert_lm.conversation')
        module.Conversation = TrackingConversation
        with patch.dict(sys.modules, {'litert_lm.conversation': module}):
            input_stream, output, thread = self.start(engine)
            self.request(input_stream, 1); self.finish(input_stream, output, 1)
            self.assertIn(('close', 101), events)
            self.request(input_stream, 2); self.finish(input_stream, output, 2)
            self.assertEqual(len(engine.creations), 1)
            history = dict(self.definitions, messages=[{'role': 'user', 'content': 'Past'}])
            self.request(input_stream, 3, history); self.finish(input_stream, output, 3)
            summary = dict(self.definitions, tools=[], system_message='')
            self.request(input_stream, 4, summary); self.finish(input_stream, output, 4)
            self.request(input_stream, 5); self.finish(input_stream, output, 5)
            self.assertEqual(len(engine.creations), 3)
            self.assertEqual(sum(event == ('clone', 1) for event in events), 3)
            self.assertNotIn(('close', 1), events)
            changed = dict(self.definitions, system_message='Different')
            self.request(input_stream, 6, changed); self.finish(input_stream, output, 6)
            self.assertIn(('close', 1), events)
            input_stream.send('shutdown'); thread.join(5)
            self.assertFalse(thread.is_alive())
            self.assertIn(('close', 4), events)
            self.assertEqual(clone.argtypes, [runner.ctypes.c_void_p])
            self.assertIs(clone.restype, runner.ctypes.c_void_p)

    def test_cancel_tool_wait_disconnect_and_failure_allow_next_request(self):
        closed = []
        class Cache:
            def acquire(self, *args):
                conversation = Conversation([{'role': 'assistant', 'content': 'Answer'}])
                conversation.close = lambda: closed.append(True)
                conversation._lib.litert_lm_conversation_cancel_process = lambda ptr: None
                return conversation
            def close(self): closed.append('base')
        input_stream, output, thread = self.start(Engine([]), Cache())
        self.request(input_stream, 1)
        self.assertTrue(output.read().startswith('1 delta ')); self.assertTrue(output.read().startswith('1 model '))
        input_stream.send('cancel 1')
        self.assertEqual(output.read(), '1 done cancelled')
        self.assertEqual(closed, [True])
        input_stream.send('generate 2 {"prompt":null}')
        self.assertTrue(output.read().startswith('2 error ')); self.assertEqual(output.read(), '2 done failed')
        self.request(input_stream, 3); self.finish(input_stream, output, 3)
        self.request(input_stream, 4)
        self.assertTrue(output.read().startswith('4 delta ')); self.assertTrue(output.read().startswith('4 model '))
        input_stream.lines.put(None)
        self.assertEqual(output.read(), '4 done cancelled')
        thread.join(5)
        self.assertFalse(thread.is_alive()); self.assertEqual(closed, [True, True, True, 'base'])

    def test_cancel_native_stream_waits_for_final_before_delete(self):
        started, cancelled, finalized = threading.Event(), threading.Event(), threading.Event()
        events = []
        class AsyncLib(Lib):
            def litert_lm_conversation_send_message_stream(self, ptr, message, context, optional, callback, data):
                def produce():
                    started.set(); cancelled.wait(5)
                    self.chunks[50] = (None, True, 'CANCELLED')
                    finalized.set(); callback(data, 50)
                threading.Thread(target=produce).start()
                return 0
            def litert_lm_conversation_cancel_process(self, ptr):
                events.append('cancel'); cancelled.set()
        conversation = Conversation([]); conversation._lib = AsyncLib([])
        def close():
            self.assertTrue(finalized.is_set()); events.append('close')
        conversation.close = close
        cache = types.SimpleNamespace(acquire=lambda *args: conversation, close=lambda: None)
        input_stream, output, thread = self.start(Engine([]), cache)
        self.request(input_stream, 1); self.assertTrue(started.wait(5))
        input_stream.send('cancel 1')
        self.assertEqual(output.read(), '1 done cancelled')
        self.assertEqual(events[-1], 'close')
        self.assertTrue(events[:-1] and all(event == 'cancel' for event in events[:-1]))

if __name__ == '__main__': unittest.main()
