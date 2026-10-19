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


def whisper_result(result):
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


def litert_ci_preflight(whisper, diagnostic, allow_unavailable=False):
    """Recognize a proven CPU adapter before optional CI LiteRT model startup.

    In pinned whisper.cpp 0c7be696, ggml-vulkan.cpp emits the exact warning
    below only for VkPhysicalDeviceProperties.deviceType == eCpu. Require one
    unambiguous selected software device and a successful Vulkan transcript;
    model failures, unknown adapters and mixed/duplicate evidence never skip.
    """
    if not allow_unavailable or whisper.get("status") != "passed":
        return None
    counts = re.findall(
        r"^ggml_vulkan: Found (\d+) Vulkan devices:\r?$", diagnostic, re.M
    )
    devices = re.findall(r"^ggml_vulkan: (\d+) = ([^\r\n]+)\r?$", diagnostic, re.M)
    warning = "ggml_vulkan: Warning: Device type is CPU. This is probably not the device you want."
    if (
        counts != ["1"]
        or len(devices) != 1
        or devices[0][0] != "0"
        or not re.match(r"(?:llvmpipe|lavapipe)\b", devices[0][1], re.I)
        or diagnostic.splitlines().count(warning) != 1
    ):
        return None
    return {
        "status": "skipped",
        "reason": "CI selected only a CPU-type software Vulkan adapter; physical GPU coverage is unavailable. LiteRT GPU startup/decode was not attempted.",
        "adapter": {"index": 0, "type": "cpu", "name": devices[0][1].split(" |", 1)[0]},
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
        "--allow-litert-unavailable",
        action="store_true",
        help="CI only: allow qualified LiteRT CPU-adapter/unsupported-driver skips; lavapipe and Whisper Vulkan are required.",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    icds = sorted(Path("/usr/share/vulkan/icd.d").glob("lvp_icd*.json"))
    if len(icds) != 1:
        message = (
            "Exactly one installed Mesa lavapipe ICD is required; "
            f"found {len(icds)} in /usr/share/vulkan/icd.d. "
            "Install mesa-vulkan-drivers in the integration image."
        )
        write_report(args.output, {
            "status": "failed", "error": message, "physical_gpu_verified": False,
        })
        raise RuntimeError(message)
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
            "whisper": whisper_result(result),
        }
        report["litert"] = litert_ci_preflight(
            report["whisper"], result.stderr, args.allow_litert_unavailable
        )
        if report["litert"] is None:
            report["litert"] = litert_probe(
                runner, model_file(args.models, "generation"), env, args.output
            )
        if (
            args.allow_litert_unavailable
            and report["litert"]["status"] == "unsupported_software_driver"
        ):
            report["litert"]["status"] = "skipped"
            report["litert"]["reason"] = (
                "The software driver provides no supported LiteRT GPU API."
            )
        write_report(args.output, report)


if __name__ == "__main__":
    main()
