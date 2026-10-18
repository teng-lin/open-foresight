#!/usr/bin/env python3
"""Run or reuse one independently verified platform stage, then publish outputs."""

import argparse
import importlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

payloads = importlib.import_module(
    "tools.ci_stage_artifacts" if __package__ else "ci_stage_artifacts"
)
cache = importlib.import_module(
    "tools.ci_stage_cache" if __package__ else "ci_stage_cache"
)

ROOT = Path(__file__).resolve().parents[1]


def restore_input(root, platform, stage, directory, identity, source):
    receipt = json.loads((directory / "identity.json").read_text())
    if (
        receipt.get("platform") != platform
        or receipt.get("stage") != stage
        or receipt.get("identity") != identity
        or receipt.get("source_commit") != source
    ):
        raise ValueError(f"Mismatched same-run {stage} prerequisite")
    archive = directory / "payload.tar.gz"
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != receipt.get("sha256"):
        raise ValueError(f"Corrupt same-run {stage} prerequisite")
    payloads.unpack(root, platform, stage, archive, receipt["content"])


def execute(root, platform, stage, hit, cmake_args):
    if stage == "native" and hit:
        # The cached source and toolchain are identical. CMake still refreshes
        # the tiny commit-identity unit, retaining expensive native objects.
        command = [
            "cmake",
            "-S",
            str(root),
            "-B",
            str(root / "build"),
            "-DCMAKE_BUILD_TYPE=Release",
            "-DPython3_EXECUTABLE="
            + os.environ.get("FORESIGHT_PYTHON", str(root / ".venv/bin/python")),
            *cmake_args,
        ]
        subprocess.run(command, cwd=root, check=True, timeout=300)
        subprocess.run(
            [
                "cmake",
                "--build",
                str(root / "build"),
                "--parallel",
                os.environ.get("FORESIGHT_BUILD_JOBS", "3"),
            ],
            cwd=root,
            check=True,
            timeout=1800,
        )
    elif not hit:
        subprocess.run(
            [
                "bash",
                str(root / "tools/build.sh"),
                "--platform",
                platform,
                "--stage",
                stage,
                *cmake_args,
            ],
            cwd=root,
            check=True,
            timeout=3600,
        )

    if stage == "native":
        versions = importlib.import_module(
            "tools.app_version" if __package__ else "app_version"
        )
        revision = cache.git(root, "rev-parse", "HEAD").decode().strip()[:12]
        expected = f"open-foresight-{versions.read_version()[0]}-{revision}"
        actual = subprocess.check_output(
            [str(root / "build/services/helper/ForesightHelper"), "--build-id"],
            text=True,
            timeout=10,
        ).strip()
        if actual != expected:
            raise ValueError(
                f"Native helper identity mismatch: expected {expected}, got {actual}"
            )


def run(
    root,
    platform,
    stage,
    environment,
    parents,
    inputs,
    repository,
    own_pr,
    event,
    release,
    cmake_args,
):
    source = cache.git(root, "rev-parse", "HEAD").decode().strip()
    for parent, directory in inputs.items():
        if parent not in parents:
            raise ValueError(f"Unexpected prerequisite: {parent}")
        restore_input(root, platform, parent, directory, parents[parent], source)
    required = (
        {"native"}
        if stage in ("core", "desktop")
        else {"native", "core", "desktop"}
        if stage == "service"
        else set()
    )
    if set(inputs) != required:
        raise ValueError(f"Stage {stage} requires input artifacts {sorted(required)}")
    environment = {
        **environment,
        "cmake_arguments": cmake_args,
        "validation_flags": {
            key: os.environ.get(key)
            for key in (
                "FORESIGHT_COVERAGE",
                "FORESIGHT_CORE_COVERAGE_MIN",
                "FORESIGHT_DESKTOP_COVERAGE_MIN",
                "FORESIGHT_ENABLE_TEST_HOOKS",
                "FORESIGHT_LINUX_UI_TEST",
                "FORESIGHT_MACOS_UI_TEST",
                "FORESIGHT_REQUIRE_NATIVE_UI_TEST",
                "CFLAGS",
                "CXXFLAGS",
                "LDFLAGS",
            )
        },
    }
    identity = cache.fingerprint(
        platform, stage, root, environment=environment, parents=parents
    )
    with tempfile.TemporaryDirectory(prefix="ci-stage-") as temporary:
        found = cache.find(
            repository,
            platform,
            stage,
            identity,
            environment,
            parents,
            root,
            own_pr,
            event,
            os.environ.get("GITHUB_HEAD_REF", ""),
            release,
            Path(temporary) / "restored",
        )
        if found["hit"]:
            payloads.unpack(
                root,
                platform,
                stage,
                Path(found["download_dir"]) / "payload.tar.gz",
                found["receipt"]["content"],
            )
            print(
                f"Reuse verified {stage}-{platform} from run {found['run_id']} ({identity})",
                flush=True,
            )
        else:
            print(
                f"Run {stage}-{platform}: no reusable successful result for {identity}",
                flush=True,
            )
        execute(root, platform, stage, found["hit"], cmake_args)
        output = root / "build/ci-stage" / f"{platform}-{stage}"
        manifest = payloads.pack(root, platform, stage, output)
        (output / "content.json").unlink()  # The bound receipt carries this manifest.
        published = cache.publish(
            platform,
            stage,
            root,
            environment,
            parents,
            output / "payload.tar.gz",
            output,
            manifest,
            reusable_result=(
                cache.source_inputs(root, stage)
                == cache.source_inputs(root, stage, source)
            ),
        )
        result = {
            "identity": published["identity"],
            "artifact_name": published["artifact_name"],
            "cache_hit": found["hit"],
            "output": str(output),
        }
        if destination := os.environ.get("GITHUB_OUTPUT"):
            with open(destination, "a") as stream:
                for key, value in result.items():
                    stream.write(
                        f"{key}={str(value).lower() if isinstance(value, bool) else value}\n"
                    )
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument(
        "--stage", choices=("native", "core", "desktop", "service"), required=True
    )
    parser.add_argument("--event", required=True)
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--parents-json", type=json.loads, default={})
    parser.add_argument("--input", action="append", default=[])
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--cmake-arg", action="append", default=[])
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    args = parser.parse_args()
    environment = json.loads(
        Path(os.environ["FORESIGHT_STAGE_ENVIRONMENT"]).read_text()
    )
    inputs = {}
    for item in args.input:
        name, path = item.split("=", 1)
        if name in inputs:
            parser.error("Duplicate stage prerequisite")
        inputs[name] = Path(path)
    result = run(
        ROOT,
        args.platform,
        args.stage,
        environment,
        args.parents_json,
        inputs,
        args.repository,
        args.own_pr,
        args.event,
        args.release,
        args.cmake_arg,
    )
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
