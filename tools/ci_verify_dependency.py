#!/usr/bin/env python3
"""Verify downloaded dependency prefixes without starting a compiler."""
import argparse
import json
from pathlib import Path
import subprocess


def verify(component, prefix):
    if component == 'macos-runtime':
        from build_macos_runtimes import verify as verify_runtime
        verify_runtime(prefix)
        return
    from build_macos_sdk import GRPC_COMMIT, PROTOBUF_COMMIT, JSON_COMMIT
    expected = {'grpc_commit': GRPC_COMMIT, 'protobuf_commit': PROTOBUF_COMMIT,
                'protobuf_version': 'libprotoc 35.1', 'json_commit': JSON_COMMIT,
                'architecture': 'arm64', 'minimum_macos': '15.0', 'static': True}
    if json.loads((prefix / 'foresight-sdk.json').read_text()) != expected:
        raise ValueError('Imported SDK provenance differs from the supported build')
    for relative in ['bin/protoc', 'bin/grpc_cpp_plugin', 'lib/cmake/grpc/gRPCConfig.cmake',
                     'share/cmake/nlohmann_json/nlohmann_jsonConfig.cmake', 'share/foresight-sdk/licenses']:
        if not (prefix / relative).exists():
            raise ValueError('Imported SDK is incomplete: ' + relative)
    actual = subprocess.check_output([str(prefix / 'bin/protoc'), '--version'], text=True).strip()
    if actual != expected['protobuf_version']:
        raise ValueError('Imported SDK protoc version differs')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', choices=('macos-sdk', 'macos-runtime'), required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    args = parser.parse_args()
    verify(args.component, args.prefix)
