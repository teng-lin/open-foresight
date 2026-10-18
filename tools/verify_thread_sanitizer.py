#!/usr/bin/env python3
"""Prove the TSan gate observes a real race; retain unsupported-runtime evidence."""

import argparse
import json
import os
from pathlib import Path
import subprocess

from sanitizer_runtime import address_runtime

SOURCE = """#include <thread>
int shared_value = 0;
int main() {
  std::thread a([] { for (int i = 0; i < 100000; ++i) ++shared_value; });
  std::thread b([] { for (int i = 0; i < 100000; ++i) ++shared_value; });
  a.join(); b.join(); return shared_value == 0;
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = args.output / "race.cpp"
    executable = args.output / "race"
    source.write_text(SOURCE)
    subprocess.run(
        [
            "clang++",
            "-O1",
            "-g",
            "-fsanitize=thread",
            "-shared-libsan",
            "-pthread",
            str(source),
            "-o",
            str(executable),
        ],
        check=True,
        timeout=120,
    )
    environment = {
        **os.environ,
        "LD_LIBRARY_PATH": str(address_runtime(kind="thread").parent),
        "TSAN_OPTIONS": "halt_on_error=1:exitcode=66",
    }
    result = subprocess.run(
        [str(executable.resolve())],
        capture_output=True,
        text=True,
        env=environment,
        timeout=30,
    )
    (args.output / "race.log").write_text(result.stdout + result.stderr)
    detected = result.returncode != 0 and "ThreadSanitizer: data race" in result.stderr
    (args.output / "result.json").write_text(
        json.dumps(
            {
                "race_detected": detected,
                "exit_code": result.returncode,
                "status": "passed"
                if detected
                else "runtime_unavailable_or_probe_failed",
            },
            indent=2,
        )
        + "\n"
    )
    if not detected:
        raise SystemExit(
            "TSan did not report the planted race; inspect retained runtime diagnostics"
        )


if __name__ == "__main__":
    main()
