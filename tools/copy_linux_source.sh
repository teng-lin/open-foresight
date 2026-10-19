#!/usr/bin/env bash
# Copy checkout sources with identical exclusions on GNU and BSD hosts.
set -euo pipefail
"${FORESIGHT_PYTHON:-python3}" - "${1:?Source tree required}" "${2:?Destination required}" <<'PYTHON'
import fnmatch
from pathlib import Path
import shutil
import sys

source, destination = (Path(value).resolve() for value in sys.argv[1:])
if destination == source or destination.is_relative_to(source):
    raise ValueError("Source copy destination must be outside the checkout")
root_patterns = (".git", "build", "dist", ".venv*", ".pub-cache", ".dart_tool",
                 "test-results", "coverage", ".env*", ".coverage", ".coverage.*")
all_patterns = ("build", ".dart_tool", "__pycache__", "*.pyc", "*.db*", "*.log", "google-client*.json")

def ignored(directory, names):
    relative = Path(directory).relative_to(source)
    patterns = all_patterns + (root_patterns if relative == Path(".") else ())
    return [name for name in names if any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)
            or relative / name == Path("models/local")]

# Keep the independently verified /src/build/_deps seed. Only the checkout is
# copied here; application build outputs are generated afterward at this path.
shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True, ignore=ignored)
PYTHON
