#!/usr/bin/env python3
"""Assemble a relocatable prototype; model assets remain separately registered."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from prepare_litert import LIBRARY_SHA256
from prepare_onnx import LIBRARY_SHA256 as ONNX_LIBRARY_SHA256

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=ROOT / 'build')
    parser.add_argument('--flutter-bundle', type=Path,
                        default=ROOT / 'apps/desktop/build/linux/x64/release/bundle')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/open-foresight')
    parser.add_argument('--google-client', type=Path, help='Optional application OAuth configuration; never account tokens')
    parser.add_argument('--revision', help='Source commit for exported trees without .git')
    parser.add_argument('--litert-library', type=Path, default=ROOT / 'build/lib/liblitert-lm.so', help='Pinned native LiteRT-LM 0.18.0 library from tools/prepare_litert.py')
    parser.add_argument('--onnx-library', type=Path, default=ROOT / 'build/lib/libonnxruntime.so', help='Pinned ONNX Runtime from tools/prepare_onnx.py')
    parser.add_argument('--generation-backend', choices=('cpu', 'gpu'), default='cpu')
    parser.add_argument('--whisper-gpu-runtime', type=Path,
                        help='Statically linked Vulkan whisper-cli to bundle (host Vulkan loader required)')
    parser.add_argument('--whisper-gpu-device', type=int, default=0,
                        help='Whisper Vulkan device index; override at launch with FORESIGHT_WHISPER_DEVICE')
    args = parser.parse_args()
    assert args.whisper_gpu_device >= 0
    helper = args.build / 'services/helper/ForesightHelper'
    native = args.build / 'native/libforesight_native.so'
    service = args.build / 'application/foresight-service'
    mcp = args.build / 'application/foresight-mcp'
    assert service.is_file() and mcp.is_file(), 'Build the application service and MCP server first'
    assert helper.is_file() and native.is_file() and args.flutter_bundle.is_dir(), 'Build all components first'
    assert not args.output.exists(), 'Choose an empty output directory to avoid stale packaged libraries'
    worker = args.build / 'services/inference/foresight-model'
    assert worker.is_file() and args.litert_library.is_file() and args.onnx_library.is_file(), 'Build native inference and prepare LiteRT-LM/ONNX Runtime first'
    assert hashlib.sha256(args.litert_library.read_bytes()).hexdigest() == LIBRARY_SHA256, 'Native LiteRT-LM library checksum mismatch'
    assert hashlib.sha256(args.onnx_library.read_bytes()).hexdigest() == ONNX_LIBRARY_SHA256, 'ONNX Runtime checksum mismatch'
    # Refuse a Python extension or an incompatible/missing public C runtime.
    environment = dict(__import__('os').environ, FORESIGHT_LITERT_LIBRARY=str(args.litert_library.resolve()))
    subprocess.run([str(worker), '--check'], env=environment, check=True)
    shutil.copytree(args.flutter_bundle, args.output / 'app')
    (args.output / 'bin').mkdir()
    (args.output / 'lib').mkdir()
    (args.output / 'share/open-foresight').mkdir(parents=True)
    shutil.copy2(helper, args.output / 'bin/ForesightHelper')
    shutil.copy2(service, args.output / 'bin/foresight-service')
    shutil.copy2(mcp, args.output / 'bin/foresight-mcp')
    shutil.copy2(native, args.output / 'lib/libforesight_native.so')
    if args.whisper_gpu_runtime:
        assert args.whisper_gpu_runtime.is_file(), 'Build the Vulkan Whisper runtime first'
        shutil.copy2(args.whisper_gpu_runtime, args.output / 'bin/whisper-cli-vulkan')
        for name in ('LICENSE', 'provenance.json'):
            shutil.copy2(args.whisper_gpu_runtime.parent / name,
                         args.output / 'share/open-foresight' / ('whisper-' + name))
    shutil.copy2(worker, args.output / 'bin/foresight-model')
    shutil.copy2(args.litert_library, args.output / 'lib/liblitert-lm.so')
    shutil.copy2(args.onnx_library, args.output / 'lib/libonnxruntime.so')
    for license_file in ('LICENSE', 'ThirdPartyNotices.txt'):
        shutil.copy2(ROOT / 'third_party/onnxruntime' / license_file, args.output / 'share/open-foresight' / ('onnxruntime-' + license_file))
    shutil.copy2(ROOT / 'third_party/litert_lm/LICENSE', args.output / 'share/open-foresight/LiteRT-LM-LICENSE')
    for dependency in ('sentencepiece', 'flatbuffers'):
        shutil.copy2(args.build / '_deps' / (dependency + '-src') / 'LICENSE',
                     args.output / 'share/open-foresight' / (dependency + '-LICENSE'))
    for component in ('protobuf-lite', 'esaxx', 'darts_clone', 'absl'):
        shutil.copy2(args.build / '_deps/sentencepiece-src/third_party' / component / 'LICENSE',
                     args.output / 'share/open-foresight' / ('sentencepiece-' + component + '-LICENSE'))
    litert_runtime = {'kind': 'native', 'version': '0.18.0', 'runner': 'bin/foresight-model',
                      'library': 'lib/liblitert-lm.so', 'sha256': hashlib.sha256(args.litert_library.read_bytes()).hexdigest()}
    client = args.google_client
    if client is not None:
        configuration = json.loads(client.read_text())
        assert set(configuration) == {'installed'} and 'client_id' in configuration['installed'], 'Use application OAuth configuration, never account tokens'
        installed = configuration['installed']
        assert isinstance(installed['client_id'], str) and isinstance(installed.get('client_secret', ''), str), 'Invalid application OAuth configuration'
        (args.output / 'share/open-foresight/google-client.json').write_text(json.dumps({'installed': {
            'client_id': installed['client_id'], 'client_secret': installed.get('client_secret', '')}}))
        (args.output / 'share/open-foresight/google-client.json').chmod(0o600)
    # Bundle helper inference/protocol dependencies, keep the Linux C ABI and desktop
    # GTK stack as explicit host prerequisites. ldd is run only on our built binaries.
    dependencies = subprocess.check_output(['ldd', str(helper), str(native), str(worker), str(args.litert_library), str(args.onnx_library)], text=True)
    assert 'not found' not in dependencies, dependencies
    bundled = []
    for name, path in re.findall(r'\s*(\S+) => (/\S+)', dependencies):
        if name.startswith(('libgrpc', 'libgpr', 'libprotobuf', 'libupb', 'libabsl',
                            'libre2', 'libcares', 'libaddress_sorting', 'libutf8', 'libicu', 'libsqlite3.so')):
            destination = args.output / 'lib' / name
            if not destination.exists():
                shutil.copy2(path, destination)
                bundled.append(name)
    # Dart sqlite3 opens the unversioned name, absent from runtime-only distro
    # packages. Keep both names within the private bundle, without dev packages.
    if (args.output / 'lib/libsqlite3.so.0').exists():
        (args.output / 'lib/libsqlite3.so').symlink_to('libsqlite3.so.0')
    launcher = args.output / 'open-foresight'
    launcher.write_text('''#!/usr/bin/env bash
set -euo pipefail
task_bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export LD_LIBRARY_PATH="$task_bundle/lib:$task_bundle/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export FORESIGHT_SERVICE="$task_bundle/bin/foresight-service"
export FORESIGHT_HELPER="$task_bundle/bin/ForesightHelper"
export FORESIGHT_NATIVE="$task_bundle/lib/libforesight_native.so"
export FORESIGHT_MODEL_WORKER="$task_bundle/bin/foresight-model"
export FORESIGHT_LITERT_LIBRARY="$task_bundle/lib/liblitert-lm.so"
export FORESIGHT_ONNX_LIBRARY="$task_bundle/lib/libonnxruntime.so"
export FORESIGHT_LITERT_RUNNER="$task_bundle/bin/foresight-model"
export FORESIGHT_LITERT_BACKEND="${FORESIGHT_LITERT_BACKEND:-@GENERATION_BACKEND@}"
if [[ -x "$task_bundle/bin/whisper-cli-vulkan" ]]; then
  export FORESIGHT_WHISPER_RUNTIME="${FORESIGHT_WHISPER_RUNTIME:-$task_bundle/bin/whisper-cli-vulkan}"
  export FORESIGHT_WHISPER_BACKEND="${FORESIGHT_WHISPER_BACKEND:-gpu}"
  export FORESIGHT_WHISPER_DEVICE="${FORESIGHT_WHISPER_DEVICE:-@WHISPER_DEVICE@}"
fi
if [[ -f "$task_bundle/share/open-foresight/google-client.json" ]]; then
  export FORESIGHT_GOOGLE_CLIENT="$task_bundle/share/open-foresight/google-client.json"
fi
# The source checkout's opt-in evaluated installation is already local. A
# relocated bundle without it still launches and offers explicit model setup.
if [[ -z "${FORESIGHT_MODEL_MANIFEST:-}" ]]; then
  for task_manifest in installed-gemma-macos-gpu.json installed-gemma-gpu.json installed.json; do
    task_install="$task_bundle/../../models/local/native/$task_manifest"
    if [[ -f "$task_install" ]]; then
      export FORESIGHT_MODEL_MANIFEST="$task_install"
      break
    fi
  done
fi
case "${FORESIGHT_ENTRYPOINT:-desktop}" in
  desktop) exec "$task_bundle/app/open-foresight" "$@" ;;
  mcp) exec "$task_bundle/bin/foresight-mcp" "$@" ;;
  service) exec "$task_bundle/bin/foresight-service" "$@" ;;
  *) echo "Unknown Open Foresight entrypoint" >&2; exit 2 ;;
esac
'''.replace('@GENERATION_BACKEND@', args.generation_backend)
   .replace('@WHISPER_DEVICE@', str(args.whisper_gpu_device)))
    launcher.chmod(0o755)
    for entry in ('mcp', 'service'):
        command = args.output / ('open-foresight-' + entry)
        command.write_text('#!/usr/bin/env bash\nset -euo pipefail\ntask_bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)\nexport FORESIGHT_ENTRYPOINT=' + entry + '\nexec "$task_bundle/open-foresight" "$@"\n')
        command.chmod(0o755)
    commit = args.revision or subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Revision must be a full lowercase Git commit hash')
    files = [{'path': str(file.relative_to(args.output)),
              'sha256': hashlib.sha256(file.read_bytes()).hexdigest()}
             for file in sorted(args.output.rglob('*')) if file.is_file()]
    manifest = {'build_id': 'open-foresight-0.1.0+' + commit[:12], 'revision': commit,
                'gemma_runtime': litert_runtime,
                'embedding_compatibility_runtime': {'kind': 'native-onnx', 'version': '1.31.0', 'sha256': ONNX_LIBRARY_SHA256},
                'generation_backend_default': args.generation_backend,
                'whisper_runtime': 'vulkan' if args.whisper_gpu_runtime else 'registered',
                'whisper_gpu_device_default': args.whisper_gpu_device if args.whisper_gpu_runtime else None,
                'legacy_ping_version': '1.0.3', 'bundled_libraries': sorted(bundled),
                'host_dependencies': ['Linux x86_64, compatible glibc/libstdc++',
                    'GTK3 desktop stack', 'PipeWire and pw-record for capture',
                    'registered local generation/speech executables and model assets'],
                'files': files}
    if args.generation_backend == 'gpu' or args.whisper_gpu_runtime:
        manifest['host_dependencies'].append('Vulkan loader and a compatible GPU driver for GPU inference')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'bundle': str(args.output), 'build_id': manifest['build_id'],
                      'files': len(files)}))

if __name__ == '__main__':
    main()
