#!/usr/bin/env python3
"""Fail before native work when an existing CMake cache embeds a dead Python."""

import os
from pathlib import Path
import re
import sys


def verify(cache):
    cache = Path(cache)
    if not cache.is_file():
        return
    match = re.search(r"^Python3_EXECUTABLE:[^=]+=([^\n]+)$", cache.read_text(), re.M)
    if match and not (Path(match[1]).is_file() and os.access(match[1], os.X_OK)):
        raise ValueError(
            f"Cached Python interpreter no longer exists or is not executable: {match[1]}. Remove the stale build tree or reconfigure it with the current Python3_EXECUTABLE."
        )


if __name__ == "__main__":
    try:
        verify(sys.argv[1])
    except ValueError as error:
        raise SystemExit(str(error)) from error
