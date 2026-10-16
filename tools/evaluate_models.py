#!/usr/bin/env python3
"""Opt-in semantic retrieval probe through the real private-socket helper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
from google.protobuf import json_format
import grpc

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'research.xeno.labs.foresight.launch_agent.proto'
CORPUS = {
    'release': 'The Foresight Linux prototype release is scheduled for November 12. Sam owns the release checklist.',
    'meeting': 'The weekly design meeting starts at 10 AM on Tuesday. Priya will prepare the accessibility review.',
    'travel': 'The team travel budget is 2400 dollars. All receipts must be submitted to Morgan by Friday.',
    'storage': 'The retrieval helper stores document metadata in SQLite and searches local embedding vectors.',
}
QUERIES = [('When will the prototype be released?', 'release'),
           ('Who prepares the accessibility review?', 'meeting'),
           ('How much money is available for travel?', 'travel'),
           ('Where is document metadata persisted?', 'storage')]

def messages():
    pool = descriptor_pool.DescriptorPool()
    pool.Add(descriptor_pb2.FileDescriptorProto.FromString(
        (ROOT / 'proto/rag/rag_service.descriptor.pb').read_bytes()))
    return {name: message_factory.GetMessageClass(pool.FindMessageTypeByName(PACKAGE + '.' + name))
            for name in ['PingRequest', 'PingResponse', 'UpdateModelPathsRequest',
                         'UpdateModelPathsResponse', 'IndexRequest', 'IndexResponse',
                         'RetrieveRequest', 'RetrieveResponse',
                         'DeleteRequest', 'DeleteResponse', 'ComputeEmbeddingRequest', 'ComputeEmbeddingResponse']}

def asset_manifest(path):
    files = []
    for file in ([path] if path.is_file() else sorted(path.rglob('*'))):
        if file.is_file() and '.cache' not in file.parts:
            digest = hashlib.sha256()
            with file.open('rb') as stream:
                for data in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(data)
            files.append({'path': (file.name if path.is_file() else str(file.relative_to(path))), 'bytes': file.stat().st_size,
                          'sha256': digest.hexdigest()})
    return files

def control_snapshot(channel):
    with tempfile.TemporaryDirectory() as temp:
        output = Path(temp) / 'control.pb'
        subprocess.run(['protoc', f'-I{ROOT / "proto/linux"}', f'--descriptor_set_out={output}',
                        'helper_control.proto'], check=True)
        pool = descriptor_pool.DescriptorPool()
        pool.Add(descriptor_pb2.FileDescriptorSet.FromString(output.read_bytes()).file[0])
        state = message_factory.GetMessageClass(pool.FindMessageTypeByName('foresight.linux.control.v1.State'))
        rpc = channel.unary_unary('/foresight.linux.control.v1.HelperControl/GetState',
                                 request_serializer=lambda _: b'', response_deserializer=state.FromString)
        return json_format.MessageToDict(rpc(None, timeout=10), preserving_proto_field_name=True)

def process_memory(pid):
    """Sample current/peak resident memory of helper and its persistent model worker."""
    identities = [pid]
    children = set()
    for file in Path(f'/proc/{pid}/task').glob('*/children'):
        try:
            children.update(int(child) for child in file.read_text().split())
        except FileNotFoundError:
            pass  # A request thread can retire during the sample.
    identities.extend(sorted(children))
    result = []
    for identity in identities:
        status = Path(f'/proc/{identity}/status')
        if status.exists():
            rows = dict(line.split(':', 1) for line in status.read_text().splitlines() if ':' in line)
            result.append({'pid': identity, 'name': rows.get('Name', '').strip(),
                           'rss': rows.get('VmRSS', '').strip(), 'peak_rss': rows.get('VmHWM', '').strip()})
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--embedding-model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    model = args.embedding_model.resolve()
    assert (model.is_dir() or model.is_file()) and not str(model).startswith('test:'), 'Real local asset required'
    classes = messages()
    with tempfile.TemporaryDirectory(prefix='foresight-eval-') as temp:
        socket = str(Path(temp) / 'helper.sock')
        log = Path(temp) / 'helper.log'
        with log.open('w') as output:
            process = subprocess.Popen([str(args.helper.resolve()), socket, str(Path(temp) / 'storage')],
                                       stdout=output, stderr=output)
            channel = grpc.insecure_channel('unix:' + socket)
            try:
                grpc.channel_ready_future(channel).result(timeout=20)
                def call(method, request, response, **fields):
                    rpc = channel.unary_unary('/' + PACKAGE + '.RagService/' + method,
                        request_serializer=lambda value: value.SerializeToString(),
                        response_deserializer=classes[response].FromString)
                    return rpc(classes[request](**fields), timeout=300)
                assert call('Ping', 'PingRequest', 'PingResponse').version == '1.0.3'
                started = time.perf_counter()
                configured = call('UpdateModelPaths', 'UpdateModelPathsRequest', 'UpdateModelPathsResponse',
                                  embedding_model_path=str(model))
                assert configured.success, configured.error_message
                initialization = time.perf_counter() - started
                for identity, text in CORPUS.items():
                    result = call('IndexDocument', 'IndexRequest', 'IndexResponse',
                                  document_id=identity, content=text, user_id='local_user',
                                  max_tokens_per_chunk=480, chunk_overlap=0, mime_type='text/plain')
                    assert result.success, result.error_message
                results = []
                for query, expected in QUERIES:
                    started = time.perf_counter()
                    reply = call('RetrieveContext', 'RetrieveRequest', 'RetrieveResponse',
                                 query={'text_query': query}, max_results=2, min_similarity_score=-1)
                    hits = [{'document_id': hit.document_id, 'text': hit.text,
                             'score': hit.relevance_score} for hit in reply.chunks]
                    results.append({'query': query, 'expected_document': expected,
                                    'top1_correct': bool(hits) and hits[0]['document_id'] == expected,
                                    'latency_seconds': time.perf_counter() - started, 'hits': hits})
                assert all(result['top1_correct'] for result in results), results
                snapshot = control_snapshot(channel)
                report = {'fixture': 'linux-semantic-corpus-v1', 'authority': 'Linux helper execution; exact Mac parity not established',
                          'backend': snapshot.get('model', {}).get('backend', 'unknown'), 'asset_path': str(model),
                          'assets': asset_manifest(model), 'initialization_seconds': initialization,
                          'queries': results, 'top1_accuracy': 1.0,
                          'model_state': snapshot,
                          'memory_samples': process_memory(process.pid),
                          'limitations': ['Four fixed factual sources, not a general quality benchmark',
                                          ('Public EmbeddingGemma 2 family; exact Mac weights remain unknown' if model.is_file() else 'Independent model substitution; original embedding identity unknown')]}
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(report, indent=2) + '\n')
                print(json.dumps({'output': str(args.output), 'top1_accuracy': report['top1_accuracy']}))
            finally:
                channel.close()
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                if process.returncode not in (0, -15):
                    print(log.read_text())

if __name__ == '__main__':
    main()
