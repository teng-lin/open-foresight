#!/usr/bin/env python3
"""Remove completed runtime compiler scratch, including read-only Bazel trees."""

import os
from pathlib import Path
import shutil
import stat

ROOT = Path(__file__).resolve().parents[1]


def remove_sources(path):
    """Make owned directories removable without following external symlinks."""
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Runtime source directory must not be a symlink")
    if not path.exists():
        return
    # Removing a file requires write permission on its parent, not on the file.
    # Top-down traversal also handles directories without owner read/execute.
    path.chmod(stat.S_IMODE(path.stat().st_mode) | stat.S_IRWXU)
    for parent, directories, _ in os.walk(path, followlinks=False):
        for name in directories:
            directory = Path(parent) / name
            if not directory.is_symlink():
                directory.chmod(stat.S_IMODE(directory.stat().st_mode) | stat.S_IRWXU)
    shutil.rmtree(path)


if __name__ == "__main__":
    remove_sources(ROOT / "build/macos-runtime-sources")
