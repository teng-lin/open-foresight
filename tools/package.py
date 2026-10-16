#!/usr/bin/env python3
"""Assemble a relocatable prototype; model assets remain separately registered."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from bundle_litert import bundle_runtime

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=ROOT / 'build')
    parser.add_argument('--flutter-bundle', type=Path,
                        default=ROOT / 'apps/desktop/build/linux/x64/release/bundle')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/foresight')
    parser.add_argument('--google-client', type=Path, help='Optional application OAuth configuration; never account tokens')
    parser.add_argument('--litert-python', type=Path, help='Validated Python environment to bundle for Gemma 4')
    parser.add_argument('--generation-backend', choices=('cpu', 'gpu'), default='cpu')
    parser.add_argument('--whisper-gpu-runtime', type=Path,
                        help='Statically linked Vulkan whisper-cli to bundle (host Vulkan loader required)')
    parser.add_argument('--whisper-gpu-device', type=int, default=0,
                        help='Whisper Vulkan device index; override at launch with FORESIGHT_WHISPER_DEVICE')
    args = parser.parse_args()
    assert args.generation_backend != 'gpu' or args.litert_python, 'GPU generation requires the bundled LiteRT runtime'
    assert args.whisper_gpu_device >= 0
    helper = args.build / 'services/helper/ForesightHelper'
    native = args.build / 'native/libforesight_native.so'
    assert helper.is_file() and native.is_file() and args.flutter_bundle.is_dir(), 'Build all components first'
    assert not args.output.exists(), 'Choose an empty output directory to avoid stale packaged libraries'
    shutil.copytree(args.flutter_bundle, args.output / 'app')
    (args.output / 'bin').mkdir()
    (args.output / 'lib').mkdir()
    (args.output / 'share/foresight').mkdir(parents=True)
    shutil.copy2(helper, args.output / 'bin/ForesightHelper')
    shutil.copy2(native, args.output / 'lib/libforesight_native.so')
    if args.whisper_gpu_runtime:
        assert args.whisper_gpu_runtime.is_file(), 'Build the Vulkan Whisper runtime first'
        shutil.copy2(args.whisper_gpu_runtime, args.output / 'bin/whisper-cli-vulkan')
        for name in ('LICENSE', 'provenance.json'):
            shutil.copy2(args.whisper_gpu_runtime.parent / name,
                         args.output / 'share/foresight' / ('whisper-' + name))
    shutil.copy2(ROOT / 'services/helper/model_adapter.py', args.output / 'share/foresight/model_adapter.py')
    shutil.copy2(ROOT / 'requirements-models.txt', args.output / 'share/foresight/requirements-models.txt')
    litert_runtime = None
    if args.litert_python is not None:
        subprocess.run([str(args.litert_python), '-I', str(ROOT / 'services/helper/litert_embedding_adapter.py'), '--check'], check=True)
        def architecture(path):
            with Path(path).open('rb') as f:
                header = f.read(20)
            if header[:4] != b'\x7fELF': raise ValueError('Expected ELF runtime')
            return int.from_bytes(header[18:20], 'little')
        shutil.copy2(ROOT / 'services/helper/litert_runner.py', args.output / 'share/foresight/litert_runner.py')
        shutil.copy2(ROOT / 'services/helper/grounded_generation.py', args.output / 'share/foresight/grounded_generation.py')
        shutil.copy2(ROOT / 'services/helper/litert_embedding_adapter.py', args.output / 'share/foresight/litert_embedding_adapter.py')
        litert_runtime = bundle_runtime(args.litert_python, args.output / 'share/foresight/python', ROOT / 'services/helper/litert_runner.py', architecture(helper), architecture)
    client = args.google_client
    if client is not None:
        configuration = json.loads(client.read_text())
        assert set(configuration) == {'installed'} and 'client_id' in configuration['installed'], 'Use application OAuth configuration, never account tokens'
        installed = configuration['installed']
        assert isinstance(installed['client_id'], str) and isinstance(installed.get('client_secret', ''), str), 'Invalid application OAuth configuration'
        (args.output / 'share/foresight/google-client.json').write_text(json.dumps({'installed': {
            'client_id': installed['client_id'], 'client_secret': installed.get('client_secret', '')}}))
        (args.output / 'share/foresight/google-client.json').chmod(0o600)
    # Bundle helper inference/protocol dependencies, keep the Linux C ABI and desktop
    # GTK stack as explicit host prerequisites. ldd is run only on our built binaries.
    dependencies = subprocess.check_output(['ldd', str(helper), str(native)], text=True)
    assert 'not found' not in dependencies, dependencies
    bundled = []
    for name, path in re.findall(r'\s*(\S+) => (/\S+)', dependencies):
        if name.startswith(('libgrpc', 'libgpr', 'libprotobuf', 'libupb', 'libabsl',
                            'libre2', 'libcares', 'libaddress_sorting', 'libutf8')):
            destination = args.output / 'lib' / name
            if not destination.exists():
                shutil.copy2(path, destination)
                bundled.append(name)
    launcher = args.output / 'foresight'
    launcher.write_text('''#!/usr/bin/env bash
set -euo pipefail
task_bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export LD_LIBRARY_PATH="$task_bundle/lib:$task_bundle/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export FORESIGHT_HELPER="$task_bundle/bin/ForesightHelper"
export FORESIGHT_NATIVE="$task_bundle/lib/libforesight_native.so"
export FORESIGHT_MODEL_ADAPTER="$task_bundle/share/foresight/model_adapter.py"
export FORESIGHT_LITERT_BACKEND="${FORESIGHT_LITERT_BACKEND:-@GENERATION_BACKEND@}"
if [[ -x "$task_bundle/bin/whisper-cli-vulkan" ]]; then
  export FORESIGHT_WHISPER_RUNTIME="${FORESIGHT_WHISPER_RUNTIME:-$task_bundle/bin/whisper-cli-vulkan}"
  export FORESIGHT_WHISPER_BACKEND="${FORESIGHT_WHISPER_BACKEND:-gpu}"
  export FORESIGHT_WHISPER_DEVICE="${FORESIGHT_WHISPER_DEVICE:-@WHISPER_DEVICE@}"
fi
if [[ -f "$task_bundle/share/foresight/google-client.json" ]]; then
  export FORESIGHT_GOOGLE_CLIENT="$task_bundle/share/foresight/google-client.json"
fi
if [[ -x "$task_bundle/share/foresight/litert-runner" ]]; then
  export FORESIGHT_LITERT_RUNNER="$task_bundle/share/foresight/litert-runner"
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
task_python="$task_bundle/../../.venv/bin/python"
if [[ -z "${FORESIGHT_MODEL_PYTHON:-}" && -x "$task_python" ]]; then
  export FORESIGHT_MODEL_PYTHON="$task_python"
fi
exec "$task_bundle/app/foresight" "$@"
'''.replace('@GENERATION_BACKEND@', args.generation_backend)
   .replace('@WHISPER_DEVICE@', str(args.whisper_gpu_device)))
    launcher.chmod(0o755)
    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    files = [{'path': str(file.relative_to(args.output)),
              'sha256': hashlib.sha256(file.read_bytes()).hexdigest()}
             for file in sorted(args.output.rglob('*')) if file.is_file()]
    manifest = {'build_id': 'foresight-0.1.0+' + commit[:12], 'revision': commit,
                'gemma_runtime': litert_runtime,
                'generation_backend_default': args.generation_backend,
                'whisper_runtime': 'vulkan' if args.whisper_gpu_runtime else 'registered',
                'whisper_gpu_device_default': args.whisper_gpu_device if args.whisper_gpu_runtime else None,
                'legacy_ping_version': '1.0.3', 'bundled_libraries': sorted(bundled),
                'host_dependencies': ['Linux x86_64, compatible glibc/libstdc++',
                    'GTK3 desktop stack', 'PipeWire and pw-record for capture',
                    'Python environment with requirements-models.txt for embeddings',
                    'registered local generation/speech executables and model assets'],
                'files': files}
    if args.generation_backend == 'gpu' or args.whisper_gpu_runtime:
        manifest['host_dependencies'].append('Vulkan loader and a compatible GPU driver for GPU inference')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'bundle': str(args.output), 'build_id': manifest['build_id'],
                      'files': len(files)}))

if __name__ == '__main__':
    main()
