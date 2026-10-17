#!/usr/bin/env python3
"""Build the pinned gRPC/protobuf closure with the same sanitizers as its callers.

Mixing instrumented generated protobuf code with an uninstrumented system
protobuf library is unsupported: metadata layout and container annotations differ.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
from build_macos_sdk import GRPC_COMMIT, PROTOBUF_COMMIT, MODULES, checkout, require_clean_sources, run

ROOT = Path(__file__).resolve().parents[1]
FLAGS = '-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=ROOT / 'build/sanitizer-sdk')
    parser.add_argument('--sources', type=Path, default=ROOT / 'build/sanitizer-sdk-sources')
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    prefix, sources = args.prefix.resolve(), args.sources.resolve()
    compiler = subprocess.check_output(['g++', '-dumpfullversion'], text=True).strip()
    manifest = {'grpc_commit': GRPC_COMMIT, 'protobuf_commit': PROTOBUF_COMMIT,
                'compiler': compiler, 'flags': FLAGS}
    stamp = prefix / 'sanitizer-sdk.json'
    if stamp.exists():
        if json.loads(stamp.read_text()) != manifest:
            parser.error('Sanitizer SDK identity differs; choose a fresh prefix')
        if all((prefix / file).exists() for file in ('bin/protoc', 'bin/grpc_cpp_plugin',
            'lib/cmake/grpc/gRPCConfig.cmake', 'lib/libprotobuf.so')):
            print('Verified instrumented SDK already installed:', prefix)
            return
    grpc = sources / 'grpc'
    checkout(grpc, 'https://github.com/grpc/grpc.git', GRPC_COMMIT)
    run('git', '-C', grpc, 'submodule', 'update', '--init', '--recursive', '--depth', '1',
        *['third_party/' + module for module in MODULES])
    for module in MODULES:
        require_clean_sources(grpc / 'third_party' / module)
    if subprocess.check_output(['git', '-C', str(grpc / 'third_party/protobuf'),
                                'rev-parse', 'HEAD'], text=True).strip() != PROTOBUF_COMMIT:
        raise ValueError('gRPC protobuf submodule differs from the release SDK')
    build = sources / 'build'
    run('cmake', '-S', grpc, '-B', build, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Debug',
        '-DCMAKE_C_COMPILER=gcc', '-DCMAKE_CXX_COMPILER=g++', '-DCMAKE_CXX_STANDARD=20',
        f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DCMAKE_INSTALL_LIBDIR=lib',
        f'-DCMAKE_C_FLAGS={FLAGS}', f'-DCMAKE_CXX_FLAGS={FLAGS}',
        '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined',
        '-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined',
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_TESTING=OFF', '-DgRPC_BUILD_TESTS=OFF',
        '-Dprotobuf_BUILD_TESTS=OFF', '-DRE2_BUILD_TESTING=OFF', '-DCARES_BUILD_TOOLS=OFF',
        '-DgRPC_SSL_PROVIDER=package', '-DgRPC_ZLIB_PROVIDER=package',
        *[f'-DgRPC_{name}_PROVIDER=module' for name in ('ABSL', 'CARES', 'PROTOBUF', 'RE2')],
        f'-DCMAKE_PROJECT_grpc_INCLUDE={ROOT / "packaging/minimal-grpc.cmake"}',
        *[f'-DgRPC_BUILD_GRPC_{language}_PLUGIN=OFF' for language in
          ('CSHARP', 'NODE', 'OBJECTIVE_C', 'PHP', 'PYTHON', 'RUBY')])
    # Protoc/plugin run during the build; keep address/UB failures fatal while
    # excluding process-shutdown leaks just as in the application test host.
    environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:halt_on_error=1',
                       UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    run('cmake', '--build', build, '--parallel', args.jobs, env=environment)
    run('cmake', '--install', build, env=environment)
    prefix.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
