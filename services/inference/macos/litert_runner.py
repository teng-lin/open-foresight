#!/usr/bin/env python3
"""Explicit CPU/GPU LiteRT-LM runner for the native generation worker.

Requires requirements-litert.txt in the selected Python environment. No
downloads, authentication, remote inference or attachment access. Optional
tool calls are delegated over stdin/stdout to the owning application service.
The native worker owns this process group and cancels it on close/timeout.
"""
import argparse
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import sys


def run_tool_conversation(engine, litert_lm, prompt, definitions, budget):
    if not isinstance(definitions, list) or not definitions:
        raise ValueError('Tool definitions must be a nonempty array')

    class DelegatedTool(litert_lm.Tool):
        def __init__(self, definition):
            if not isinstance(definition, dict):
                raise ValueError('Tool definition must be an object')
            self.definition = (definition if 'function' in definition else
                               {'type': 'function', 'function': definition})

        def get_tool_description(self):
            return self.definition

        def execute(self, param):
            raise RuntimeError('Tool execution belongs to the application service')

    with engine.create_conversation(
            system_message='Follow the requested task faithfully. Do not invent facts.',
            tools=[DelegatedTool(d) for d in definitions],
            automatic_tool_calling=False,
            sampler_config=litert_lm.SamplerConfig(top_k=40, top_p=0.9, temperature=0.4, seed=0),
            thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
            filter_channel_content_from_kv_cache=True,
            enable_speculative_decoding=True,
            max_output_tokens=budget) as conversation:
        message = {'role': 'user', 'content': prompt}
        for turn in range(20):
            # Use the pinned 0.18.0 C API through its owned conversation. The
            # public Python Message parser JSON-decodes string arguments, while
            # original Foresight treats them as a verbatim search query.
            optional = conversation._create_optional_args(
                max_output_tokens=budget,
                repetition_penalty_config=litert_lm.RepetitionPenaltyConfig(repetition_penalty=1.05))
            try:
                response = conversation._lib.litert_lm_conversation_send_message(
                    conversation._ptr, json.dumps(message), '{}', optional)
                if not response:
                    raise RuntimeError('Tool generation failed')
                try:
                    raw = conversation._lib.litert_lm_json_response_get_string(response)
                    value = json.loads(raw.decode('utf-8'))
                finally:
                    conversation._lib.litert_lm_json_response_delete(response)
            finally:
                conversation._delete_optional_args(optional)
            if not isinstance(value, dict):
                raise ValueError('Invalid tool generation response')
            calls = value.get('tool_calls')
            if not calls:
                print('answer ' + json.dumps(value, ensure_ascii=False), flush=True)
                return
            if not isinstance(calls, list):
                raise ValueError('Invalid tool calls')
            if turn == 19:
                print('answer ' + json.dumps({'error': 'Max turns reached after tool call detection'}), flush=True)
                return
            print('tool ' + json.dumps(calls, ensure_ascii=False), flush=True)
            line = sys.stdin.readline()
            if not line:
                raise RuntimeError('Tool conversation owner disconnected')
            message = json.loads(line)
            if not isinstance(message, dict) or message.get('role') != 'user':
                raise ValueError('Invalid tool response message')


def run(args):
    if importlib.metadata.version('litert-lm') != '0.18.0':
        raise RuntimeError('This runner requires litert-lm==0.18.0')
    import litert_lm

    if args.check:
        return

    model = Path(args.model).resolve(strict=True)
    if not model.is_file():
        raise ValueError('Model must be a local file')
    cache = Path(os.environ.get('FORESIGHT_LITERT_CACHE', str(model.parent / '.litert-cache'))) / args.backend
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    backend = litert_lm.Backend.GPU() if args.backend == 'gpu' else litert_lm.Backend.CPU(thread_count=4)
    with litert_lm.Engine(str(model), backend=backend,
                         audio_backend=litert_lm.Backend.CPU(thread_count=4),
                         max_num_tokens=4096, cache_dir=str(cache)) as engine:
        if args.probe:
            return
        if args.prompt is None:
            raise ValueError('A prompt is required')
        prompt = args.prompt
        if args.tools:
            if args.json_schema:
                raise ValueError('Tools cannot be combined with a response schema')
            if len(engine.tokenize(prompt)) + args.max_output_tokens + 256 > 4096:
                raise ValueError('Prompt and output reserve exceed the 4096-token context')
            run_tool_conversation(engine, litert_lm, prompt, json.loads(args.tools), args.max_output_tokens)
            return
        schema = None
        if args.json_schema:
            schema = json.loads(args.json_schema)
            if not isinstance(schema, dict):
                raise ValueError('JSON schema must be an object')
            request = schema.pop('x-foresight-grounded-request', None)
            if request is not None:
                # -I deliberately omits script directories from sys.path.
                # Load only the shipped sibling, never a cwd/user module.
                spec = importlib.util.spec_from_file_location(
                    'foresight_grounded', Path(__file__).with_name('grounded_generation.py'))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                result = module.grounded_answer(engine, litert_lm, request, args.max_output_tokens)
                sys.stdout.write(json.dumps(result, ensure_ascii=False))
                sys.stdout.flush()
                return
            prompt += '\nReturn exactly one JSON object with the requested answer and source IDs, without markdown or explanation outside the object.'
        if len(engine.tokenize(prompt)) + args.max_output_tokens + 256 > 4096:
            raise ValueError('Prompt and output reserve exceed the 4096-token context')
        with engine.create_conversation(
                system_message='Follow the requested task faithfully. Do not invent facts.',
                automatic_tool_calling=False,
                sampler_config=litert_lm.SamplerConfig(top_k=40, top_p=0.9, temperature=0.4, seed=0),
                thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
                filter_channel_content_from_kv_cache=True,
                constrained_decoding_config=litert_lm.ConstrainedDecodingConfig(enable=schema is not None, provider=litert_lm.LiteRtLmConstraintProviderType.LL_GUIDANCE if schema is not None else None),
                enable_speculative_decoding=schema is None,
                max_output_tokens=args.max_output_tokens) as conversation:
            text = ''
            for chunk in conversation.send_message_async(
                    prompt, max_output_tokens=args.max_output_tokens,
                    response_format=litert_lm.ResponseFormat.json(schema) if schema is not None else None,
                    repetition_penalty_config=litert_lm.RepetitionPenaltyConfig(repetition_penalty=1.05)):
                if chunk.tool_calls:
                    raise RuntimeError('Model emitted an unsupported tool call')
                part = str(chunk)
                text += part
                if len(text) >= 128 and text[-128:].isspace():
                    raise RuntimeError('Generation entered a whitespace loop')
                sys.stdout.write(part)
                sys.stdout.flush()
            # This API does not expose a reliable finish reason. Conservatively
            # reject output near the token budget instead of publishing it as
            # a complete note. Structured callers also require complete JSON.
            if len(engine.tokenize(text)) >= max(1, args.max_output_tokens - 16):
                raise RuntimeError('Generation reached the output budget; retry with more tokens')
            if not text.strip():
                raise RuntimeError('Generation returned empty text')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model')
    parser.add_argument('--backend', choices=('cpu', 'gpu'),
                        default=os.environ.get('FORESIGHT_LITERT_BACKEND', 'cpu'))
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--probe', action='store_true')
    parser.add_argument('--prompt')
    parser.add_argument('--json-schema')
    parser.add_argument('--tools')
    parser.add_argument('--max-output-tokens', type=int, default=256)
    args = parser.parse_args()
    if args.backend not in ('cpu', 'gpu'):
        parser.error('FORESIGHT_LITERT_BACKEND must be cpu or gpu')
    if not args.check and not args.model:
        parser.error('a local model file is required')
    if not 1 <= args.max_output_tokens <= 3072:
        parser.error('output budget must be between 1 and 3072')
    # Native GPU drivers may write to fd 1. Keep streamed text/JSON on a
    # separate descriptor so driver diagnostics cannot become answer content.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), 'w', buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = protocol
    try:
        run(args)
    except Exception as error:
        print(f'LiteRT-LM runner failed: {error}', file=sys.stdout if args.probe else sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
