"""Assert production helper binaries contain no failure-injection hooks."""

from pathlib import Path
import sys


def main() -> None:
    binary = Path(sys.argv[1]).read_bytes()
    for hook in (
        b"FORESIGHT_CRASH_AT",
        b"FORESIGHT_TEST_DELAY_MS",
        b".crash-at",
        b".pause-at",
    ):
        if hook in binary:
            raise SystemExit(f"Production helper still contains test hook {hook!r}")


if __name__ == "__main__":
    main()
