"""Exercise the production Keychain ACL with separate ad-hoc signed principals.

This requires an actual macOS Security server, not a mocked Keychain. The user's
default keychain and search list are restored even when assertions fail.
"""

import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile


def run(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, timeout=20, check=check)


def security(*args, check=True):
    return run("/usr/bin/security", *args, check=check)


def code_hash(executable):
    result = run("/usr/bin/codesign", "--display", "--verbose=4", str(executable))
    return re.search(r"^CDHash=(\S+)$", result.stderr, re.MULTILINE).group(1)


def main():
    fixture = Path(sys.argv[1]).resolve()
    default = shlex.split(security("default-keychain", "-d", "user").stdout)
    search = shlex.split(security("list-keychains", "-d", "user").stdout)
    if len(default) != 1:
        raise AssertionError(f"Expected one default keychain, got {default!r}")
    root = os.environ.get("FORESIGHT_TEST_TEMP_ROOT")
    with tempfile.TemporaryDirectory(
        prefix="foresight-keychain-acl-", dir=root
    ) as temp:
        directory = Path(temp)
        keychain = directory / "private.keychain-db"
        password = secrets.token_urlsafe(24)
        service = "org.openforesight.acl-test." + secrets.token_hex(8)
        secret = "private-fixture-" + secrets.token_hex(24)
        owner, outsider = directory / "service", directory / "unrelated-reader"
        for path, identity in (
            (owner, "org.openforesight.test.service"),
            (outsider, "org.openforesight.test.unrelated"),
        ):
            shutil.copy2(fixture, path)
            run(
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                identity,
                str(path),
            )
        created = False
        try:
            security("create-keychain", "-p", password, str(keychain))
            created = True
            security("set-keychain-settings", "-lut", "3600", str(keychain))

            def invoke(principal, action):
                return run(
                    str(principal),
                    str(keychain),
                    password,
                    action,
                    service,
                    secret,
                    check=False,
                )

            written = invoke(owner, "write")
            assert written.returncode == 0, written.stderr + written.stdout
            allowed = invoke(owner, "read")
            assert allowed.returncode == 0 and allowed.stdout.strip() == secret, (
                allowed.stderr
            )
            denied = invoke(outsider, "read")
            assert denied.returncode == 5, denied.stderr + denied.stdout
            assert secret not in denied.stdout + denied.stderr
            assert "Keychain access denied: status=" in denied.stderr

            original_hash = code_hash(owner)
            # Change a retained constant at the same path, then re-sign with
            # the original identifier, preserving the Mach-O file's layout.
            run("/usr/bin/codesign", "--remove-signature", str(owner))
            executable = owner.read_bytes()
            marker = b"foresight-keychain-fixture-v1"
            assert marker in executable
            owner.write_bytes(
                executable.replace(marker, b"foresight-keychain-fixture-v2")
            )
            run(
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                "org.openforesight.test.service",
                str(owner),
            )
            run("/usr/bin/codesign", "--verify", "--strict", str(owner))
            assert code_hash(owner) != original_hash
            updated = invoke(owner, "read")
            if updated.returncode == 0:
                assert updated.stdout.strip() == secret
                update_result = "access retained by updated service"
            else:
                assert updated.returncode == 5, updated.stderr
                assert secret not in updated.stdout + updated.stderr
                assert "reconnect Google authorization" in updated.stderr
                update_result = "failed closed; reconnect authorization required"
            print(
                json.dumps(
                    {
                        "owner_read": "allowed",
                        "unrelated_reader": "denied without interaction",
                        "service_update": update_result,
                    }
                )
            )
        finally:
            # Restore both settings before deleting the disposable keychain.
            # Do not hide restoration errors behind a successful test result.
            try:
                security("default-keychain", "-d", "user", "-s", default[0])
            finally:
                try:
                    security("list-keychains", "-d", "user", "-s", *search)
                finally:
                    if created:
                        security("delete-keychain", str(keychain))


if __name__ == "__main__":
    main()
