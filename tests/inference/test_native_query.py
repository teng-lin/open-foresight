"""Native detector rejection and opt-in authenticated-model parity.

Pass the compiled worker as argv[1] for CTest. An explicit local model and a
Python interpreter with NumPy/SentencePiece enable output-token parity checks;
model acquisition and decryption are outside this test.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def verify(worker):
    environment = dict(os.environ, PATH="/nonexistent")
    subprocess.run([worker, "--check"], env=environment, check=True)
    with tempfile.TemporaryDirectory() as directory:
        invalid = Path(directory) / "bad-model"
        invalid.write_bytes(b"untrusted model")
        for path in (invalid, invalid.with_name("missing-model")):
            result = subprocess.run(
                [worker, "--model", str(path)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode != 1 or json.loads(result.stdout)["type"] != "fatal":
                raise AssertionError((result.returncode, result.stdout, result.stderr))
    model = os.environ.get("FORESIGHT_QUERY_MODEL")
    python = os.environ.get("FORESIGHT_QUERY_REFERENCE_PYTHON")
    if not model or not python:
        print(
            "Native query self-check and unauthenticated/missing model rejection passed"
        )
        return
    requests = [
        {
            "id": "positive",
            "prompt": " <ctrl1>We need to ship the launch soon. What risks could delay the launch?",
            "max_output_tokens": 512,
        },
        {
            "id": "negative",
            "prompt": " <ctrl1>The meeting starts at three.",
            "max_output_tokens": 512,
        },
        {
            "id": "bounded",
            "prompt": " <ctrl1>When is the project review?",
            "max_output_tokens": 4,
        },
    ]
    result = subprocess.run(
        [worker, "--model", model],
        env=environment,
        input="".join(json.dumps(r) + "\n" for r in requests),
        capture_output=True,
        text=True,
        check=True,
        timeout=900,
    )
    frames = [json.loads(row) for row in result.stdout.splitlines()]
    if len(frames) != len(requests) + 1 or frames[0]["type"] != "ready":
        raise AssertionError(frames)
    oracle = Path(__file__).resolve().parents[2] / "tools/legacy_query_executor.py"
    for request, frame in zip(requests, frames[1:]):
        reference = subprocess.run(
            [
                python,
                str(oracle),
                model,
                "--transcript",
                request["prompt"][len(" <ctrl1>") :],
                "--max-output-tokens",
                str(request["max_output_tokens"]),
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=900,
        )
        expected = json.loads(reference.stdout)
        if frame["id"] != request["id"] or frame["type"] != "result":
            raise AssertionError(frame)
        for key in ("text", "input_token_ids", "output_token_ids", "finish_reason"):
            if frame[key] != expected[key]:
                raise AssertionError((key, frame[key], expected[key]))
    print("Native dedicated detector matches reference output tokens for all fixtures")


if __name__ == "__main__":
    verify(sys.argv[1])
