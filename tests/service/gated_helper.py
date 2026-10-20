#!/usr/bin/env python3
"""A ForesightHelper stand-in that holds SIGTERM until a test releases it.

Usage: gated_helper.py CONTROL_DIRECTORY [helper arguments...]

The service starts its helper with the socket and storage paths; this fixture
ignores them. It writes CONTROL_DIRECTORY/started (its pid) once its SIGTERM
handler is installed. On SIGTERM it writes CONTROL_DIRECTORY/stopping, then
exits 0 only after CONTROL_DIRECTORY/release exists. A service closing this
helper is therefore held inside its helper shutdown, with its profile lock.

The Dart fixture (package:foresight_test_support/gated_helper.dart) and the
built-service suite (tests/service/gated_helper.py) run byte-identical copies.
"""

import os
import pathlib
import signal
import sys
import time

control = pathlib.Path(sys.argv[1])


def publish(name):
    # Readers poll for these files; never expose a partly written pid.
    staging = control / f".{name}.{os.getpid()}"
    staging.write_text(str(os.getpid()))
    staging.replace(control / name)


def shutdown(signum, frame):
    publish("stopping")
    # Polling only delays the release; the test decides when it happens.
    while not (control / "release").exists():
        time.sleep(0.005)
    raise SystemExit(0)


signal.signal(signal.SIGTERM, shutdown)
publish("started")
while True:
    signal.pause()
