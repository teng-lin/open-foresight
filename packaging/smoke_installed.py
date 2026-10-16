#!/usr/bin/env python3
"""Exercise installed files as an ordinary user in a disposable Xvfb session.

A pinned Tiny model and public speech fixture exercise CPU decoding only in a
temporary directory. No account, microphone, physical display, or host profile
is used. GPU/audio/portal acceptance belongs to separate hardware tests.
"""
import json
import hashlib
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request


def main():
    root = Path('/opt/open-foresight')
    assert os.getuid() != 0, 'Run the application smoke test as a normal user'
    env = dict(os.environ, LD_LIBRARY_PATH=f'{root}/lib:{root}/app/lib:{root}/share/open-foresight/python/lib',
               LIBGL_ALWAYS_SOFTWARE='1', GDK_BACKEND='x11')
    # Check all runtime ELFs, including dlopen-only Python extensions. This
    # catches host dependencies that an executable-only ldd check misses.
    count = 0
    for file in root.rglob('*'):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        linked = subprocess.run(['ldd', str(file)], env=env, capture_output=True, text=True)
        assert 'not found' not in linked.stdout + linked.stderr, (file, linked.stdout, linked.stderr)
        count += 1
    assert count > 0
    subprocess.run([str(root / 'share/open-foresight/litert-runner'), '--check'],
                   env=env, check=True, timeout=30)
    subprocess.run([str(root / 'bin/whisper-cli-vulkan'), '--help'],
                   env=env, check=True, capture_output=True, timeout=30)
    with tempfile.TemporaryDirectory(prefix='foresight-install-') as temp:
        private = Path(temp)
        model = private / 'ggml-tiny.bin'
        request = urllib.request.Request(
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
            '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin',
            headers={'User-Agent': 'open-foresight-ci'})
        with urllib.request.urlopen(request, timeout=90) as response, model.open('wb') as output:
            while block := response.read(1024 * 1024):
                output.write(block)
        with model.open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21'
        fixture = Path(__file__).resolve().parents[1] / 'tests/fixtures/audio/jfk.wav'
        decoded = subprocess.run([str(root / 'bin/whisper-cli-vulkan'), '-ng', '-t', '2',
                                  '-m', str(model), '-f', str(fixture), '-l', 'en', '-nt'],
                                 env=env, check=True, capture_output=True, text=True, timeout=90)
        assert 'country' in decoded.stdout.lower(), decoded.stdout + decoded.stderr
        data, runtime = private / 'data', private / 'run'
        env.update(FORESIGHT_DATA=str(data), FORESIGHT_RUNTIME=str(runtime))
        log = private / 'desktop.log'
        with log.open('w') as output:
            app = subprocess.Popen(['/usr/bin/open-foresight'], env=env,
                                   cwd='/', stdout=output, stderr=output, start_new_session=True)
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    assert app.poll() is None, log.read_text()
                    if (data / 'application.db').exists() and (runtime / 'helper.sock').exists():
                        break
                    time.sleep(.25)
                else:
                    raise TimeoutError(log.read_text())
                with socket.socket(socket.AF_UNIX) as command:
                    command.settimeout(5)
                    command.connect(str(runtime / 'commands.sock'))
                    command.sendall(b'{"version":1,"command":"activate"}\n')
                    assert command.recv(128).strip() == b'accepted'
                with sqlite3.connect(data / 'application.db') as db:
                    assert db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
                    assert db.execute('SELECT count(*) FROM models').fetchone()[0] == 0
                assert data.stat().st_mode & 0o077 == 0
                assert runtime.stat().st_mode & 0o077 == 0
                time.sleep(3)
                assert app.poll() is None, log.read_text()
                print(json.dumps({'installed_startup': True, 'activation_ipc': True,
                                  'elf_linkage_files': count, 'private_profile': True,
                                  'litert_import': True, 'whisper_cli': True,
                                  'whisper_cpu_fixture': True,
                                  'physical_audio_or_gpu_inference_tested': False}))
            finally:
                os.killpg(app.pid, signal.SIGTERM) if app.poll() is None else None
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait()


if __name__ == '__main__':
    main()
