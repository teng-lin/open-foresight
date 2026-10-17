#!/usr/bin/env python3
"""Exercise native inference with an empty executable PATH and optional Python parity oracle.

Python here drives tests only; the native child has no Python executable in PATH.
"""

from typing import Any
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run_worker(command, requests, environment):
    result = subprocess.run(
        command,
        input="".join(json.dumps(r) + "\n" for r in requests),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=900,
    )
    if result.returncode:
        raise RuntimeError(result.stderr[-6000:] + result.stdout[-2000:])
    messages = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(messages) == len(requests) + 1, messages
    assert all("error" not in message for message in messages), messages
    return messages


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--worker", type=Path, required=True)
    p.add_argument("--library", type=Path, required=True)
    p.add_argument("--embedding", type=Path, required=True)
    p.add_argument("--onnx-library", type=Path)
    p.add_argument("--generation", type=Path)
    p.add_argument("--backend", choices=["cpu", "gpu"], default="cpu")
    p.add_argument("--reference-python", type=Path)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    environment = dict(
        os.environ,
        FORESIGHT_LITERT_LIBRARY=str(args.library.resolve()),
        PATH="/nonexistent",
    )
    if args.onnx_library:
        environment["FORESIGHT_ONNX_LIBRARY"] = str(args.onnx_library.resolve())
    worker = str(args.worker.resolve())
    directory = args.embedding.is_dir()
    subprocess.run([worker, "--check"], env=environment, check=True, timeout=300)
    texts = [
        "Mira sends the draft Tuesday.",
        "Café 東京 — résumé.",
        "",
        "A meeting about launch schedules. " * 400,
    ]
    requests: list[dict[str, Any]] = [{"op": "encode", "text": text} for text in texts]
    requests += [{"op": "decode", "tokens": [2, 10, 2364]}]
    requests += [
        {"op": "embed", "text": text, "task": task}
        for text in texts
        for task in ["document", "query", "raw"]
    ]
    options = ["--gpu"] if args.backend == "gpu" else []
    native = run_worker(
        [worker, "--embedding", str(args.embedding.resolve()), *options],
        requests,
        environment,
    )
    for message in native[6:]:
        vector = message["result"]
        assert len(vector) == native[0]["dimensions"] and all(
            math.isfinite(x) for x in vector
        )
        assert abs(math.sqrt(sum(x * x for x in vector)) - 1) < 0.0001
    report = {
        "backend": args.backend,
        "native_identity": native[0],
        "requests": len(requests),
        "empty_path": True,
    }
    if args.reference_python:
        reference = run_worker(
            [
                str(args.reference_python.absolute()),
                "-I",
                str(
                    ROOT
                    / (
                        "tests/reference/inference/model_adapter.py"
                        if directory
                        else "tests/reference/inference/litert_embedding_adapter.py"
                    )
                ),
                str(args.embedding.resolve()),
                *options,
            ],
            requests,
            dict(os.environ),
        )
        assert all(native[0][key] == value for key, value in reference[0].items()), (
            native[0],
            reference[0],
        )
        assert native[1:6] == reference[1:6], "Tokenizer mismatch"
        differences = [
            max(abs(a - b) for a, b in zip(n["result"], r["result"], strict=False))
            for n, r in zip(native[6:], reference[6:], strict=False)
        ]
        assert max(differences) < 0.0001, differences
        report["max_embedding_difference"] = max(differences)
        report["python_oracle"] = "test-only, not packaged"
    if args.generation:
        command = [
            worker,
            "--model",
            str(args.generation.resolve()),
            "--backend",
            args.backend,
        ]
        result = subprocess.run(
            [
                *command,
                "--prompt",
                "Reply with one short sentence: what is 2 + 2?",
                "--max-output-tokens",
                "128",
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=900,
        )
        assert result.returncode == 0 and re.search(
            r"\b(?:4|four)\b", result.stdout, re.IGNORECASE
        ), result.stderr[-2000:]
        report["generation"] = result.stdout
        short = subprocess.run(
            [*command, "--prompt", "Reply exactly YES.", "--max-output-tokens", "16"],
            env=environment,
            capture_output=True,
            text=True,
            timeout=900,
        )
        assert short.returncode == 0 and short.stdout.strip(), short.stderr[-2000:]
        report["short_output_budget"] = short.stdout
        schema = {
            "type": "object",
            "properties": {"answer": {"type": "string"}},
            "required": ["answer"],
            "additionalProperties": False,
        }
        result = subprocess.run(
            [
                *command,
                "--prompt",
                "Return JSON with answer set to hello.",
                "--json-schema",
                json.dumps(schema),
                "--max-output-tokens",
                "128",
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=900,
        )
        assert result.returncode == 0 and isinstance(
            json.loads(result.stdout)["answer"], str
        ), result.stderr[-2000:]
        report["structured_generation"] = json.loads(result.stdout)
        request = {
            "version": 1,
            "question": "Who sends the draft and when?",
            "sources": [
                {
                    "citation": "S1",
                    "title": "Planning meeting",
                    "excerpt": "Mira sends the draft Tuesday.",
                }
            ],
        }
        result = subprocess.run(
            [
                *command,
                "--prompt",
                "Answer from evidence",
                "--json-schema",
                json.dumps({"x-foresight-grounded-request": request}),
                "--max-output-tokens",
                "512",
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=900,
        )
        assert result.returncode == 0, result.stderr[-3000:]
        answer = json.loads(result.stdout)
        assert (
            answer["citations"] == ["S1"]
            and "Mira" in answer["answer"]
            and "Tuesday" in answer["answer"]
        ), answer
        report["grounded_generation"] = answer
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
