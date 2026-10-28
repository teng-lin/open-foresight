"""Copy the source tree without Git metadata, as an archived export would arrive."""

from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
_IGNORED = shutil.ignore_patterns(
    ".git", ".venv", ".venv-litert", "build", "dist", "coverage", "test-results",
    ".dart_tool", "__pycache__", ".pytest_cache", "node_modules", "*.pyc",
)


def _source_files(root: Path) -> list[str] | None:
    """Tracked plus unignored untracked files, or None when Git cannot list them.

    Git runs here, in the parent, so exports contain exactly the source and no
    caches or ignored output; a child planning from the export never needs Git.
    """
    if not (root / ".git").exists():
        return None
    try:
        listing = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True, check=True, timeout=120,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return sorted({name for name in listing.decode(errors="surrogateescape").split("\0") if name})


def export_tree(destination: Path) -> Path:
    """Return a copy of the source that has no `.git`.

    A checkout is exported from `git ls-files`; a tree that is itself an export
    (no `.git`) is copied with build and cache directories pruned.
    """
    names = _source_files(ROOT)
    if names is None:
        shutil.copytree(ROOT, destination, ignore=_IGNORED, symlinks=True)
    else:
        for name in names:
            source = ROOT / name
            if not (source.is_symlink() or source.is_file()):
                continue  # deleted in the working tree but still indexed
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target, follow_symlinks=False)
    assert not (destination / ".git").exists()
    return destination
