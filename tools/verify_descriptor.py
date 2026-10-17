#!/usr/bin/env python3
"""Audit all recovered tags/types/RPCs against a fresh transcription descriptor."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'research.xeno.labs.foresight.launch_agent.proto'
METHODS = ['IndexDocument', 'RetrieveContext', 'UpdateModelPaths', 'DeleteDocument',
           'Encode', 'ChunkText', 'TruncateText', 'ComputeEmbedding',
           'ComputeImageEmbedding', 'ComputeAudioEmbedding', 'Ping']

def shape(file):
    return {
        'package': file.package,
        'messages': {m.name: {'oneofs': [o.name for o in m.oneof_decl],
            'fields': [(f.name, f.number, f.type, f.label, f.type_name,
                        f.oneof_index if f.HasField('oneof_index') else None)
                       for f in m.field]} for m in file.message_type},
        'services': {s.name: [(m.name, m.input_type, m.output_type,
                              m.client_streaming, m.server_streaming)
                             for m in s.method] for s in file.service}}

def verify(protoc='protoc'):
    raw = (ROOT / 'proto/rag/rag_service.descriptor.pb').read_bytes()
    recovered = descriptor_pb2.FileDescriptorProto.FromString(raw)
    assert recovered.package == PACKAGE
    assert len(recovered.message_type) == 22
    assert len(recovered.service) == 1
    assert [m.name for m in recovered.service[0].method] == METHODS
    assert recovered.syntax == 'editions' and recovered.edition == 1001
    assert recovered.options.features.utf8_validation == descriptor_pb2.FeatureSet.NONE
    with tempfile.TemporaryDirectory() as temp:
        output = Path(temp) / 'transcribed.pb'
        subprocess.run([protoc, f'-I{ROOT / "proto/rag"}',
                        f'--descriptor_set_out={output}', 'rag_service.proto'], check=True)
        transcribed = descriptor_pb2.FileDescriptorSet.FromString(output.read_bytes()).file[0]
    expected = shape(recovered)
    actual = shape(transcribed)
    actual = json.loads(json.dumps(actual).replace('foresight.helper.v1', PACKAGE))
    expected = json.loads(json.dumps(expected))
    assert expected == actual, 'Wire shape differs from recovered descriptor'
    pool = descriptor_pool.DescriptorPool()
    pool.Add(recovered)
    ping = message_factory.GetMessageClass(pool.FindMessageTypeByName(PACKAGE + '.PingResponse'))
    # Edition explicit default presence and unknown field preservation are tested on actual bytes.
    default = ping.FromString(b'\x08\x00')
    assert default.HasField('success') and default.SerializeToString() == b'\x08\x00'
    unknown = b'\x98\x06\x07'
    assert ping.FromString(unknown).SerializeToString() == unknown
    query = message_factory.GetMessageClass(pool.FindMessageTypeByName(PACKAGE + '.Query'))
    selected = query.FromString(b'\x0a\x01x\x12\x01y')
    assert selected.WhichOneof('query') == 'audio_query' and selected.audio_query == b'y'
    return {'descriptor_sha256': hashlib.sha256(raw).hexdigest(),
            'service': PACKAGE + '.RagService', 'rpc_count': 11, 'message_count': 22,
            'wire_shape': 'verified', 'edition': '2024',
            'production_cpp': 'version package/name while preserving recovered explicit presence and UTF8 NONE',
            'proto3_deviations': ['Implicit scalar presence loses explicitly supplied default values',
                                  'UTF-8 validation differs from recovered NONE',
                                  'Java outer class option absent (not a C++ wire difference)']}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--protoc', default='protoc')
    args = parser.parse_args()
    print(json.dumps(verify(args.protoc), indent=2))
