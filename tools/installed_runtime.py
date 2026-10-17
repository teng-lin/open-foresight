"""Platform-neutral ownership checks for disposable installed-app acceptance."""

import os
from pathlib import Path
import platform
import subprocess
import time

from install_macos import process_path as mac_process_path


def process_path(pid):
    if platform.system() == "Darwin":
        return mac_process_path(pid)
    try:
        return Path(f"/proc/{pid}/exe").resolve(strict=True)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None


def layout(bundle):
    bundle = Path(bundle).resolve(strict=True)
    if bundle.suffix == ".app":
        return (
            bundle / "Contents/MacOS/foresight-mcp",
            bundle
            / "Contents/Library/Services/Open Foresight Service.app/Contents/MacOS/foresight-service",
        )
    return bundle / "open-foresight-mcp", bundle / "bin/foresight-service"


def service_command(service, env, action):
    # Linux launches must use the installed wrapper's own runtime configuration.
    launcher = service.parent.parent / "open-foresight-service"
    command = launcher if launcher.is_file() else service
    result = subprocess.run(
        [str(command), action],
        cwd="/",
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    if action == "--status":
        import json

        return json.loads(result.stdout)


def wait_stopped(pid, executable, timeout=30):
    deadline = time.monotonic() + timeout
    while process_path(pid) == executable.resolve():
        if time.monotonic() >= deadline:
            raise TimeoutError("Installed service did not stop")
        time.sleep(0.05)


def clean_environment(home, data, runtime):
    """Permit display plumbing and isolated profiles, never runtime overrides."""
    env = {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "FORESIGHT_DATA": str(data),
        "FORESIGHT_RUNTIME": str(runtime),
    }
    for key in (
        "DISPLAY",
        "XAUTHORITY",
        "DBUS_SESSION_BUS_ADDRESS",
        "LANG",
        "XDG_RUNTIME_DIR",
    ):
        if key in os.environ:
            env[key] = os.environ[key]
    return env
