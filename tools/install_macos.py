#!/usr/bin/env python3
"""Install/upgrade only Open Foresight; defer live apps unless owned services can stop.

No default destination: use --destination explicitly. This never targets the
reference Google Foresight app. Ad-hoc development installs require opt-in.
A shared per-installation kernel lock prevents service startup during exchange.
All profiles of the same installed application participate in that lock.
"""

import argparse
import ctypes
from contextlib import contextmanager
import fcntl
import hashlib
import stat
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
import sys
import tempfile
import time

IDENTIFIER = "io.openforesight.App"
SERVICE = Path(
    "Contents/Library/Services/Open Foresight Service.app/Contents/MacOS/foresight-service"
)


class Deferred(RuntimeError):
    pass


def metadata(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != IDENTIFIER:
        raise ValueError(f"Refusing a different application identity: {app}")
    return info


def verify_signature(app):
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        check=True,
        capture_output=True,
        timeout=300,
    )
    details = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    ).stderr
    values = dict(line.split("=", 1) for line in details.splitlines() if "=" in line)
    if values.get("Identifier") != IDENTIFIER:
        raise ValueError("Signed application identifier differs from Open Foresight")
    return {"team": values.get("TeamIdentifier"), "adhoc": "Signature=adhoc" in details}


def process_path(pid):
    if sys.platform != "darwin":
        raise RuntimeError("Executable ownership checks require macOS")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return Path(os.fsdecode(buffer.value)).resolve()


def processes_in_bundle(app):
    root = app.resolve()
    output = subprocess.check_output(
        ["/bin/ps", "-axo", "pid="], text=True, timeout=300
    )
    found = {}
    for value in output.split():
        pid = int(value)
        path = process_path(pid)
        if path is not None and path.is_relative_to(root):
            found[pid] = str(path)
    return found


def minimal_environment(home, profile=None):
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    if sys.platform == "darwin":
        # ProfilePaths validates the private user temp directory before profile
        # endpoint discovery, even when the live service uses a runtime override.
        env["TMPDIR"] = os.environ.get("TMPDIR", tempfile.gettempdir())
    if profile is not None:
        env["FORESIGHT_DATA"] = str(Path(profile).resolve())
    return env


def stop_owned_services(app, active, profiles, timeout=1800):
    executable = (app / SERVICE).resolve()
    if not profiles:
        raise Deferred(
            "Specify --profile for each running service, or close the app and retry"
        )
    services = {pid for pid, path in active.items() if Path(path) == executable}
    owners = {}
    for profile in profiles:
        env = minimal_environment(Path.home(), profile)
        response = subprocess.run(
            [str(executable), "--status"],
            cwd="/",
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if response.returncode:
            raise Deferred(
                f"Cannot authenticate service ownership for profile {profile}: {response.stderr.strip()}"
            )
        state = json.loads(response.stdout)
        pid = state["pid"]
        if pid not in active or process_path(pid) != executable:
            raise Deferred(f"Profile {profile} is not owned by this installed service")
        if state.get("capture", {}).get("active") or state.get("capture", {}).get(
            "finishing"
        ):
            raise Deferred(
                f"Recording is active for profile {profile}. Stop recording and wait for the final transcript before upgrading; the application was not replaced"
            )
        owners[pid] = env
    if set(owners) != services:
        raise Deferred(
            "Some running service profiles were not supplied; upgrade deferred"
        )
    parents = {
        int(pid): int(parent)
        for pid, parent in (
            line.split()
            for line in subprocess.check_output(
                ["/bin/ps", "-axo", "pid=,ppid="], text=True, timeout=300
            ).splitlines()
            if line.strip()
        )
    }
    for pid in set(active) - services:
        seen, ancestor = set(), pid
        while ancestor not in services and ancestor in parents and ancestor not in seen:
            seen.add(ancestor)
            ancestor = parents[ancestor]
        if ancestor not in services:
            raise Deferred(
                "The desktop, MCP client, or an unrelated worker is running. Close clients before upgrading"
            )
    # The preliminary status check gives an early deferral, but only the
    # serialized service operation can close the recording-start race. A
    # positive structured acknowledgement certifies successful resource cleanup;
    # EOF, an unsupported old CLI, or a failed close all defer replacement.
    for pid, env in owners.items():
        if process_path(pid) != executable:
            raise Deferred("Service identity changed before shutdown; retry")
        response = subprocess.run(
            [str(executable), f"--stop-if-idle={pid}"],
            cwd="/",
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if response.returncode:
            raise Deferred(
                f"Idle service shutdown was refused or failed; app was not replaced: {response.stderr.strip()}"
            )
        try:
            acknowledgement = json.loads(response.stdout)
        except (ValueError, TypeError) as error:
            raise Deferred(
                "Service shutdown was not explicitly acknowledged; app was not replaced"
            ) from error
        if (
            not isinstance(acknowledgement, dict)
            or acknowledgement.get("stopped") is not True
            or acknowledgement.get("shutdown_verified") is not True
        ):
            raise Deferred("Service did not verify idle shutdown; app was not replaced")
        deadline = time.monotonic() + 15
        while process_path(pid) == executable and time.monotonic() < deadline:
            time.sleep(0.05)
        if process_path(pid) == executable:
            raise Deferred(
                "Service is still running after graceful shutdown; app was not replaced"
            )


def copy_application(source, destination):
    if sys.platform == "darwin":
        # shutil.copytree on macOS omits extended attributes/resource forks.
        # Retain quarantine and stapled-ticket metadata rather than bypassing it.
        subprocess.run(
            [
                "/usr/bin/ditto",
                "--rsrc",
                "--extattr",
                "--qtn",
                "--acl",
                str(source),
                str(destination),
            ],
            check=True,
            env=minimal_environment(Path.home()),
            capture_output=True,
            timeout=300,
        )
    else:
        shutil.copytree(source, destination, symlinks=True)


def installation_lock_path(app):
    identity = hashlib.sha256(str(Path(app).resolve()).encode("utf-8")).hexdigest()[:24]
    home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    cache = (
        home / "Library/Caches/io.openforesight.App"
        if sys.platform == "darwin"
        else home / ".cache/open-foresight"
    )
    return cache / "install-locks" / identity / "lock"


def legacy_installation_lock_path(app):
    identity = hashlib.sha256(str(Path(app).resolve()).encode("utf-8")).hexdigest()[:24]
    # macOS /tmp is the system alias for /private/tmp. Start at its fixed
    # canonical directory so every untrusted descendant remains O_NOFOLLOW.
    temporary = Path("/private/tmp" if sys.platform == "darwin" else "/tmp")  # noqa: S108 - Released lock protocol bridge only.
    return temporary / f"of-install-{os.getuid()}-{identity}" / "lock"


@contextmanager
def _installation_lock_file(path):
    """Open each ancestor without following links; validate the opened inode."""
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    fd = None
    try:
        for index, component in enumerate(path.parts[1:-1]):
            try:
                os.mkdir(component, mode=0o700, dir_fd=directory)
            except FileExistsError:
                pass
            child = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory,
            )
            os.close(directory)
            directory = child
            info = os.fstat(directory)
            private = index == len(path.parts) - 3
            writable = info.st_mode & (0o077 if private else 0o022)
            shared_temporary = (
                not private and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
            )
            if info.st_uid not in {0, os.getuid()} or (
                writable and not shared_temporary
            ):
                raise ValueError(
                    "Installation lock directory must be private and user-owned"
                )
        fd = os.open(
            path.name,
            os.O_CREAT | os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=directory,
        )
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
            or info.st_nlink != 1
        ):
            raise ValueError(
                "Installation lock must be a private user-owned regular file"
            )
        yield fd
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


@contextmanager
def installation_lock(app, *, exclusive=True):
    # Incoming installers hold the legacy lock too: an old service racing an
    # upgrade must refuse to launch before the application exchange finishes.
    # New services never allocate locks in shared temporary storage.
    with _installation_lock_file(installation_lock_path(app)) as fd:
        try:
            fcntl.flock(
                fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB
            )
        except BlockingIOError as error:
            raise Deferred(
                "Application service or another installer acquired the installation lock; retry after it exits"
            ) from error
        if not exclusive:
            yield
            return
        with _installation_lock_file(legacy_installation_lock_path(app)) as legacy:
            try:
                fcntl.lockf(legacy, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise Deferred(
                    "A released application service holds the legacy installation lock; retry after it exits"
                ) from error
            yield


def atomic_swap(first, second):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    library.renamex_np.restype = ctypes.c_int
    if library.renamex_np(os.fsencode(first), os.fsencode(second), 2):  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def install(
    source,
    destination,
    *,
    allow_adhoc=False,
    stop_services=False,
    profiles=(),
    verify=verify_signature,
    active=processes_in_bundle,
    stopper=stop_owned_services,
    swap=atomic_swap,
):
    source, destination = Path(source).absolute(), Path(destination).absolute()
    if source.is_symlink() or destination.is_symlink():
        raise ValueError("Application roots must not be symbolic links")
    source = source.resolve()
    if (
        source.suffix != ".app"
        or destination.suffix != ".app"
        or source == destination.resolve()
    ):
        raise ValueError("Choose distinct source/destination .app directories")
    if source.is_relative_to(
        destination.resolve()
    ) or destination.resolve().is_relative_to(source):
        raise ValueError("Source and destination must not contain each other")
    metadata(source)
    incoming = verify(source)
    if incoming["adhoc"] and not allow_adhoc:
        raise ValueError("Ad-hoc development installs require --allow-ad-hoc")
    if destination.exists():
        metadata(destination)
        previous = verify(destination)
        if (
            previous["team"] != incoming["team"]
            or previous["adhoc"] != incoming["adhoc"]
        ):
            raise ValueError(
                "Upgrade signing team/type differs from the installed application"
            )
        running = active(destination)
        if running:
            if not stop_services:
                raise Deferred(
                    f"Installed application is running ({sorted(running)}); upgrade deferred"
                )
            stopper(destination, running, profiles)
            if active(destination):
                raise Deferred(
                    "Installed application still has live processes; upgrade deferred"
                )
    destination.parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(destination):
        if destination.exists() and active(destination):
            raise Deferred(
                "Application launched before maintenance lock acquisition; upgrade deferred"
            )
        # Staging beneath the destination parent guarantees the same filesystem.
        temp = tempfile.mkdtemp(
            prefix=".open-foresight-install-", dir=destination.parent
        )
        cleanup = True
        try:
            stage = Path(temp) / destination.name
            copy_application(source, stage)
            metadata(stage)
            if verify(stage) != incoming:
                raise ValueError("Staged signature identity changed during copying")
            if destination.exists() and active(destination):
                raise Deferred("Application launched while staging; upgrade deferred")
            existed = destination.exists()
            if existed:
                swap(
                    stage, destination
                )  # Atomic exchange of complete nonempty bundles.
            else:
                os.replace(stage, destination)
            try:
                if verify(destination) != incoming:
                    raise ValueError("Installed signature identity changed")
            except BaseException:
                try:
                    if existed:
                        swap(stage, destination)
                    else:
                        os.replace(destination, stage)
                except BaseException as rollback_error:
                    cleanup = False
                    raise RuntimeError(
                        f"Rollback failed; preserved recovery bundle at {stage}"
                    ) from rollback_error
                raise
        finally:
            if cleanup:
                shutil.rmtree(temp)
    return {
        "installed": str(destination),
        "identifier": IDENTIFIER,
        "signing": "ad-hoc-development" if incoming["adhoc"] else "developer-id",
        "upgraded": existed,
        "maintenance_lock": "exclusive",
        "rollback": "available until post-swap signature verification completes",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument(
        "--defer-if-running",
        action="store_true",
        help="Default: leave running applications unchanged",
    )
    parser.add_argument(
        "--stop-services",
        action="store_true",
        help="Stop verified idle services; defer active recordings until final transcription finishes",
    )
    parser.add_argument("--profile", type=Path, action="append", default=[])
    parser.add_argument("--allow-ad-hoc", action="store_true")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("Installation requires macOS")
    if args.defer_if_running and args.stop_services:
        parser.error("Choose defer-if-running or stop-services")
    try:
        print(
            json.dumps(
                install(
                    args.source,
                    args.destination,
                    allow_adhoc=args.allow_ad_hoc,
                    stop_services=args.stop_services,
                    profiles=args.profile,
                )
            )
        )
    except Deferred as error:
        print(json.dumps({"status": "deferred", "reason": str(error)}))
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
