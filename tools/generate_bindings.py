#!/usr/bin/env python3
"""Generate the versioned helper API, preserving recovered field/edition features."""
import argparse
import re
from pathlib import Path
import subprocess
import tempfile
from google.protobuf import descriptor_pb2

ROOT = Path(__file__).resolve().parents[1]

def production_descriptor():
    """Version the owned API without changing recovered scalar presence/features."""
    descriptor = descriptor_pb2.FileDescriptorProto.FromString(
        (ROOT / 'proto/rag/rag_service.descriptor.pb').read_bytes())
    original = descriptor.package
    descriptor.name = 'rag_service.proto'
    descriptor.package = re.search(r'package\s+([\w.]+)\s*;',
        (ROOT / 'proto/rag/rag_service.proto').read_text()).group(1)
    for message in descriptor.message_type:
        for field in message.field:
            if field.type_name:
                field.type_name = field.type_name.replace(original, descriptor.package)
    for service in descriptor.service:
        for method in service.method:
            method.input_type = method.input_type.replace(original, descriptor.package)
            method.output_type = method.output_type.replace(original, descriptor.package)
    return descriptor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--language', choices=['cpp', 'python', 'dart'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--protoc', default='protoc')
    parser.add_argument('--grpc-plugin')
    args = parser.parse_args()
    descriptor = production_descriptor()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / 'descriptor-set.pb'
        source.write_bytes(descriptor_pb2.FileDescriptorSet(file=[descriptor]).SerializeToString())
        command = [args.protoc, f'--descriptor_set_in={source}',
                   f'--{args.language}_out={"grpc:" if args.language == "dart" else ""}{args.output}']
        if args.grpc_plugin:
            command.extend([f'--plugin=protoc-gen-grpc={args.grpc_plugin}',
                            f'--grpc_out={args.output}'])
        subprocess.run(command + [descriptor.name], check=True)

if __name__ == '__main__':
    main()
