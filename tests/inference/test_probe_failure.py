#!/usr/bin/env python3
"""A failed native model probe must retain actionable protocol diagnostics."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(worker):
    with tempfile.TemporaryDirectory(prefix="foresight-probe-error-") as temporary:
        missing = str(Path(temporary) / "missing-litert.so")
        alternate_missing = str(Path(temporary) / "missing café library.so")
        for library in (missing, alternate_missing):
            result = subprocess.run(
                [worker, "--model", str(Path(temporary) / "unused"), "--probe"],
                env={**os.environ, "FORESIGHT_LITERT_LIBRARY": library},
                capture_output=True,
                text=True,
                timeout=15,
            )
            assert result.returncode == 1, result
            # The entire protocol output must be one failure object, never a
            # partial capability result or a loader diagnostic on stdout.
            error = json.loads(result.stdout)
            assert set(error) == {"error"}, error
            assert library in error["error"], error
            assert "Cannot load native LiteRT-LM" in error["error"], error
            assert "native_stop_token_sequences" not in error, error
        directory = Path(temporary) / "embedding.litertlm"
        directory.mkdir()
        for asset in (directory, Path(temporary) / "unsupported.bin"):
            result = subprocess.run(
                [worker, "--embedding", str(asset)],
                env={**os.environ, "FORESIGHT_LITERT_LIBRARY": missing},
                capture_output=True,
                text=True,
                timeout=15,
            )
            assert result.returncode == 1, result
            assert "Unsupported model format" in json.loads(result.stdout)["error"], (
                result
            )
    print("Failed native probe publishes its loader error on the protocol stream")


if __name__ == "__main__":
    run(sys.argv[1])
