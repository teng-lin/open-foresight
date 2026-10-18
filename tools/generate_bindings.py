#!/usr/bin/env python3
"""Generate from the authoritative descriptor, without rewriting edition features."""

import argparse
from pathlib import Path
import subprocess
import tempfile
from google.protobuf import descriptor_pb2

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", choices=["cpp", "python"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--protoc", default="protoc")
    parser.add_argument("--grpc-plugin")
    args = parser.parse_args()
    descriptor = descriptor_pb2.FileDescriptorProto.FromString(
        (ROOT / "proto/rag/rag_service.descriptor.pb").read_bytes()
    )
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / "descriptor-set.pb"
        source.write_bytes(
            descriptor_pb2.FileDescriptorSet(file=[descriptor]).SerializeToString()
        )
        command = [
            args.protoc,
            f"--descriptor_set_in={source}",
            f"--{args.language}_out={args.output}",
        ]
        if args.grpc_plugin:
            command.extend(
                [
                    f"--plugin=protoc-gen-grpc={args.grpc_plugin}",
                    f"--grpc_out={args.output}",
                ]
            )
        subprocess.run(command + [descriptor.name], check=True, timeout=300)


if __name__ == "__main__":
    main()
