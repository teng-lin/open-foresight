"""Exercise the packaged Mac runner protocol without loading a model/library."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runner', ROOT / 'services/inference/macos/litert_runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Lib:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.messages = []
        self.deleted = 0

    def litert_lm_conversation_send_message(self, ptr, message, context, optional):
        self.messages.append(json.loads(message))
        self.response = next(self.responses)
        return 7

    def litert_lm_json_response_get_string(self, ptr):
        return json.dumps(self.response, ensure_ascii=False).encode()

    def litert_lm_json_response_delete(self, ptr):
        self.deleted += 1


class Conversation:
    def __init__(self, responses):
        self._lib = Lib(responses)
        self._ptr = 1
        self.options = []
        self.closed = False

    def __enter__(self): return self
    def __exit__(self, *args): self.closed = True
    def _create_optional_args(self, **kwargs):
        self.options.append(kwargs)
        return 2
    def _delete_optional_args(self, ptr): pass


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


class ToolRunnerTest(unittest.TestCase):
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
        self.assertEqual(frames, [('model', value), ('model', answer), ('answer', answer)])
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
        self.assertEqual(frames, [('tool', calls), ('answer', answer)])
        self.assertEqual(engine.creations, 1)
        self.assertFalse(engine.config['automatic_tool_calling'])
        self.assertEqual(engine.config['tools'][0].get_tool_description(), {'type': 'function', 'function': {'name': 'google_search'}})
        self.assertEqual(engine.conversation._lib.messages, [{'role': 'user', 'content': 'Question'}, reply])
        self.assertEqual(engine.conversation._lib.deleted, 2)
        self.assertTrue(engine.conversation.closed)

    def test_twentieth_turn_does_not_execute_another_tool_batch(self):
        calls = [{'function': {'name': 'google_search', 'arguments': {'query': 'q'}}}]
        replies = (json.dumps({'role': 'user', 'content': 'result'}) + '\n') * 19
        engine, frames = self.run_protocol([{'tool_calls': calls}] * 20, replies)
        self.assertEqual([kind for kind, _ in frames], ['tool'] * 19 + ['answer'])
        self.assertEqual(frames[-1][1], {'error': 'Max turns reached after tool call detection'})
        self.assertEqual(len(engine.conversation._lib.messages), 20)
        self.assertEqual(engine.conversation._lib.deleted, 20)

    def test_owner_disconnect_and_invalid_reply_close_conversation(self):
        for reply in ['', '{}\n']:
            engine = Engine([{'tool_calls': [{'function': {'name': 'google_search'}}]}])
            with patch('sys.stdin', io.StringIO(reply)), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises((RuntimeError, ValueError)):
                    runner.run_tool_conversation(engine, API, 'Question', [{'name': 'google_search'}], 256)
            self.assertTrue(engine.conversation.closed)
            self.assertEqual(engine.conversation._lib.deleted, 1)


if __name__ == '__main__': unittest.main()
