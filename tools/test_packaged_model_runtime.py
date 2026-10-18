#!/usr/bin/env python3
"""Exercise real models through a relocated package's own inference processes.

Models remain external to the package. Their hashes must match the public setup
catalog; SDK test models cannot satisfy this acceptance. This does not establish
Developer ID, notarization, physical audio, or a production GPU on another host.
"""

from typing import Any, IO, cast

from model_pins import release_models

import argparse
import hashlib
import json
import math
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

GENERATION_SHA256 = release_models()["generation"][3]
EMBEDDING_SHA256 = release_models()["embedding"][3]


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def packaged_paths(bundle):
    bundle = bundle.resolve(strict=True)
    if bundle.suffix == ".app":
        resources = bundle / "Contents/Resources"
        config = json.loads((resources / "runtime.json").read_text())

        def path(key):
            value = (resources / config[key]).resolve(strict=True)
            if not value.is_relative_to(bundle):
                raise RuntimeError(f"Packaged {key} escapes the application")
            return value

        return (
            path("FORESIGHT_LITERT_RUNNER"),
            path("FORESIGHT_MODEL_WORKER"),
            {"FORESIGHT_LITERT_LIBRARY": str(path("FORESIGHT_LITERT_LIBRARY"))},
        )

    def own(relative):
        value = (bundle / relative).resolve(strict=True)
        if not value.is_relative_to(bundle):
            raise RuntimeError(f"Packaged {relative} escapes the bundle")
        return value

    worker = own("bin/foresight-model")
    return (
        worker,
        worker,
        {
            "FORESIGHT_LITERT_LIBRARY": str(own("lib/liblitert-lm.so")),
            "LD_LIBRARY_PATH": str(bundle / "lib"),
        },
    )


class Peer:
    def __init__(self, command, environment, cwd, log, timeout):
        self.timeout = timeout
        self.lines: queue.Queue[Any] = queue.Queue()
        self.log = log.open("wb")
        self.process = subprocess.Popen(
            command,
            env=environment,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            bufsize=1,
        )

        def read():
            try:
                for line in cast(IO[str], self.process.stdout):
                    self.lines.put(line.rstrip("\n"))
            finally:
                self.lines.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def receive(self):
        try:
            value = self.lines.get(timeout=self.timeout)
        except queue.Empty:
            raise TimeoutError(
                f"No protocol frame for {self.timeout} seconds"
            ) from None
        if value is None:
            raise EOFError(f"Worker closed stdout (exit={self.process.poll()})")
        return value

    def send(self, value):
        cast(IO[str], self.process.stdin).write(value + "\n")
        cast(IO[str], self.process.stdin).flush()

    def close(self, shutdown=None):
        try:
            if self.process.poll() is None:
                if shutdown:
                    self.send(shutdown)
                cast(IO[str], self.process.stdin).close()
                try:
                    self.process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    self.process.wait(timeout=15)
                    raise RuntimeError("Worker failed graceful shutdown") from None
            if self.process.returncode:
                raise RuntimeError(f"Worker exited {self.process.returncode}")
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=30)
            if not cast(IO[str], self.process.stdin).closed:
                cast(IO[str], self.process.stdin).close()
            self.reader.join(timeout=2)
            cast(IO[str], self.process.stdout).close()
            self.log.close()
            trailing = []
            while not self.lines.empty():
                value = self.lines.get_nowait()
                if value is not None:
                    trailing.append(value)
            if self.process.returncode == 0 and trailing:
                raise RuntimeError(f"Unexpected trailing worker stdout: {trailing!r}")


def finish_peer(peer, output, name, primary_error, shutdown=None):
    cleanup: dict[str, Any] = {"graceful_shutdown": False}
    try:
        peer.close(shutdown)
        cleanup["graceful_shutdown"] = True
    except Exception as error:
        cleanup["error"] = str(error)
        if primary_error is None:
            raise
        primary_error.add_note("Worker cleanup also failed: " + str(error))
    finally:
        cleanup["exit_code"] = peer.process.returncode
        (output / f"{name}-shutdown.json").write_text(
            json.dumps(cleanup, indent=2) + "\n"
        )


def generation_probe(runner, model, backend, environment, cwd, output, timeout):
    base = [str(runner), "--model", str(model), "--backend", backend]
    with (output / f"{backend}-capabilities.stderr").open("wb") as log:
        result = subprocess.run(
            [*base, "--probe"],
            cwd=cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
            timeout=timeout,
        )
    if result.returncode:
        raise RuntimeError("Packaged production model capability probe failed")
    capabilities = json.loads(result.stdout)
    if capabilities.get("native_stop_token_sequences") is not True:
        raise RuntimeError(
            "Packaged runtime lacks the native stop sequences required by note enhancement"
        )
    peer = Peer(
        [*base, "--serve"],
        environment,
        cwd,
        output / f"{backend}-generation.stderr",
        timeout,
    )
    requests = []
    primary_error = None
    try:
        if peer.receive() != "ready 1":
            raise RuntimeError("Unexpected persistent-worker readiness frame")
        pid = peer.process.pid
        for token in (1, 2):
            payload = {
                "prompt": "Reply with one short sentence: what is 2 + 2?",
                "max_output_tokens": 128,
                "tools": {
                    "tools": [],
                    "system_message": "Answer the question accurately.",
                    "stop_token_ids": [[1, 1]],
                },
            }
            peer.send(f"generate {token} " + json.dumps(payload))
            frames, answer = [], None
            while True:
                line = peer.receive()
                frames.append(line)
                fields = line.split(" ", 2)
                if len(fields) != 3 or fields[0] != str(token):
                    raise RuntimeError(f"Invalid or cross-request frame: {line!r}")
                kind, value = fields[1:]
                if kind == "error":
                    raise RuntimeError(f"Production generation failed: {value}")
                if kind == "answer":
                    answer = json.loads(value)
                if kind == "done":
                    if value != "completed":
                        raise RuntimeError(f"Generation terminal status: {value}")
                    break
            if answer is None or answer.get("error"):
                raise RuntimeError(f"No successful answer: {answer!r}")
            text = answer.get("content", "")
            if isinstance(text, list):
                text = "".join(
                    part.get("text", "") for part in text if isinstance(part, dict)
                )
            if "4" not in text and "four" not in text.lower():
                raise RuntimeError(
                    f"Production model failed the elementary arithmetic check: {text!r}"
                )
            requests.append({"request": token, "answer": answer, "frames": frames})
            if peer.process.poll() is not None or peer.process.pid != pid:
                raise RuntimeError(
                    "Persistent model worker was replaced between requests"
                )
    except Exception as error:
        primary_error = error
        raise
    finally:
        finish_peer(peer, output, f"{backend}-generation", primary_error, "shutdown")
    return {
        "capabilities": capabilities,
        "same_engine_process_two_requests": True,
        "ordered_stop_configuration_accepted": True,
        "ordered_stop_termination": "not_measured_by_this_probe",
        "graceful_shutdown": True,
        "requests": requests,
    }


def embedding_probe(worker, model, backend, environment, cwd, output, timeout):
    command = [str(worker), "--embedding", str(model)]
    if backend == "gpu":
        command.append("--gpu")
    peer = Peer(
        command, environment, cwd, output / f"{backend}-embedding.stderr", timeout
    )
    primary_error = None
    try:
        identity = json.loads(peer.receive())
        if (
            identity.get("digest") != EMBEDDING_SHA256
            or identity.get("dimensions") != 768
        ):
            raise RuntimeError(
                f"Unexpected production embedding identity: {identity!r}"
            )
        if identity.get("backend") != f"litert-lm-embedding-{backend}":
            raise RuntimeError(
                f"Embedding worker selected a different backend: {identity!r}"
            )
        for task in ("document", "query"):
            peer.send(
                json.dumps(
                    {
                        "op": "embed",
                        "task": task,
                        "text": "Mira sends the draft Tuesday.",
                    }
                )
            )
            message = json.loads(peer.receive())
            vector = message.get("result", [])
            if (
                len(vector) != 768
                or not all(math.isfinite(x) for x in vector)
                or abs(math.sqrt(sum(x * x for x in vector)) - 1) > 0.0001
            ):
                raise RuntimeError(f"Invalid production {task} embedding: {message!r}")
    except Exception as error:
        primary_error = error
        raise
    finally:
        finish_peer(peer, output, f"{backend}-embedding", primary_error)
    return {
        "identity": identity,
        "document_and_query_finite_normalized_768": True,
        "graceful_shutdown": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--generation", required=True, type=Path)
    parser.add_argument("--embedding", required=True, type=Path)
    parser.add_argument("--backend", choices=("cpu", "gpu"), required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "failed",
        "backend": args.backend,
        "signed_release_acceptance": "not_run",
        "other_platform_gpu_acceptance": "not_run",
    }
    try:
        report["stage"] = "model_digest_verification"
        models = [
            args.generation.resolve(strict=True),
            args.embedding.resolve(strict=True),
        ]
        actual = [digest(model) for model in models]
        if actual != [GENERATION_SHA256, EMBEDDING_SHA256]:
            raise RuntimeError("Production models differ from the pinned setup catalog")
        report["stage"] = "package_path_resolution"
        runner, worker, config = packaged_paths(args.bundle)
        with tempfile.TemporaryDirectory(
            prefix="of-production-", dir="/tmp"
        ) as temporary:
            root = Path(temporary)
            home, poisoned = root / "home", root / "untrusted working directory"
            home.mkdir()
            poisoned.mkdir()
            for name in ("litert_lm.py", "sentencepiece.py", "numpy.py"):
                (poisoned / name).write_text(
                    'raise RuntimeError("untrusted working directory imported")\n'
                )
            environment = {
                "PATH": "/usr/bin:/bin",
                "HOME": str(home),
                "TMPDIR": str(root),
                "PYTHONPATH": str(poisoned),
                "FORESIGHT_LITERT_CACHE": str(root / "cache"),
                **config,
            }
            report["stage"] = "embedding"
            report["embedding"] = embedding_probe(
                worker,
                models[1],
                args.backend,
                environment,
                poisoned,
                args.output,
                args.timeout,
            )
            report["stage"] = "generation"
            report["generation"] = generation_probe(
                runner,
                models[0],
                args.backend,
                environment,
                poisoned,
                args.output,
                args.timeout,
            )
        report.update(
            status="passed",
            stage="complete",
            generation_sha256=actual[0],
            embedding_sha256=actual[1],
            bundle=str(args.bundle.resolve()),
            isolated_profile=True,
            no_checkout_or_sdk_environment=True,
            poisoned_cwd_rejected=True,
        )
    except Exception as error:
        report["error"] = str(error)
        report["additional_errors"] = getattr(error, "__notes__", [])
        raise
    finally:
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
