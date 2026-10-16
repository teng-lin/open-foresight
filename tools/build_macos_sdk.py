#!/usr/bin/env python3
"""Build pinned, static arm64 dependencies with a real macOS 15 deployment target.

Homebrew binaries are build tools only: its current gRPC/protobuf bottles can
require newer OS versions. gRPC's exact gitlinked dependencies are built from
source and installed together. No deployment load commands are patched.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GRPC_COMMIT = 'aae267021b1ac256f8b9038d0ef528c3798cc137'  # v1.83.1; its protobuf 35.1 supports the repo's Edition 2024 descriptor
PROTOBUF_COMMIT = '35cd01f9fe9afbeea38cc7b979a3b6bfcde82c03'
JSON_COMMIT = '65ee68451d8eb2b5f3a30b410476ab83deb3289b'  # v3.12.0
MODULES = ['abseil-cpp', 'boringssl-with-bazel', 'cares/cares', 'protobuf', 're2']


def run(*args, **kwargs):
    print('+', ' '.join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def checkout(path, repository, commit):
    if not (path / '.git').exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        run('git', 'init', path)
        run('git', '-C', path, 'remote', 'add', 'origin', repository)
    remote = subprocess.check_output(['git', '-C', str(path), 'remote', 'get-url', 'origin'], text=True).strip()
    if remote != repository:
        raise ValueError(f'Refusing unexpected source repository: {remote}')
    present = subprocess.run(['git', '-C', str(path), 'cat-file', '-e', commit],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if present.returncode:
        run('git', '-C', path, 'fetch', '--depth', '1', 'origin', commit)
    dirty = subprocess.check_output(['git', '-C', str(path), 'diff', '--name-only',
                                     '--ignore-submodules=all'], text=True).strip()
    if dirty:
        raise ValueError(f'Refusing modified SDK sources at {path}: {dirty}')
    run('git', '-C', path, 'checkout', '--detach', commit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=ROOT / 'build/sdk')
    parser.add_argument('--sources', type=Path, default=ROOT / 'build/sdk-sources')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.error('Build on an Apple Silicon Mac; cross builds are not validated')
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    prefix, sources = args.prefix.resolve(), args.sources.resolve()
    manifest = {'grpc_commit': GRPC_COMMIT, 'protobuf_commit': PROTOBUF_COMMIT,
                'protobuf_version': 'libprotoc 35.1', 'json_commit': JSON_COMMIT,
                'architecture': 'arm64', 'minimum_macos': '15.0', 'static': True}
    stamp = prefix / 'foresight-sdk.json'
    required = [prefix / 'bin/protoc', prefix / 'bin/grpc_cpp_plugin',
                prefix / 'lib/cmake/grpc/gRPCConfig.cmake',
                prefix / 'share/cmake/nlohmann_json/nlohmann_jsonConfig.cmake']
    if stamp.exists() and json.loads(stamp.read_text()) == manifest and all(p.exists() for p in required):
        print(f'Validated SDK already installed: {prefix}')
        return
    if stamp.exists() and json.loads(stamp.read_text()) != manifest:
        parser.error('SDK prefix contains a different build; use a fresh --prefix')
    checkout(sources / 'grpc', 'https://github.com/grpc/grpc.git', GRPC_COMMIT)
    run('git', '-C', sources / 'grpc', 'submodule', 'update', '--init', '--depth', '1',
        *['third_party/' + module for module in MODULES])
    for module in MODULES:
        path = sources / 'grpc/third_party' / module
        dirty = subprocess.check_output(['git', '-C', str(path), 'diff', '--name-only'], text=True).strip()
        if dirty:
            raise ValueError(f'Refusing modified SDK dependency at {path}: {dirty}')
    checkout(sources / 'json', 'https://github.com/nlohmann/json.git', JSON_COMMIT)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='15.0')
    # Clear inherited package hints that could make a newer Homebrew library
    # silently enter the SDK, even when running from a developer shell.
    for key in ['CMAKE_PREFIX_PATH', 'PKG_CONFIG_PATH', 'CPATH', 'LIBRARY_PATH',
                'CPLUS_INCLUDE_PATH', 'LDFLAGS', 'CPPFLAGS']:
        env.pop(key, None)
    common = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
              f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DCMAKE_OSX_ARCHITECTURES=arm64',
              '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0', '-DCMAKE_CXX_STANDARD=17',
              '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DBUILD_SHARED_LIBS=OFF',
              '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local',
              '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF']
    # Upstream BoringSSL adds its entire test suite to ALL even when gRPC's
    # tests are disabled. Exclude that subdirectory from ALL; grpc's explicit
    # ssl/crypto dependencies and parent install rules still build/install the
    # required libraries. The pinned source checkout stays unmodified.
    hook = sources / 'sdk-project.cmake'
    hook.write_text('if(PROJECT_NAME STREQUAL "grpc")\n  cmake_language(DEFER CALL set_property DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/third_party/boringssl-with-bazel" PROPERTY EXCLUDE_FROM_ALL TRUE)\nendif()\n')
    common += [f'-DCMAKE_PROJECT_INCLUDE={hook}', '-DBUILD_TESTING=OFF', '-DCARES_BUILD_TOOLS=OFF']
    build = sources / 'grpc-build'
    run('cmake', '-S', sources / 'grpc', '-B', build, *common,
        '-DgRPC_INSTALL=ON', '-DgRPC_BUILD_TESTS=OFF',
        '-DgRPC_BUILD_GRPC_CPP_PLUGIN=ON',
        *[f'-DgRPC_BUILD_GRPC_{language}_PLUGIN=OFF' for language in
          ['CSHARP', 'NODE', 'OBJECTIVE_C', 'PHP', 'PYTHON', 'RUBY']],
        *[f'-DgRPC_{name}_PROVIDER=module' for name in ['ABSL', 'CARES', 'PROTOBUF', 'RE2', 'SSL']],
        # c-ares' link-only symbol probe sees pipe2 in new SDKs even though
        # Apple introduced it in macOS 27. Select its existing pipe/fcntl
        # fallback rather than weakening availability diagnostics.
        '-DHAVE_PIPE2:BOOL=OFF',
        '-DgRPC_ZLIB_PROVIDER=package', '-Dprotobuf_BUILD_TESTS=OFF',
        '-DABSL_BUILD_TESTING=OFF', '-DRE2_BUILD_TESTING=OFF', env=env)
    run('cmake', '--build', build, '--parallel', args.jobs, env=env)
    run('cmake', '--install', build, env=env)
    json_build = sources / 'json-build'
    run('cmake', '-S', sources / 'json', '-B', json_build, *common,
        '-DJSON_BuildTests=OFF', '-DJSON_Install=ON', env=env)
    run('cmake', '--install', json_build, env=env)
    licenses = prefix / 'share/foresight-sdk/licenses'
    licenses.mkdir(parents=True, exist_ok=True)
    dependencies = {'grpc': sources / 'grpc', 'nlohmann-json': sources / 'json'}
    dependencies.update({name.replace('/', '-'): sources / 'grpc/third_party' / name
                         for name in MODULES})
    for name, directory in dependencies.items():
        for source in directory.iterdir():
            if source.is_file() and source.name.startswith(('LICENSE', 'COPYING', 'NOTICE')):
                shutil.copy2(source, licenses / f'{name}-{source.name}')
    version = subprocess.check_output([str(prefix / 'bin/protoc'), '--version'], text=True).strip()
    # Compatibility is a schema/plugin capability, not a guessed version
    # floor. Generate from the unchanged authoritative Edition 2024 descriptor
    # and the control schema using this installed protoc/plugin pair.
    with tempfile.TemporaryDirectory(prefix='foresight-sdk-probe-') as temporary:
        run(sys.executable, ROOT / 'tools/generate_bindings.py', '--language', 'cpp',
            '--output', temporary, '--protoc', prefix / 'bin/protoc',
            '--grpc-plugin', prefix / 'bin/grpc_cpp_plugin')
        run(prefix / 'bin/protoc', f'--proto_path={ROOT / "proto/linux"}',
            f'--cpp_out={temporary}', f'--grpc_out={temporary}',
            f'--plugin=protoc-gen-grpc={prefix / "bin/grpc_cpp_plugin"}',
            ROOT / 'proto/linux/helper_control.proto')
    actual_commit = subprocess.check_output(
        ['git', '-C', str(sources / 'grpc/third_party/protobuf'), 'rev-parse', 'HEAD'],
        text=True).strip()
    if actual_commit != PROTOBUF_COMMIT:
        raise RuntimeError(f'Unexpected protobuf gitlink: {actual_commit}')
    manifest['protobuf_version'] = version
    for binary in [prefix / 'bin/protoc', prefix / 'bin/grpc_cpp_plugin']:
        info = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
        if 'minos 15.0' not in info:
            raise RuntimeError(f'Unexpected deployment target for {binary}: {info}')
        loads = subprocess.check_output(['otool', '-L', str(binary)], text=True)
        if '/opt/homebrew/' in loads or '/usr/local/' in loads:
            raise RuntimeError(f'External runtime dependency in {binary}: {loads}')
    if not all(path.exists() for path in required):
        raise RuntimeError('SDK install is incomplete')
    stamp.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Use -DCMAKE_PREFIX_PATH={prefix} -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0')


if __name__ == '__main__':
    main()
