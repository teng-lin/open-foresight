#!/usr/bin/env python3
"""Exercise shipped GPU runtimes on Mesa's explicitly selected software Vulkan ICD."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import wave

from integration_gates import model_file
from test_packaged_model_runtime import Peer, finish_peer, packaged_paths

ROOT = Path(__file__).resolve().parents[1]
# These describe absent GPU API capabilities, never model/decoder failures.
UNSUPPORTED = re.compile(
    r"no (?:available )?OpenCL (?:platform|device)|OpenCL (?:library|driver).*not (?:found|available)|"
    r"failed to (?:load|initialize) OpenCL|GPU (?:delegate|backend|support) (?:is )?not (?:supported|available)|"
    r"no (?:suitable|compatible) GPU device",
    re.I,
)


def whisper_result(result, allow_unavailable=False):
    if (
        allow_unavailable
        and result.returncode == 0
        and "using Vulkan0 backend" not in result.stderr
        and "ggml_vulkan: No devices found." in result.stderr
        and "whisper_backend_init_gpu: no GPU found" in result.stderr
    ):
        return {
            "status": "skipped",
            "reason": "The selected software Vulkan driver exposes no supported GPU device.",
            "diagnostic": result.stderr,
        }
    if result.returncode or "using Vulkan0 backend" not in result.stderr:
        raise RuntimeError(
            "Whisper failed to execute on software Vulkan: " + result.stderr
        )
    if not re.search(r"llvmpipe|lavapipe", result.stderr, re.I):
        raise RuntimeError(
            "Whisper did not identify the selected software Vulkan device"
        )
    if not re.search(r"\b(?:and|so|my|fellow|americans)\b", result.stdout, re.I):
        raise RuntimeError(
            "Whisper returned no known speech from the two-second fixture"
        )
    return {
        "status": "passed",
        "backend": "Vulkan0",
        "transcript": result.stdout.strip(),
    }


def litert_probe(runner, model, env, output):
    command = [str(runner), "--model", model, "--backend", "gpu"]
    probe = subprocess.run(
        [*command, "--probe"],
        env=env,
        cwd="/",
        text=True,
        capture_output=True,
        timeout=180,
    )
    (output / "litert-probe.log").write_text(probe.stdout + probe.stderr)
    if probe.returncode:
        if UNSUPPORTED.search(probe.stderr):
            return {"status": "unsupported_software_driver", "diagnostic": probe.stderr}
        raise RuntimeError("Unexpected LiteRT GPU capability failure: " + probe.stderr)
    peer = Peer([*command, "--serve"], env, "/", output / "litert-decode.log", 180)
    primary = None
    try:
        if peer.receive() != "ready 1":
            raise RuntimeError("LiteRT GPU model failed to become ready")
        peer.send(
            "generate 1 "
            + json.dumps(
                {
                    "prompt": "Count from one to five.",
                    "max_output_tokens": 16,
                    "tools": {
                        "tools": [],
                        "system_message": "Answer briefly.",
                        "stop_token_ids": [[1, 1]],
                    },
                }
            )
        )
        answer = None
        while True:
            frame = peer.receive().split(" ", 2)
            if len(frame) != 3 or frame[0] != "1":
                raise RuntimeError("Malformed GPU decode frame: " + repr(frame))
            if frame[1] == "error":
                raise RuntimeError("LiteRT GPU decode failed: " + frame[2])
            if frame[1] == "answer":
                answer = json.loads(frame[2])
            if frame[1] == "done":
                if frame[2] != "completed" or not answer or answer.get("error"):
                    raise RuntimeError(
                        "LiteRT GPU decode did not complete successfully"
                    )
                break
        text = answer.get("content", "")
        if isinstance(text, list):
            text = "".join(
                part.get("text", "") for part in text if isinstance(part, dict)
            )
        if not isinstance(text, str) or not text.strip():
            raise RuntimeError("LiteRT GPU returned no decoded text")
        return {
            "status": "passed",
            "backend": "gpu",
            "max_output_tokens": 16,
            "answer": answer,
        }
    except Exception as error:
        primary = error
        raise
    finally:
        finish_peer(peer, output, "software-gpu", primary, "shutdown")


def software_environment(icd, temporary, packaged):
    return {
        **packaged,
        "PATH": "/usr/bin:/bin",
        "HOME": str(temporary),
        "FORESIGHT_LITERT_CACHE": str(Path(temporary) / "litert-cache"),
        "VK_ICD_FILENAMES": str(icd),
        "VK_DRIVER_FILES": str(icd),
        # ggml excludes CPU-type Vulkan devices by default. This explicit
        # software-only runner opts in to lavapipe without changing the app.
        "GGML_VK_VISIBLE_DEVICES": "0",
    }


def write_report(output, report):
    (output / "software-gpu.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--allow-unavailable",
        action="store_true",
        help="CI only: record absent GPU/driver support as skipped; runtime failures remain fatal.",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    icds = sorted(Path("/usr/share/vulkan/icd.d").glob("lvp_icd*.json"))
    if not icds and args.allow_unavailable:
        write_report(
            args.output,
            {
                "status": "skipped",
                "reason": "No Mesa lavapipe Vulkan ICD is installed on this CI instance.",
                "physical_gpu_verified": False,
            },
        )
        return
    if len(icds) != 1:
        raise RuntimeError("Exactly one installed Mesa lavapipe ICD is required")
    runner, _, environment = packaged_paths(args.bundle)
    with tempfile.TemporaryDirectory(prefix="software-gpu-") as temporary:
        env = software_environment(icds[0], temporary, environment)
        audio = Path(temporary) / "two-seconds.wav"
        with (
            wave.open(str(ROOT / "tests/fixtures/audio/jfk.wav")) as source,
            wave.open(str(audio), "wb") as target,
        ):
            target.setparams(source.getparams())
            target.writeframes(source.readframes(source.getframerate() * 2))
        result = subprocess.run(
            [
                str(args.bundle.resolve() / "bin/whisper-cli-vulkan"),
                "-m",
                model_file(args.models, "speech"),
                "-f",
                str(audio),
                "-l",
                "en",
                "-nt",
                "-t",
                "2",
                "-dev",
                "0",
            ],
            env=env,
            cwd="/",
            text=True,
            capture_output=True,
            timeout=300,
        )
        (args.output / "whisper-vulkan.log").write_text(result.stdout + result.stderr)
        report = {
            "driver": "Mesa lavapipe",
            "physical_gpu_verified": False,
            "whisper": whisper_result(result, args.allow_unavailable),
        }
        report["litert"] = litert_probe(
            runner, model_file(args.models, "generation"), env, args.output
        )
        if (
            args.allow_unavailable
            and report["litert"]["status"] == "unsupported_software_driver"
        ):
            report["litert"]["status"] = "skipped"
            report["litert"]["reason"] = (
                "The software driver provides no supported LiteRT GPU API."
            )
        write_report(args.output, report)


if __name__ == "__main__":
    main()
