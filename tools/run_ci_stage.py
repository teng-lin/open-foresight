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
stage_environment = importlib.import_module(
    "tools.ci_stage_environment" if __package__ else "ci_stage_environment"
)

timing = importlib.import_module("tools.ci_timing" if __package__ else "ci_timing")

ROOT = Path(__file__).resolve().parents[1]


@timing.phase("same-run prerequisite verification and restore")
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
    payload_kind = "native-runtime" if stage == "native" else stage
    if receipt.get("payload_kind", stage) != payload_kind:
        raise ValueError("Prerequisite has an unexpected payload kind")
    payloads.unpack(root, platform, payload_kind, archive, receipt["content"])


@timing.phase("stage execution")
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
        expected = f"open-foresight-{versions.read_version(root)[0]}-{revision}"
        actual = subprocess.check_output(
            [str(root / "build/services/helper/ForesightHelper"), "--build-id"],
            text=True,
            timeout=10,
        ).strip()
        if actual != expected:
            raise ValueError(
                f"Native helper identity mismatch: expected {expected}, got {actual}"
            )


@timing.phase("complete stage")
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
    stage_environment.reject_compiler_overrides()
    source = cache.git(root, "rev-parse", "HEAD").decode().strip()
    for parent, directory in inputs.items():
        if parent not in parents:
            raise ValueError(f"Unexpected prerequisite: {parent}")
        restore_input(root, platform, parent, directory, parents[parent], source)
    required = (
        {"native"}
        if stage in ("core", "desktop")
        else {"native", "core"}
        if stage == "service"
        else set()
    )
    expected_parents = {"native", "core", "desktop"} if stage == "service" else required
    if set(parents) != expected_parents:
        raise ValueError(
            f"Stage {stage} requires parent identities {sorted(expected_parents)}"
        )
    # Service integration compiles its Debug UI harness from current source. Its
    # successful desktop prerequisite is bound by identity, not a Release bundle.
    if set(inputs) != required:
        raise ValueError(f"Stage {stage} requires input artifacts {sorted(required)}")
    environment = {
        **environment,
        "cmake_arguments": cmake_args,
        "validation_flags": {
            key: hashlib.sha256(os.environ[key].encode()).hexdigest()
            if key in os.environ
            else None
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
    # An inactive diagnostic option must not change historical environment
    # identities or discard compatible native compiler work. Only the core
    # benchmark has additional validation semantics to bind.
    if stage == "core" and os.environ.get("FORESIGHT_CORE_COVERAGE_BENCHMARK") == "1":
        environment["validation_flags"]["FORESIGHT_CORE_COVERAGE_BENCHMARK"] = (
            hashlib.sha256(b"1").hexdigest()
        )
    identity = cache.fingerprint(
        platform, stage, root, environment=environment, parents=parents
    )
    with tempfile.TemporaryDirectory(prefix="ci-stage-") as temporary:
        compilation = {"hit": False}
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
            os.environ.get("GITHUB_HEAD_REF") or os.environ.get("GITHUB_REF_NAME", ""),
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
            if stage == "native":
                compilation = cache.find_native_work(
                    repository,
                    platform,
                    environment,
                    root,
                    own_pr,
                    event,
                    os.environ.get("GITHUB_HEAD_REF")
                    or os.environ.get("GITHUB_REF_NAME", ""),
                    release,
                    Path(temporary) / "compilation",
                )
                if compilation["hit"]:
                    payloads.unpack(
                        root,
                        platform,
                        "native",
                        Path(compilation["download_dir"]) / "payload.tar.gz",
                        compilation["receipt"]["content"],
                        force_changed=True,
                    )
                    if compilation.get("configuration_changed"):
                        # Recompute changed CMake defaults instead of inheriting
                        # old cached values. Keep all objects, fetched dependency
                        # trees and SDKs for the actual incremental build.
                        (root / "build/CMakeCache.txt").unlink(missing_ok=True)
                        print(
                            "Refresh CMake configuration values because these "
                            "recipe inputs changed: "
                            + ", ".join(compilation["configuration_changed"]),
                            flush=True,
                        )
                    print(
                        "Reuse compatible native compilation work from run "
                        f"{compilation['run_id']}; current configure/build/tests "
                        "are still required",
                        flush=True,
                    )
                else:
                    print(
                        "Native compilation required: no retained verified "
                        "successful producer matches the current compiler, SDK, "
                        "system packages and build settings",
                        flush=True,
                    )
                    if compilation.get("incompatible_environment_fields"):
                        print(
                            "Retained compilation artifacts differ in environment "
                            "fields: "
                            + ", ".join(compilation["incompatible_environment_fields"]),
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
            "compilation_cache_hit": compilation["hit"],
            "output": str(output),
        }
        if stage == "native":
            runtime_output = root / "build/ci-stage" / f"{platform}-native-runtime"
            runtime_manifest = payloads.pack(
                root, platform, "native-runtime", runtime_output
            )
            (runtime_output / "content.json").unlink()
            runtime = cache.publish(
                platform,
                stage,
                root,
                environment,
                parents,
                runtime_output / "payload.tar.gz",
                runtime_output,
                runtime_manifest,
                reusable_result=False,
                payload_kind="native-runtime",
            )
            if runtime["identity"] != published["identity"]:
                raise ValueError(
                    "Runtime prerequisite differs from validated native inputs"
                )
            result["runtime_artifact_name"] = runtime["artifact_name"]
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
