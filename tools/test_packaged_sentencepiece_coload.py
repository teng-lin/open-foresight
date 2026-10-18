#!/usr/bin/env python3
"""Check both native/SentencePiece initialization orders in isolated children."""

from typing import Any
import argparse
import json
from pathlib import Path
import subprocess

from litert_extensions import PYTHON_CAPABILITY_PROBE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--python",
        required=True,
        type=Path,
        help="The copied/package-owned standalone Python interpreter",
    )
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    results: dict[str, Any] = {}
    failures = []
    try:
        for name, extra in [
            ("sentencepiece_first", []),
            ("native_first", ["--native-first"]),
        ]:
            try:
                value = subprocess.run(
                    [
                        str(args.python.resolve(strict=True)),
                        "-I",
                        "-B",
                        "-c",
                        PYTHON_CAPABILITY_PROBE,
                        *extra,
                    ],
                    env={"PATH": "/usr/bin:/bin"},
                    cwd="/",
                    text=True,
                    capture_output=True,
                    timeout=20,
                )
                results[name] = {
                    "exit_code": value.returncode,
                    "stdout": value.stdout,
                    "stderr": value.stderr,
                }
                if value.returncode:
                    raise RuntimeError(
                        f"{name} native co-load failed: exit {value.returncode}"
                    )
                results[name]["capabilities"] = json.loads(value.stdout)
            except subprocess.TimeoutExpired as error:
                results[name] = {
                    "status": "timed_out_and_terminated",
                    "error": str(error),
                }
                failures.append(f"{name}: {error}")
            except Exception as error:
                results.setdefault(name, {})["error"] = str(error)
                failures.append(f"{name}: {error}")
        if failures:
            raise RuntimeError("; ".join(failures))
        results["status"] = "passed"
    except Exception as error:
        results.update(status="failed", error=str(error))
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
