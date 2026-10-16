#!/usr/bin/env python3
"""Opt-in real helper retrieval -> owned native generator -> cited answer probe."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile
import time
import grpc
from evaluate_models import PACKAGE, messages

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['helper', 'embedding-model', 'native', 'runner', 'generation-model', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    classes = messages()
    with tempfile.TemporaryDirectory(prefix='foresight-pipeline-') as temp:
        socket = str(Path(temp) / 'helper.sock')
        process = subprocess.Popen([str(args.helper.resolve()), socket, str(Path(temp) / 'storage')],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        channel = grpc.insecure_channel('unix:' + socket)
        library = ctypes.CDLL(str(args.native.resolve()))
        library.fs_engine_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        library.fs_engine_create.restype = ctypes.c_void_p
        library.fs_conversation_create.argtypes = [ctypes.c_void_p]
        library.fs_conversation_create.restype = ctypes.c_void_p
        library.fs_generate.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        library.fs_event_poll.argtypes = [ctypes.c_void_p, ctypes.c_int]
        library.fs_event_poll.restype = ctypes.c_void_p
        library.fs_string_free.argtypes = [ctypes.c_void_p]
        library.fs_conversation_destroy.argtypes = [ctypes.c_void_p, ctypes.c_int]
        library.fs_engine_destroy.argtypes = [ctypes.c_void_p]
        engine = conversation = None
        try:
            grpc.channel_ready_future(channel).result(timeout=15)
            def call(method, request, response, **fields):
                rpc = channel.unary_unary('/' + PACKAGE + '.RagService/' + method,
                    request_serializer=lambda value: value.SerializeToString(),
                    response_deserializer=classes[response].FromString)
                return rpc(classes[request](**fields), timeout=300)
            configured = call('UpdateModelPaths', 'UpdateModelPathsRequest', 'UpdateModelPathsResponse',
                              embedding_model_path=str(args.embedding_model.resolve()))
            assert configured.success, configured.error_message
            source = 'The Foresight Linux prototype will be released on November 12. Sam is responsible for the release.'
            indexed = call('IndexDocument', 'IndexRequest', 'IndexResponse', document_id='release-source',
                           content=source, user_id='local_user', max_tokens_per_chunk=480, mime_type='text/plain')
            assert indexed.success, indexed.error_message
            retrieved = call('RetrieveContext', 'RetrieveRequest', 'RetrieveResponse',
                             query={'text_query': 'When will the prototype be released?'},
                             max_results=1, min_similarity_score=0,
                             allowed_document_ids=['release-source'])
            assert retrieved.chunks and retrieved.chunks[0].document_id == 'release-source'
            excerpt = retrieved.chunks[0].text
            # The evaluation explicitly identifies Qwen ChatML preprocessing.
            # It is a Linux fixture, not recovered Foresight prompt behavior.
            prompt = ('<|im_start|>system\nAnswer only from the context. Include the citation [S1] in your answer.'
                      '<|im_end|>\n<|im_start|>user\n'
                      f'Context [S1]: {excerpt}\nWhen will the prototype be released? Cite [S1].'
                      '<|im_end|>\n<|im_start|>assistant\n')
            engine = library.fs_engine_create(str(args.runner.resolve()).encode(),
                                              str(args.generation_model.resolve()).encode())
            assert engine, 'Native engine configuration failed'
            conversation = library.fs_conversation_create(engine)
            assert conversation
            started = time.perf_counter()
            assert library.fs_generate(conversation, b'pipeline-v1', prompt.encode()) == 0
            events = []
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                owned = library.fs_event_poll(conversation, 100)
                if not owned:
                    continue
                try:
                    event = json.loads(ctypes.string_at(owned))
                finally:
                    library.fs_string_free(owned)
                events.append(event)
                if event['type'] == 'done':
                    break
            elapsed = time.perf_counter() - started
            assert events and events[-1]['type'] == 'done' and events[-1]['status'] == 'completed', events
            assert [event['sequence'] for event in events] == list(range(len(events)))
            assert sum(event['type'] == 'done' for event in events) == 1
            assert not library.fs_event_poll(conversation, 100), 'Event after done'
            answer = ''.join(event.get('text', '') for event in events if event['type'] == 'delta')
            quality_passed = 'november 12' in answer.casefold() and '[S1]' in answer
            report = {'fixture': 'linux-cited-pipeline-v1', 'authority': 'Linux evaluation; not Mac parity',
                      'question': 'When will the prototype be released?', 'source_id': 'release-source',
                      'source_revision': 1, 'retrieved_excerpt': excerpt, 'citation': 'S1', 'answer': answer,
                      'quality_passed': quality_passed,
                      'latency_seconds': elapsed, 'terminal_status': events[-1]['status'],
                      'ordered_event_count': len(events), 'exactly_one_terminal': True,
                      'no_events_after_terminal': True,
                      'model_sha256': hashlib.sha256(args.generation_model.read_bytes()).hexdigest(),
                      'runner_sha256': hashlib.sha256(args.runner.read_bytes()).hexdigest(),
                      'backend': 'llama.cpp CPU completion worker', 'prompt_format': 'Qwen ChatML',
                      'peak_worker_rss_kib': resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
                      'limitations': ['One factual prompt; does not establish general answer quality',
                                      'Runtime loads model per request; original LiteRT equivalence unclaimed']}
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + '\n')
            assert quality_passed, f'Quality failure recorded at {args.output}: {answer}'
            print(json.dumps({'answer': answer, 'latency_seconds': elapsed, 'output': str(args.output)}))
        finally:
            if conversation:
                library.fs_conversation_destroy(conversation, 1)
            if engine:
                library.fs_engine_destroy(engine)
            channel.close()
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

if __name__ == '__main__':
    main()
