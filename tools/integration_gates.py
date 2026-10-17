#!/usr/bin/env python3
"""Explicit, fail-closed integration groups; only disposable profiles/virtual audio."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from test_macos_release_models import MODELS

ROOT = Path(__file__).resolve().parents[1]


def check_events(path, expected):
    events = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    done = [event for event in events if event.get('type') == 'testDone' and not event.get('hidden')]
    if (len(done) != expected or any(event.get('skipped') or event.get('result') != 'success' for event in done)
            or not events or events[-1].get('type') != 'done' or events[-1].get('success') is not True):
        raise RuntimeError(f'Expected {expected} executed passing tests with no skips: {path}')
    return {'passed': len(done), 'skipped': 0}


def run_tests(package, files, expected, env, output, name, flutter='flutter', dart='dart'):
    output.mkdir(parents=True, exist_ok=True)
    events = output / f'{name}.events.jsonl'
    events.unlink(missing_ok=True)
    command = [flutter if package == 'desktop' else dart, 'test', *files,
               '--concurrency=1', '--reporter=expanded', '--file-reporter=json:' + str(events)]
    if package == 'desktop': command.append('--no-pub')
    cwd = ROOT / ('apps/desktop' if package == 'desktop' else 'packages/foresight_core')
    with (output / f'{name}.log').open('w') as log:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=2400)
    if result.returncode:
        print((output / f'{name}.log').read_text()[-12000:], flush=True)
        raise RuntimeError(f'{name} failed with exit {result.returncode}')
    return check_events(events, expected)


def model_file(directory, kind):
    _, _, filename, digest = MODELS[kind]
    path = (directory / filename).resolve(strict=True)
    with path.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
            raise ValueError(f'Wrong {kind} fixture digest')
    return str(path)


def bundle_environment(bundle, inherited):
    # Do not inherit profile paths, account configuration, capture routes or developer overrides.
    env = {key: value for key, value in inherited.items() if not key.startswith('FORESIGHT_')}
    bundle = bundle.resolve(strict=True)
    if bundle.suffix == '.app':
        resources = bundle / 'Contents/Resources'
        config = json.loads((resources / 'runtime.json').read_text())
        keys = ['FORESIGHT_NATIVE', 'FORESIGHT_HELPER', 'FORESIGHT_LITERT_RUNNER',
                'FORESIGHT_MODEL_WORKER', 'FORESIGHT_MODEL_PYTHON', 'FORESIGHT_LITERT_PYTHON',
                'FORESIGHT_MODEL_ADAPTER', 'FORESIGHT_LITERT_EMBEDDING_ADAPTER', 'FORESIGHT_QUERY_WORKER']
        for key in keys:
            if key in config:
                env[key] = str((resources / config[key]).resolve(strict=True))
    else:
        env.update(FORESIGHT_NATIVE=str(bundle / 'lib/libforesight_native.so'),
                   FORESIGHT_HELPER=str(bundle / 'bin/ForesightHelper'),
                   FORESIGHT_LITERT_RUNNER=str(bundle / 'bin/foresight-model'),
                   FORESIGHT_MODEL_WORKER=str(bundle / 'bin/foresight-model'),
                   FORESIGHT_LITERT_LIBRARY=str(bundle / 'lib/liblitert-lm.so'),
                   FORESIGHT_ONNX_LIBRARY=str(bundle / 'lib/libonnxruntime.so'),
                   FORESIGHT_QUERY_WORKER=str(bundle / 'share/open-foresight/adapters/legacy_query_worker.py'),
                   FORESIGHT_LITERT_PYTHON=str(bundle / 'bin/query-python'),
                   LD_LIBRARY_PATH=str(bundle / 'lib') + ':' + str(bundle / 'app/lib'))
    for key in ['FORESIGHT_NATIVE', 'FORESIGHT_HELPER', 'FORESIGHT_LITERT_RUNNER']:
        if not Path(env[key]).is_file():
            raise ValueError(f'Missing bundle runtime: {key}')
    env.update(FORESIGHT_LITERT_BACKEND='cpu', FORESIGHT_GENERATION_BACKEND='litert_lm')
    return env


def models_gate(args, env):
    env.update(FORESIGHT_INTEGRATION='1', FORESIGHT_GOOGLE_REAL_HELPER='1', FORESIGHT_GEMMA_TEST='1',
               FORESIGHT_WEB_MODEL_TEST='1', FORESIGHT_EMBEDDING_GPU='0',
               FORESIGHT_GENERATION_MODEL=model_file(args.models, 'generation'),
               FORESIGHT_EMBEDDING=model_file(args.models, 'embedding'),
               FORESIGHT_GEMMA_REPORT=str(args.output / 'gemma.json'),
               FORESIGHT_GOOGLE_REPORT=str(args.output / 'google-helper.json'),
               FORESIGHT_WEB_MODEL_REPORT=str(args.output / 'web-model.json'))
    env['FORESIGHT_GEMMA_MODEL'] = env['FORESIGHT_GENERATION_MODEL']
    env['FORESIGHT_GENERATION_RUNNER'] = env['FORESIGHT_LITERT_RUNNER']
    desktop = run_tests('desktop', ['test/integration_test.dart', 'test/native_load_test.dart',
        'test/meeting_citation_test.dart', 'test/google_real_helper_test.dart', 'test/gemma_native_test.dart'],
        5, env, args.output, 'models-desktop', args.flutter, args.dart)
    core = run_tests('core', ['test/web_model_test.dart'], 1, env, args.output, 'models-core', args.flutter, args.dart)
    return {'desktop': desktop, 'core': core}


@contextmanager
def private_pipewire(env, output):
    if sys.platform != 'linux' or Path('/dev/snd').exists():
        raise RuntimeError('Virtual audio requires Linux without host sound devices')
    if not env.get('DBUS_SESSION_BUS_ADDRESS'):
        raise RuntimeError('Run virtual-audio under dbus-run-session')
    processes, streams = [], []
    with tempfile.TemporaryDirectory(prefix='of-audio-', dir='/tmp') as directory:
        root = Path(directory)
        runtime, home = root / 'run', root / 'home'
        runtime.mkdir(mode=0o700); home.mkdir(mode=0o700)
        private = dict(env, PUB_CACHE=env.get('PUB_CACHE', str(Path(env.get('HOME', str(Path.home()))) / '.pub-cache')),
                       FLUTTER_SUPPRESS_ANALYTICS='true', HOME=str(home), XDG_RUNTIME_DIR=str(runtime), PIPEWIRE_RUNTIME_DIR=str(runtime),
                       PIPEWIRE_REMOTE='pipewire-0', PULSE_SERVER=f'unix:{runtime}/pulse/native',
                       XDG_CONFIG_HOME=str(home / '.config'), XDG_STATE_HOME=str(home / '.state'))
        # Ubuntu 24.04's WirePlumber 0.4 otherwise probes logind/Bluetooth.
        # This session only manages virtual nodes, with no hardware monitors.
        config = home / '.config/wireplumber'
        for group, settings in {
            'main': 'alsa_monitor.enabled = false\nv4l2_monitor.enabled = false\nlibcamera_monitor.enabled = false\n',
            'bluetooth': 'bluez_monitor.enabled = false\nbluez_midi_monitor.enabled = false\n',
        }.items():
            folder = config / f'{group}.lua.d'
            folder.mkdir(parents=True)
            (folder / '51-virtual-only.lua').write_text(settings)
        try:
            for daemon in ['pipewire', 'pipewire-pulse', 'wireplumber']:
                log = (output / f'{daemon}.log').open('w'); streams.append(log)
                processes.append(subprocess.Popen([daemon], env=private, stdout=log, stderr=subprocess.STDOUT,
                                                   start_new_session=True))
            deadline = time.monotonic() + 30
            while True:
                ready = subprocess.run(['pactl', 'info'], env=private, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if ready.returncode == 0: break
                if time.monotonic() > deadline or any(process.poll() is not None for process in processes):
                    raise RuntimeError('Private PipeWire did not become ready; inspect daemon logs')
                time.sleep(.1)
            sink = f'foresight-ci-{os.getpid()}'
            source = sink + '-microphone'
            for command in [
                ['load-module', 'module-null-sink', 'sink_name=' + sink, 'channels=1', 'rate=48000'],
                ['load-module', 'module-remap-source', 'master=' + sink + '.monitor', 'source_name=' + source, 'channels=1'],
            ]:
                subprocess.run(['pactl', *command], env=private, check=True, stdout=subprocess.DEVNULL, timeout=15)
            # Pulse can accept module loads before WirePlumber publishes default metadata.
            for kind, target in [('sink', sink), ('source', source)]:
                deadline = time.monotonic() + 15
                while True:
                    result = subprocess.run(['pactl', f'set-default-{kind}', target], env=private,
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                    if result.returncode == 0: break
                    if time.monotonic() > deadline or any(process.poll() is not None for process in processes):
                        raise RuntimeError(f'Private PipeWire default {kind} did not become ready')
                    time.sleep(.1)
            private.update(FORESIGHT_MICROPHONE_TARGET=source, FORESIGHT_LIVE_SINK=sink)
            yield private
        finally:
            for process in reversed(processes):
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
            for stream in streams: stream.close()


def audio_gate(args, env):
    runner = args.bundle.resolve() / 'bin/whisper-cli-vulkan'
    if not runner.is_file(): raise ValueError('Linux bundle must include Whisper')
    env.update(FORESIGHT_SPEECH_RUNNER=str(runner), FORESIGHT_WHISPER_RUNTIME=str(runner),
               FORESIGHT_WHISPER_BACKEND='cpu', FORESIGHT_SPEECH_MODEL=model_file(args.models, 'speech'),
               FORESIGHT_AUDIO_FIXTURE=str(ROOT / 'tests/fixtures/audio/jfk.wav'),
               FORESIGHT_LIVE_TEST='1', FORESIGHT_LIVE_GAP_TEST='1', FORESIGHT_PRIVATE_PIPEWIRE='1',
               FORESIGHT_LIVE_REPORT=str(args.output / 'live.json'),
               FORESIGHT_LIVE_GAP_REPORT=str(args.output / 'live-gap.json'),
               FORESIGHT_PIPEWIRE_REPORT=str(args.output / 'pipewire.json'))
    with private_pipewire(env, args.output) as private:
        desktop = run_tests('desktop', ['test/live_recording_test.dart', 'test/live_gap_recording_test.dart'],
                            2, private, args.output, 'audio-desktop', args.flutter, args.dart)
        core = run_tests('core', ['test/recording_pipewire_test.dart'], 1, private, args.output, 'audio-core', args.flutter, args.dart)
    return {'desktop': desktop, 'core': core, 'physical_audio': 'not_run'}


def fast_gate(args, env):
    with tempfile.TemporaryDirectory(prefix='of-fail-', dir='/tmp') as directory:
        runner = Path(directory) / 'pw-record'
        runner.write_text('#!/bin/sh\nexit 1\n'); runner.chmod(0o700)
        env = dict(env, PATH=directory + os.pathsep + env['PATH'])
        files = ['test/answer_failure_test.dart']
        if sys.platform == 'linux':
            if args.native is None or not args.native.is_file(): raise ValueError('--native is required on Linux')
            env.update(FORESIGHT_CAPTURE_STATE_TEST='1', FORESIGHT_NATIVE=str(args.native.resolve()))
            files.append('test/capture_failure_test.dart')
        return run_tests('desktop', files, len(files), env, args.output, 'fast', args.flutter, args.dart)


def reference_gate(args, env):
    if args.suite == 'reference-models':
        if args.query_model is None: raise ValueError('--query-model must point to an already authorized local asset')
        env.update(FORESIGHT_QUERY_MODEL_TEST='1', FORESIGHT_PROACTIVE_MODEL_TEST='1',
                   FORESIGHT_QUERY_MODEL=str(args.query_model.resolve(strict=True)),
                   FORESIGHT_QUERY_PYTHON=env['FORESIGHT_LITERT_PYTHON'], FORESIGHT_QUERY_WORKER=env['FORESIGHT_QUERY_WORKER'])
        return run_tests('core', ['test/dedicated_query_model_test.dart', 'test/proactive_model_test.dart'],
                         5, env, args.output, 'reference-models', args.flutter, args.dart)
    if not args.original_socket or not args.port_socket: raise ValueError('Both existing tokenizer sockets are required')
    env.update(FORESIGHT_ORIGINAL_TOKENIZER_SOCKET=args.original_socket, FORESIGHT_PORT_TOKENIZER_SOCKET=args.port_socket)
    return run_tests('core', ['test/reference_tokenizer_live_test.dart'], 1, env, args.output, 'reference-tokenizer', args.flutter, args.dart)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', required=True, choices=['fast', 'models', 'virtual-audio', 'reference-models', 'reference-tokenizer'])
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--native', type=Path)
    parser.add_argument('--models', type=Path)
    parser.add_argument('--query-model', type=Path)
    parser.add_argument('--original-socket'); parser.add_argument('--port-socket')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--flutter', default='flutter'); parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    report = {'suite': args.suite, 'status': 'failed'}
    try:
        if args.suite in ('models', 'virtual-audio') and args.models is None: parser.error('--models is required')
        if args.suite != 'fast' and args.bundle is None: parser.error('--bundle is required')
        with tempfile.TemporaryDirectory(prefix='of-ci-', dir='/tmp') as directory:
            env = dict(os.environ) if args.suite == 'fast' else bundle_environment(args.bundle, os.environ)
            env['TMPDIR'] = directory
            # Model fixtures are mounted read-only; compilation caches are disposable.
            env['FORESIGHT_LITERT_CACHE'] = str(Path(directory) / 'litert-cache')
            if args.suite == 'fast': result = fast_gate(args, env)
            elif args.suite == 'models': result = models_gate(args, env)
            elif args.suite == 'virtual-audio': result = audio_gate(args, env)
            else: result = reference_gate(args, env)
        report.update(status='passed', result=result)
    finally:
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__': main()
