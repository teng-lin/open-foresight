"""Assert production helper binaries contain no failure-injection hooks."""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--expected-enabled", choices=("0", "1"), default="0")
    args = parser.parse_args()
    binary = args.binary.read_bytes()
    for hook in (
        b"FORESIGHT_CRASH_AT",
        b"FORESIGHT_TEST_DELAY_MS",
        b".crash-at",
        b".pause-at",
    ):
        if (hook in binary) != (args.expected_enabled == "1"):
            raise SystemExit(
                f"Helper test hook {hook!r} does not match expected-enabled={args.expected_enabled}"
            )


if __name__ == "__main__":
    main()
