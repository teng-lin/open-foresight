#!/usr/bin/env python3
"""Regenerate all shipped Dart protobufs and fail on drift (or --write)."""
import argparse
import difflib
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DESTINATIONS = [ROOT / 'packages/foresight_core/lib/src/generated',
                ROOT / 'apps/desktop/lib/generated']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    parser.add_argument('--protoc', default='protoc')
    args = parser.parse_args()
    drift = False
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        subprocess.run([sys.executable, str(ROOT / 'tools/generate_bindings.py'),
                        '--language', 'dart', '--output', str(output),
                        '--protoc', args.protoc], check=True)
        for directory, name in [('linux', 'helper_control'), ('foresight', 'web_content')]:
            subprocess.run([args.protoc, f'-I{ROOT / "proto" / directory}',
                            f'--dart_out=grpc:{output}', f'{name}.proto'], check=True)
        generated_names = {file.name for file in output.glob('*.dart')}
        for destination in DESTINATIONS:
            stale = {file.name for file in destination.glob('*.dart')} - generated_names
            if stale:
                raise SystemExit(f'Stale generated Dart files in {destination}: {sorted(stale)}')
        for generated in sorted(output.glob('*.dart')):
            for destination in DESTINATIONS:
                target = destination / generated.name
                # Desktop files are forwarding exports, never independent bindings.
                if destination == DESTINATIONS[1] and not target.exists():
                    continue
                expected = (generated.read_text() if destination == DESTINATIONS[0]
                    else f"export 'package:foresight_core/src/generated/{generated.name}';\n")
                actual = target.read_text() if target.exists() else ''
                if expected == actual:
                    continue
                if args.write:
                    target.write_text(expected)
                else:
                    drift = True
                    print(''.join(difflib.unified_diff(actual.splitlines(True),
                        expected.splitlines(True), fromfile=str(target.relative_to(ROOT)),
                        tofile='regenerated/' + generated.name)))
    if drift:
        raise SystemExit('Dart bindings drifted; run tools/check_dart_bindings.py --write with protoc_plugin 24.0.0')


if __name__ == '__main__':
    main()
