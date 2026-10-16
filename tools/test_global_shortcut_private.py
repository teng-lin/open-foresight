#!/usr/bin/env python3
"""Run global shortcut acceptance in a nested Hyprland on an owned headless desktop."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--agent-desktop', type=Path, default=ROOT.parent / 'agent-desktop')
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--model-python', type=Path, default=Path(os.environ.get('FORESIGHT_MODEL_PYTHON', ROOT / '.venv/bin/python')))
    parser.add_argument('--render-device', type=Path)
    parser.add_argument('--model-manifest', type=Path, default=ROOT / 'models/local/native/installed.json')
    parser.add_argument('--expect-embedding-backend')
    parser.add_argument('--report', type=Path, default=ROOT / 'test-results/global-shortcut-private.json')
    args = parser.parse_args()
    device = args.render_device or next(iter(sorted(Path('/dev/dri').glob('renderD*'))), None)
    assert device and device.exists(), 'A GPU render node is required by nested Hyprland'
    assert device.name.startswith('renderD'), 'Use a render node, not a modesetting device'
    host_config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'hypr/bindings.lua'
    original_hash = hashlib.sha256(host_config.read_bytes()).hexdigest() if host_config.exists() else None
    desk = ['uv', 'run', '--directory', str(args.agent_desktop), '--no-sync', 'agent-desktop']
    parent_env = {**os.environ, 'AGENT_DESKTOP_RENDERER': 'gles2', 'AGENT_DESKTOP_RENDER_DEVICE': str(device)}
    def desktop(*arguments):
        return json.loads(subprocess.check_output(desk + list(arguments), text=True, env=parent_env))
    session = None
    report = None
    # Hyprland appends its instance signature to AF_UNIX paths (108-byte limit).
    # A long build TMPDIR can make IPC unusable before the app even launches.
    with tempfile.TemporaryDirectory(prefix='fh-', dir='/tmp') as temporary:
        root = Path(temporary)
        runtime, config, commands = root / 'r', root / 'c', root / 'bin'
        for path in (runtime, config, commands, config / 'hypr'):
            path.mkdir(mode=0o700)
        main_config = config / 'hypr/hyprland.lua'
        main_config.write_text('dofile("/usr/share/omarchy/default/hypr/helpers.lua")\n'
                               'dofile(os.getenv("XDG_CONFIG_HOME") .. "/hypr/bindings.lua")\n')
        (config / 'hypr/bindings.lua').write_text('-- Owned shortcut acceptance configuration\n')
        starter = root / 'start-inner'
        starter.write_text('#!/bin/sh\nset -eu\n' +
                           'export XDG_RUNTIME_DIR=' + shlex.quote(str(runtime)) + '\n' +
                           'export XDG_CONFIG_HOME=' + shlex.quote(str(config)) + '\n' +
                           'export LIBSEAT_BACKEND=foresight-disabled\nexport AQ_DRM_DEVICES=/dev/null\n'
                           'export HYPRLAND_NO_SD_NOTIFY=1\nexport HYPRLAND_NO_SD_VARS=1\n'
                           'exec /usr/bin/Hyprland --config ' + shlex.quote(str(main_config)) + '\n')
        starter.chmod(0o700)
        try:
            session = desktop('create', '--mode', 'headless', '--guard-host')['session']
            inner = desktop('launch', session, '--', str(starter))
            deadline = time.monotonic() + 30
            while True:
                sockets = list((runtime / 'hypr').glob('*/.socket.sock'))
                if sockets:
                    assert len(sockets) == 1
                    signature = sockets[0].parent.name
                    break
                job = next(x for x in desktop('status', session)['applications'] if x['pid'] == inner['pid'])
                if job['exit_code'] is not None or time.monotonic() > deadline:
                    raise RuntimeError('Private Hyprland failed: ' + Path(inner['logs']).read_text()[-3000:])
                time.sleep(.2)
            displays = [path for path in runtime.glob('wayland-*') if path.is_socket()]
            assert len(displays) == 1
            display = displays[0]
            proxy = commands / 'hyprctl'
            # The exception to the session's command guard accepts only this
            # owned compositor. Missing/mismatched context never falls back.
            proxy.write_text('#!/bin/sh\nset -eu\n' +
                             '[ "${XDG_RUNTIME_DIR:-}" = ' + shlex.quote(str(runtime)) + ' ] || exit 91\n' +
                             '[ "${HYPRLAND_INSTANCE_SIGNATURE:-}" = ' + shlex.quote(signature) + ' ] || exit 92\n' +
                             '[ -S ' + shlex.quote(str(sockets[0])) + ' ] || exit 93\n' +
                             'exec /usr/bin/hyprctl --instance ' + shlex.quote(signature) + ' "$@"\n')
            proxy.chmod(0o700)
            scoped = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'HYPRLAND_INSTANCE_SIGNATURE': signature}
            def control(*arguments):
                return subprocess.check_output(['/usr/bin/hyprctl', '--instance', signature, *arguments], env=scoped, text=True)
            monitors = json.loads(control('monitors', '-j'))
            assert monitors and all(x['name'].startswith(('WAYLAND-', 'HEADLESS-')) for x in monitors)
            descriptors = [str(path.readlink()) for path in Path(f'/proc/{inner["pid"]}/fd').iterdir() if path.exists()]
            assert not any(value.startswith('/dev/input/') or value.startswith('/dev/dri/card') for value in descriptors)
            sentinel = desktop('launch', session, '--', 'env', 'XDG_RUNTIME_DIR=' + str(runtime),
                               'WAYLAND_DISPLAY=' + str(display), 'GDK_BACKEND=wayland',
                               '/usr/bin/foot', '--config=/dev/null', '--title=Foresight-shortcut-sentinel', '/bin/sleep', '600')
            deadline = time.monotonic() + 20
            while json.loads(control('activewindow', '-j')).get('pid') != sentinel['pid']:
                if time.monotonic() > deadline:
                    raise TimeoutError('Private focus sentinel did not map')
                time.sleep(.2)
            keyboard = root / 'keyboard'
            flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True))
            subprocess.run(['cc', str(ROOT / 'tools/hotkey_keyboard.c'), '-o', str(keyboard), *flags], check=True)
            test_report = root / 'report.json'
            model_options = ' --model-python ' + shlex.quote(str(args.model_python.expanduser().absolute())) + ' --model-manifest ' + shlex.quote(str(args.model_manifest.resolve()))
            if args.expect_embedding_backend:
                model_options += ' --expect-embedding-backend ' + shlex.quote(args.expect_embedding_backend)
            runner = root / 'run-test'
            runner.write_text('#!/bin/sh\nset -eu\n' +
                              '\n'.join('export ' + key + '=' + shlex.quote(value) for key, value in {
                                  'XDG_RUNTIME_DIR': str(runtime), 'XDG_CONFIG_HOME': str(config),
                                  'WAYLAND_DISPLAY': str(display), 'HYPRLAND_INSTANCE_SIGNATURE': signature,
                                  'PULSE_SERVER': f'unix:/run/user/{os.getuid()}/pulse/native',
                                  'PIPEWIRE_REMOTE': f'/run/user/{os.getuid()}/pipewire-0', 'GDK_BACKEND': 'wayland',
                              }.items()) + '\n' +
                              'export PATH=' + shlex.quote(str(commands)) + ':$PATH\n' +
                              'cd ' + shlex.quote(str(ROOT)) + '\nexec python tools/test_global_shortcut.py ' +
                              shlex.quote(str(args.bundle.resolve())) + ' --keyboard ' + shlex.quote(str(keyboard)) +
                              ' --dart ' + shlex.quote(args.dart) + ' --private-runtime ' + shlex.quote(str(runtime)) +
                              ' --private-config ' + shlex.quote(str(config)) + model_options + ' --report ' + shlex.quote(str(test_report)) + '\n')
            runner.chmod(0o700)
            launched = desktop('launch', session, '--', str(runner))
            print(json.dumps({'private_session': session, 'test_pid': launched['pid'], 'logs': launched['logs']}), flush=True)
            deadline = time.monotonic() + 180
            while True:
                job = next(x for x in desktop('status', session)['applications'] if x['pid'] == launched['pid'])
                if job['exit_code'] is not None:
                    if job['exit_code'] != 0:
                        raise RuntimeError(Path(launched['logs']).read_text()[-6000:])
                    break
                if time.monotonic() > deadline:
                    raise TimeoutError('Private shortcut acceptance exceeded 180 seconds')
                time.sleep(2)
            report = json.loads(test_report.read_text())
            report.update({'render_only_device': True, 'physical_seat_disabled': True,
                           'physical_input_or_modesetting_descriptors_absent': True,
                           'output_geometry': [{key: item[key] for key in ('width', 'height', 'scale')} for item in monitors],
                           'package_revision': json.loads((args.bundle / 'manifest.json').read_text())['revision']})
        finally:
            if session is not None:
                result = desktop('destroy', session)
                assert result['status'] == 'stopped'
            current_hash = hashlib.sha256(host_config.read_bytes()).hexdigest() if host_config.exists() else None
            assert current_hash == original_hash, 'Host binding file changed during private acceptance'
        assert report is not None
        report.update({'private_session_stopped': True, 'host_binding_file_unchanged': True,
                       'limitations': ['Virtual microphone is silent; this tests shortcut/capture ownership, not physical speech',
                                       'Nested output scale is recorded; this is not pixel-parity acceptance',
                                       'Other desktop shortcut portals have separate unverified keyboard behavior']})
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
