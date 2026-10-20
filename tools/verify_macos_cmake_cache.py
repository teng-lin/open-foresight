#!/usr/bin/env python3
"""Reject application configurations that bypass the verified macOS SDK roots."""

import argparse
from pathlib import Path


def verify(cache: Path, *, sdk: Path, icu: Path) -> None:
    """Check resolved CMake package paths, including physical symlink targets."""
    entries = {}
    for line in cache.read_text().splitlines():
        if line.startswith(("#", "//")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if ":" in key:
            entries[key.split(":", 1)[0]] = value

    def require(key: str, expected: str) -> None:
        if entries.get(key) != expected:
            raise ValueError(f"{key} must be {expected!r}, got {entries.get(key)!r}")

    def beneath(key: str, prefix: Path) -> None:
        value = entries.get(key, "")
        path = Path(value)
        if (
            not value
            or value.endswith("-NOTFOUND")
            or not path.is_absolute()
            or not path.exists()
            or not path.resolve().is_relative_to(prefix.resolve())
        ):
            raise ValueError(f"{key} must resolve inside {prefix}: {value!r}")

    require("CMAKE_GENERATOR", "Ninja")
    require("CMAKE_OSX_ARCHITECTURES", "arm64")
    require("CMAKE_OSX_DEPLOYMENT_TARGET", "15.0")
    require("CMAKE_BUILD_TYPE", "Release")
    require("CMAKE_IGNORE_PREFIX_PATH", "/opt/homebrew;/usr/local")
    # A prefix hint alone does not prove which package find_package selected.
    beneath("Protobuf_DIR", sdk)
    beneath("gRPC_DIR", sdk)
    beneath("ICU_INCLUDE_DIR", icu)
    for component in ("UC", "I18N"):
        candidates = [
            key
            for key in entries
            if key in (f"ICU_{component}_LIBRARY", f"ICU_{component}_LIBRARY_RELEASE")
            and not entries[key].endswith("-NOTFOUND")
        ]
        if not candidates:
            raise ValueError(f"Missing resolved ICU {component} library")
        for key in candidates:
            beneath(key, icu)
    for key, value in entries.items():
        if (
            key.startswith("ICU_")
            and key.endswith(("_LIBRARY", "_LIBRARY_DEBUG", "_LIBRARY_RELEASE"))
            and value
            and not value.endswith("-NOTFOUND")
        ):
            beneath(key, icu)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--icu", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args.cache, sdk=args.sdk, icu=args.icu)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Unqualified macOS CMake configuration: {error}\n")


if __name__ == "__main__":
    main()
