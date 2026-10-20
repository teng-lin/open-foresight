#!/usr/bin/env python3
"""Install the fixed Linux amd64 gh used by the two Ubuntu release evidence jobs."""

import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import time
from urllib.error import URLError
from urllib.request import urlopen

VERSION = "2.102.0"
ARCHIVE = f"gh_{VERSION}_linux_amd64.tar.gz"
URL = f"https://github.com/cli/cli/releases/download/v{VERSION}/{ARCHIVE}"
# Official v2.102.0 checksums manifest and release-asset API digest agree.
SHA256 = "bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386"
SIZE = 15319960
MEMBER = f"gh_{VERSION}_linux_amd64/bin/gh"


def download():
    for attempt in range(3):
        try:
            with urlopen(URL, timeout=60) as response:  # noqa: S310 - fixed official HTTPS release.
                return response.read(SIZE + 1)
        except (URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)
    raise AssertionError("Unreachable download retry state")


def install(directory):
    data = download()
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Pinned GitHub CLI archive size/checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = [member for member in archive if member.name == MEMBER]
        if len(members) != 1 or not members[0].isfile():
            raise ValueError("Pinned GitHub CLI archive lacks its regular executable")
        source = archive.extractfile(members[0])
        if source is None:
            raise ValueError("Pinned GitHub CLI executable cannot be read")
        executable = source.read()
    binary = directory / "bin/gh"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(executable)
    binary.chmod(0o755)
    # Keep the real command's stdout/stderr in the job log; a failure cannot
    # expose this directory through GITHUB_PATH or fall back to the runner gh.
    subprocess.run([str(binary), "--version"], check=True, timeout=30)
    return binary


def main():
    directory = Path(os.environ["RUNNER_TEMP"]) / "release-evidence-gh"
    path = Path(os.environ["GITHUB_PATH"])
    binary = install(directory)
    with path.open("a") as output:
        output.write(str(binary.parent) + "\n")


if __name__ == "__main__":
    main()
