#!/usr/bin/env python3
"""Check preview ordering with the native distribution's version comparator."""

import subprocess
import sys

from package_linux import PREVIEW_VERSION, native_version


def verify(kind, version):
    match = PREVIEW_VERSION.fullmatch(version)
    if not match:
        return
    current, release = native_version(version, "1", kind)
    stable = match[1]
    if kind == "deb":
        subprocess.run(
            [
                "dpkg",
                "--compare-versions",
                current + "-" + release,
                "lt",
                stable + "-1",
            ],
            check=True,
            timeout=30,
        )
    elif kind == "rpm":
        import rpm

        if rpm.labelCompare(("0", current, release), ("0", stable, "1")) >= 0:
            raise ValueError("Preview RPM must sort below the intended stable release")
    elif kind == "arch":
        result = subprocess.check_output(
            ["vercmp", current + "-" + release, stable + "-1"], text=True, timeout=30
        )
        if int(result) >= 0:
            raise ValueError(
                "Preview Arch package must sort below the intended stable release"
            )
    else:
        raise ValueError("Unsupported package format")
    print(f"Verified preview upgrade ordering: {kind} {current}-{release} < {stable}-1")


if __name__ == "__main__":
    verify(*sys.argv[1:])
