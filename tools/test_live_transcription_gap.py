#!/usr/bin/env python3
"""Verify real Whisper transcription across an owned virtual microphone outage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--manifest', type=Path,
                        default=ROOT / 'models/local/native/installed-gemma-macos-gpu.json')
    parser.add_argument('--bundle', type=Path, default=ROOT / 'dist/open-foresight')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--log', type=Path, required=True)
    args = parser.parse_args()
    speech = json.loads(args.manifest.read_text())['speech']
    model = Path(speech['model'])
    if hashlib.sha256(model.read_bytes()).hexdigest() != speech['sha256']:
        raise ValueError('Speech model checksum mismatch')
    library = args.bundle.resolve() / 'lib/libforesight_native.so'
    environment = dict(os.environ, FORESIGHT_LIVE_GAP_TEST='1',
                       FORESIGHT_NATIVE=str(library),
                       FORESIGHT_SPEECH_RUNNER=speech['runtime'],
                       FORESIGHT_SPEECH_MODEL=str(model),
                       FORESIGHT_AUDIO_FIXTURE=str(ROOT / 'tests/fixtures/audio/jfk.wav'),
                       FORESIGHT_LIVE_GAP_REPORT=str(args.report.resolve()))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open('w') as log:
        result = subprocess.run([
            args.flutter, 'test', '--no-pub', '--reporter', 'expanded',
            'test/live_gap_recording_test.dart'], cwd=ROOT / 'apps/desktop',
            env=environment, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print(args.log.read_text()[-6000:])
        raise SystemExit(result.returncode)
    report = json.loads(args.report.read_text())
    report.update(speech_model_sha256=speech['sha256'],
                  speech_runtime_sha256=hashlib.sha256(Path(environment.get('FORESIGHT_WHISPER_RUNTIME', speech['runtime'])).read_bytes()).hexdigest(),
                  requested_speech_backend=environment.get('FORESIGHT_WHISPER_BACKEND', 'runner-default'),
                  requested_speech_device=environment.get('FORESIGHT_WHISPER_DEVICE'),
                  native_library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  recording_source_sha256=hashlib.sha256((ROOT / 'apps/desktop/lib/recording.dart').read_bytes()).hexdigest(),
                  test_source_sha256=hashlib.sha256((ROOT / 'apps/desktop/test/live_gap_recording_test.dart').read_bytes()).hexdigest(),
                  bundle_revision=json.loads((args.bundle / 'manifest.json').read_text())['revision'],
                  acceptance_passed=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'acceptance_passed': True, 'report': str(args.report)}))


if __name__ == '__main__':
    main()
