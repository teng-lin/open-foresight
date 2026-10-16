#!/usr/bin/env python3
"""Exercise the native process identity boundary against a real helper.

Usage: test_native_process.py /path/libforesight_native.dylib /path/ForesightHelper
"""
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

library, helper = sys.argv[1:]
lib = ctypes.CDLL(library)
lib.fs_process_matches.argtypes = [ctypes.c_int64] + [ctypes.c_char_p] * 3
lib.fs_process_matches.restype = ctypes.c_int
lib.fs_set_runtime_environment.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
lib.fs_set_runtime_environment.restype = ctypes.c_int
assert lib.fs_set_runtime_environment(b'PATH', b'/invalid') == -1
assert lib.fs_set_runtime_environment(None, b'value') == -1
assert lib.fs_set_runtime_environment(b'FORESIGHT_HELPER', os.fsencode(helper)) == 0
with tempfile.TemporaryDirectory(prefix='fs-identity-', dir='/tmp') as directory:
    os.chmod(directory, 0o700)
    socket, storage = str(Path(directory) / 'helper.sock'), str(Path(directory) / 'data')
    process = subprocess.Popen([helper, socket, storage, '--allow-test-models'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(200):
            if Path(socket).exists():
                break
            assert process.poll() is None, process.stderr.read()
            time.sleep(.025)
        assert Path(socket).exists(), 'helper did not start'
        # system_clock native period is microseconds in Apple libc++,
        # nanoseconds in Linux libstdc++. The authentic ID is subsequently
        # fetched over the private helper control protocol by the Dart owner.
        stamp = time.time_ns() // (1000 if sys.platform == 'darwin' else 1)
        instance = f'{process.pid}-{stamp}'.encode()
        def matches(pid=process.pid, sock=socket, root=storage, identity=instance):
            return lib.fs_process_matches(pid, sock.encode(), root.encode(), identity)
        assert matches() == 1
        assert matches(sock=socket + '-other') == 0
        assert matches(root=storage + '-other') == 0
        assert matches(identity=b'0-1') == 0
        assert matches(pid=os.getpid()) == 0
        if sys.platform == 'darwin':
            assert matches(identity=f'{process.pid}-1'.encode()) == 0
    finally:
        process.terminate()
        process.wait(timeout=10)
print('native helper identity and environment boundary passed')
