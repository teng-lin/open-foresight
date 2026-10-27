"""Copy the source tree without Git metadata, as an archived export would arrive."""

from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
_IGNORED = shutil.ignore_patterns(
    ".git", ".venv", ".venv-litert", "build", "dist", "coverage", "test-results",
    ".dart_tool", "__pycache__", ".pytest_cache", "node_modules", "*.pyc",
)


def export_tree(destination: Path) -> Path:
    """Return a complete copy of the working tree that has no `.git`."""
    shutil.copytree(ROOT, destination, ignore=_IGNORED, symlinks=True)
    assert not (destination / ".git").exists()
    return destination
