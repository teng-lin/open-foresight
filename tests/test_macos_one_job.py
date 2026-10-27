"""Independent macOS lanes retain every gate and the package trust boundary."""

import json
import os
import re
from pathlib import Path
import subprocess

import pytest

from tests.test_macos_cmake_cache import configured as configured
from tests.test_pull_request_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]


def _shell_environment(values):
    # Fixture PATH stubs must win over host startup files, including SSH shells.
    return {
        key: value for key, value in values.items() if key not in {"BASH_ENV", "ENV"}
    }


def config():
    return parse_workflow((ROOT / ".github/workflows/macos.yml").read_text())


def setup():
    return parse_workflow(
        (ROOT / ".github/actions/setup-macos-stage/action.yml").read_text()
    )["runs"]["steps"]


def test_parallel_lanes_keep_each_suite_and_package_prerequisites_independent():
    workflow = config()
    jobs = workflow["jobs"]
    checks = jobs["macos-checks"]
    assert checks["runs-on"] == "macos-15"
    assert checks["strategy"] == {
        "fail-fast": False,
        "matrix": {"stage": ["contracts", "native", "core", "desktop", "service"]},
    }
    assert checks["needs"] == ["changes", "distribution-number"]
    assert checks["env"]["FORESIGHT_PARALLEL_GATES"] == "0"
    assert checks["env"]["FORESIGHT_CORE_TEST_CONCURRENCY"] == "2"
    assert jobs["macos"]["env"]["FORESIGHT_PARALLEL_GATES"] == "0"
    steps = checks["steps"]
    contracts = next(step for step in steps if "source and SDK" in step.get("name", ""))
    assert contracts["if"] == "matrix.stage == 'contracts'"
    assert "platform_python_tests.py --platform macos" in contracts["run"]
    stage = next(
        step for step in steps if "isolated macOS stage" in step.get("name", "")
    )
    assert stage["if"] == "matrix.stage != 'contracts'"
    command = stage["run"]
    assert command.index("cmake -S .") < command.index("verify_macos_cmake_cache.py")
    assert command.index("verify_macos_cmake_cache.py") < command.index(
        "tools/build.sh"
    )
    assert "--stage native --build-only" in command
    assert 'if [[ "$MACOS_CHECK_STAGE" != native ]]' in command
    assert 'if [[ "$MACOS_CHECK_STAGE" == service ]]' in command
    assert "--stage core --build-only" in command
    assert '--stage "$MACOS_CHECK_STAGE" "${task_cmake_args[@]}"' in command
    assert "set -o pipefail" in command
    evidence = next(step for step in steps if step.get("if") == "always()")
    assert (
        evidence["with"]["name"]
        == "macos-${{ matrix.stage }}-evidence-${{ inputs.request_id || inputs.source || github.event.pull_request.head.sha || github.sha }}-${{ github.run_attempt }}"
    )
    assert "test-results/" in evidence["with"]["path"]
    assert {"coverage/", "apps/desktop/coverage/lcov.info"} <= set(
        evidence["with"]["path"].splitlines()
    )

    package = jobs["macos"]
    assert package["needs"] == ["changes", "distribution-number", "macos-checks"]
    assert "always()" in package["if"]
    commands = "\n".join(step.get("run", "") for step in package["steps"])
    assert commands.count("tools/build.sh") == 1
    assert "--platform macos --stage all --build-only" in commands
    assert commands.index("cmake -S .") < commands.index("verify_macos_cmake_cache.py")
    assert commands.index("verify_macos_cmake_cache.py") < commands.index(
        "tools/build.sh"
    )
    assert commands.index("tools/build.sh") < commands.index("tools/package_macos.py")
    assert commands.index("tools/package_macos.py") < commands.index(
        "verify_macos_release_runtime.py"
    )
    assert commands.index("verify_macos_release_runtime.py") < commands.index(
        "smoke_macos_bundle.py"
    )
    assert (
        commands.count("tools/package_macos.py")
        == commands.count("smoke_macos_bundle.py")
        == 1
    )
    assert "macos-stages" not in jobs
    assert not (ROOT / ".github/workflows/macos-platform-stages.yml").exists()
    for job in (checks, package):
        assert job["env"]["FORESIGHT_MACOS_UI_TEST"] == "1"
        assert job["env"]["FORESIGHT_REQUIRE_NATIVE_UI_TEST"] == "1"
        lane_commands = "\n".join(step.get("run", "") for step in job["steps"])
        assert "--coverage" not in lane_commands
        assert "run_ci_stage" not in lane_commands
        assert "ci_native_work.py" not in lane_commands
        assert not any(step.get("continue-on-error") for step in job["steps"])
        assert not any(
            "download-artifact@" in step.get("uses", "") for step in job["steps"]
        )
    assert "macos" in jobs["platform-checks"]["needs"]
    assert package["outputs"] == {
        "bundle_id": "${{ steps.macos-candidate.outputs.artifact-id }}",
        "bundle_digest": "${{ steps.macos-candidate.outputs.artifact-digest }}",
        "attempt": "${{ steps.macos-receipt.outputs.attempt }}",
    }
    for step in package["steps"]:
        if step.get("id") in {"macos-inference", "macos-installed", "macos-smoke"}:
            assert (
                step["if"]
                == "${{ !cancelled() && steps.macos-assembly.outcome == 'success' }}"
            )
        if (
            step.get("id") in {"macos-receipt", "macos-candidate"}
            or "publish-receipt" in step.get("run", "")
            or step.get("with", {})
            .get("name", "")
            .startswith(("receipt-ci-macos-app-", "preview-macos-application"))
        ):
            assert "needs.macos-checks.result == 'success'" in step["if"]
            assert "always()" not in step["if"]
    assert workflow["permissions"] == {"contents": "read", "actions": "read"}


@pytest.mark.parametrize(
    "failed_result,outcome",
    [(None, "success")]
    + [
        (name, outcome)
        for name in (
            "CHECKS_RESULT",
            "BUILD_RESULT",
            "ASSEMBLY_RESULT",
            "INFERENCE_RESULT",
            "INSTALLED_RESULT",
            "SMOKE_RESULT",
        )
        for outcome in ("failure", "cancelled", "skipped")
    ],
)
def test_real_mac_aggregate_requires_every_lane_and_package(failed_result, outcome):
    step = next(
        step
        for step in config()["jobs"]["macos"]["steps"]
        if step.get("name") == "Require every Mac test lane and package check"
    )
    outcomes = {name: "success" for name in step["env"]}
    if failed_result:
        outcomes[failed_result] = outcome
    result = subprocess.run(
        ["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", step["run"]],
        env=_shell_environment({**os.environ, **outcomes}),
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert (result.returncode == 0) == (failed_result is None), (
        result.stdout + result.stderr
    )


@pytest.mark.parametrize("result", ["failure", "cancelled", "skipped"])
def test_aggregate_rejects_non_successful_consolidated_job(result):
    from tools.ci_changes import check_gates, select_gates

    selected = select_gates(["apps/desktop/macos/source.swift"])
    jobs = {
        name: {"result": "success" if needed else "skipped"}
        for name, needed in selected.items()
    }
    jobs["changes"] = {"result": "success"}
    jobs["macos"] = {"result": result}
    jobs["linux-native"] = {"result": "skipped"}
    with pytest.raises(ValueError, match="macos: expected success"):
        check_gates(jobs, selected)


def publisher():
    return parse_workflow(
        (ROOT / ".github/workflows/macos-cache-publish.yml").read_text()
    )


def test_mac_application_is_restore_only_and_dedicated_publisher_preserves_keys():
    consumer = setup()
    workflow = publisher()
    assert set(workflow["on"]) == {"workflow_call", "workflow_dispatch"}
    assert workflow["permissions"] == {"contents": "read", "actions": "read"}
    job = workflow["jobs"]["publish-macos-caches"]
    assert "github.ref == 'refs/heads/main'" in job["if"]
    assert '"schedule","workflow_dispatch"' in job["if"]
    assert "github.workflow_ref" in job["if"]
    assert ".github/workflows/preview-packages.yml@refs/heads/main" in job["if"]
    assert ".github/workflows/macos-cache-publish.yml@refs/heads/main" in job["if"]
    steps = job["steps"]
    assert not any("/save@" in step.get("uses", "") for step in consumer)
    checkout = steps[0]
    assert checkout["with"]["ref"] == "${{ github.sha }}"
    assert checkout["with"]["persist-credentials"] is False
    commands = "\n".join(step.get("run", "") for step in steps)
    for forbidden in (
        "ci_macos_dependencies",
        "ci_dependency_wait",
        "cmake",
        "build.sh",
        "flutter build",
        "xcodebuild",
        "dart compile",
        "ci_native_work",
    ):
        assert forbidden not in commands
    for cache in ("flutter", "pub"):
        restore = next(step for step in consumer if step.get("id") == cache)
        published_restore = next(step for step in steps if step.get("id") == cache)
        assert published_restore == restore
        save = next(
            step
            for step in steps
            if "/save@" in step.get("uses", "")
            and step["with"]["path"] == restore["with"]["path"]
        )
        assert save["with"]["key"] == restore["with"]["key"]
        assert "-ui-v2" in save["with"]["key"]
        assert save["if"] == f"steps.{cache}.outputs.cache-hit != 'true'"
    pin = next(
        step
        for step in consumer
        if step.get("name") == "Verify the pinned macOS Flutter SDK"
    )
    assert pin in steps
    first_check = next(
        i
        for i, step in enumerate(steps)
        if step.get("name") == "Verify reviewed current main before warming"
    )
    for i, step in enumerate(steps):
        if "/restore@" in step.get("uses", "") or step.get("name") in (
            "Verify the pinned macOS Flutter SDK",
            "Warm the pinned desktop engine cache",
            "Resolve locked language prerequisites",
        ):
            assert first_check < i
    nightly = parse_workflow(
        (ROOT / ".github/workflows/preview-packages.yml").read_text()
    )
    call = nightly["jobs"]["publish-macos-caches"]
    assert call["uses"] == "./.github/workflows/macos-cache-publish.yml"
    assert call["needs"] == "plan"
    assert "needs.plan.result == 'success'" in call["if"]
    assert "needs.plan.outputs.build == 'true'" in call["if"]
    assert "github.ref == 'refs/heads/main'" in call["if"]
    assert '"schedule","workflow_dispatch"' in call["if"]
    assert "!inputs.exercise_failure_path" in call["if"]
    before_save = next(
        i for i, step in enumerate(steps) if "/save@" in step.get("uses", "")
    )
    assert steps[before_save - 1]["name"] == "Verify current main before publishing"


@pytest.mark.parametrize(
    "ref,event,source,current,head,allowed",
    [
        ("refs/heads/main", "schedule", "a" * 40, "a" * 40, "a" * 40, True),
        ("refs/heads/main", "workflow_dispatch", "a" * 40, "a" * 40, "a" * 40, True),
        ("refs/heads/main", "pull_request", "a" * 40, "a" * 40, "a" * 40, False),
        (
            "refs/heads/feature",
            "workflow_dispatch",
            "a" * 40,
            "a" * 40,
            "a" * 40,
            False,
        ),
        ("refs/heads/main", "push", "a" * 40, "a" * 40, "a" * 40, False),
        ("refs/heads/main", "schedule", "a" * 40, "b" * 40, "a" * 40, False),
        ("refs/heads/main", "schedule", "a" * 40, "a" * 40, "b" * 40, False),
    ],
)
@pytest.mark.parametrize(
    "startup", [False, True], ids=["clean_env", "inherited_startup"]
)
def test_real_mac_publisher_source_guards_fail_closed(
    tmp_path, monkeypatch, startup, ref, event, source, current, head, allowed
):
    marker = tmp_path / "startup-ran"
    if startup:
        startup_file = tmp_path / ".bashrc"
        startup_file.write_text('printf startup > "$STARTUP_MARKER"; exit 97\n')
        for name in ("BASH_ENV", "ENV"):
            monkeypatch.setenv(name, str(startup_file))
        monkeypatch.setenv("HOME", str(tmp_path))
        monkeypatch.setenv("SSH_CLIENT", "127.0.0.1 12345 22")
        monkeypatch.setenv("STARTUP_MARKER", str(marker))
    binary = tmp_path / "bin"
    binary.mkdir()
    for name, value in (("git", head), ("gh", current)):
        command = binary / name
        command.write_text("#!/bin/sh\nprintf '%s\\n' '" + value + "'\n")
        command.chmod(0o755)
    checks = [
        step
        for step in publisher()["jobs"]["publish-macos-caches"]["steps"]
        if step.get("name", "").startswith("Verify") and "current main" in step["name"]
    ]
    assert len(checks) == 2
    for check in checks:
        result = subprocess.run(
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-euo",
                "pipefail",
                "-c",
                check["run"],
            ],
            cwd=tmp_path,
            env=_shell_environment(
                {
                    **os.environ,
                    "PATH": str(binary),
                    "GITHUB_REF": ref,
                    "GITHUB_EVENT_NAME": event,
                    "SOURCE": source,
                    "GITHUB_REPOSITORY": "owner/repo",
                    "GITHUB_WORKFLOW_REF": "owner/repo/.github/workflows/preview-packages.yml@refs/heads/main",
                }
            ),
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert (result.returncode == 0) == allowed, result.stdout + result.stderr
        assert not marker.exists(), "Fixture shell must ignore inherited startup files"


def test_real_language_warmup_resolves_both_locks_before_any_save(tmp_path):
    for package in ("packages/foresight_core", "apps/desktop"):
        (tmp_path / package).mkdir(parents=True)
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    for name in ("dart", "flutter"):
        script = binary / name
        script.write_text(
            '#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["MAC_SETUP_LOG"],"a") as f: f.write(json.dumps([os.path.basename(sys.argv[0]),os.getcwd(),sys.argv[1:]])+"\\n")\n'
        )
        script.chmod(0o755)
    for step in publisher()["jobs"]["publish-macos-caches"]["steps"]:
        if step.get("name") in (
            "Warm the pinned desktop engine cache",
            "Resolve locked language prerequisites",
        ):
            assert step in setup()
            subprocess.run(
                [
                    "/bin/bash",
                    "--noprofile",
                    "--norc",
                    "-euo",
                    "pipefail",
                    "-c",
                    step["run"],
                ],
                cwd=tmp_path,
                env=_shell_environment(
                    {
                        **os.environ,
                        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                        "MAC_SETUP_LOG": str(log),
                    }
                ),
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )
        if "/save@" in step.get("uses", ""):
            assert [json.loads(line) for line in log.read_text().splitlines()] == [
                ["flutter", str(tmp_path), ["precache", "--macos"]],
                [
                    "dart",
                    str(tmp_path / "packages/foresight_core"),
                    ["pub", "get", "--enforce-lockfile"],
                ],
                [
                    "flutter",
                    str(tmp_path / "apps/desktop"),
                    ["pub", "get", "--enforce-lockfile"],
                ],
            ]


@pytest.mark.parametrize("qualified", [True, False])
@pytest.mark.parametrize(
    "lane,native_failure",
    [(lane, False) for lane in ("package", "native", "core", "desktop", "service")]
    + [(lane, True) for lane in ("core", "desktop", "service")],
)
def test_real_build_step_shell_preserves_cmake_arguments_and_stops_before_build_on_bad_roots(
    tmp_path, configured, qualified, lane, native_failure
):
    import shlex
    import shutil
    import sys

    cache, sdk, icu = configured
    workspace = tmp_path / "workspace with spaces"
    (workspace / "build").mkdir(parents=True)
    (workspace / "build/sdk").symlink_to(sdk, target_is_directory=True)
    (workspace / ".venv/bin").mkdir(parents=True)
    (workspace / ".venv/bin/python").symlink_to(sys.executable)
    (workspace / "tools").mkdir()
    shutil.copy2(ROOT / "tools/verify_macos_cmake_cache.py", workspace / "tools")
    if not qualified:
        cache.write_text(
            cache.read_text().replace(str(sdk / "lib/cmake/gRPC"), str(tmp_path))
        )
    binary = workspace / "bin"
    binary.mkdir()
    brew = binary / "brew"
    brew.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(str(icu)) + "\n")
    brew.chmod(0o755)
    log = workspace / "commands.jsonl"
    fake = '#!/usr/bin/env python3\nimport json,os,shutil,sys\nwith open(os.environ["MAC_BUILD_LOG"],"a") as f: f.write(json.dumps([os.path.basename(sys.argv[0]),sys.argv[1:]])+"\\n")\nif os.path.basename(sys.argv[0]) == "cmake": shutil.copy2(os.environ["MAC_BUILD_CACHE"],"build/CMakeCache.txt")\nprint("stub-build")\nif os.environ.get("MAC_FAIL_NATIVE") == "1" and "--stage" in sys.argv and sys.argv[sys.argv.index("--stage")+1] == "native": sys.exit(91)\n'
    for executable in (
        binary / "cmake",
        workspace / "tools/build.sh",
    ):
        executable.write_text(fake)
        executable.chmod(0o755)
    step = next(
        step
        for step in config()["jobs"]["macos" if lane == "package" else "macos-checks"][
            "steps"
        ]
        if "tools/build.sh" in step.get("run", "")
    )
    result = subprocess.run(
        ["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", step["run"]],
        cwd=workspace,
        env=_shell_environment(
            {
                **os.environ,
                "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                "MAC_BUILD_LOG": str(log),
                "MAC_BUILD_CACHE": str(cache),
                "MACOS_CHECK_STAGE": lane,
                "MAC_FAIL_NATIVE": "1" if native_failure else "0",
            }
        ),
        capture_output=True,
        text=True,
        timeout=15,
    )
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert calls[0][0] == "cmake"
    if qualified:
        if native_failure:
            assert result.returncode == 91
            assert (
                "stub-build"
                in (workspace / f"test-results/macos/{lane}.log").read_text()
            )
            assert len(calls) == 2, (
                "Failed native prerequisite must stop dependent stages"
            )
            assert calls[-1][1][:5] == [
                "--platform",
                "macos",
                "--stage",
                "native",
                "--build-only",
            ]
            return
        assert result.returncode == 0, result.stdout + result.stderr
        assert calls[-1][0] == "build.sh"
        prefixes = {
            "package": [["all", "--build-only"]],
            "native": [["native"]],
            "core": [["native", "--build-only"], ["core"]],
            "desktop": [["native", "--build-only"], ["desktop"]],
            "service": [
                ["native", "--build-only"],
                ["core", "--build-only"],
                ["service"],
            ],
        }[lane]
        assert len(calls) == len(prefixes) + 1
        assert calls[0][1][:6] == [
            "-S",
            ".",
            "-B",
            "build",
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DPython3_EXECUTABLE={workspace}/.venv/bin/python",
        ]
        expected_args = [
            "-G",
            "Ninja",
            f"-DCMAKE_PREFIX_PATH={workspace}/build/sdk",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "-DCMAKE_OSX_ARCHITECTURES=arm64",
            f"-DICU_ROOT={icu}",
            "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local",
        ]
        assert calls[0][1][6:] == expected_args
        for call, prefix in zip(calls[1:], prefixes, strict=True):
            expected = ["--platform", "macos", "--stage", *prefix]
            assert call == ["build.sh", expected + expected_args]
    else:
        assert result.returncode == 1
        assert "gRPC_DIR must resolve inside" in result.stdout + result.stderr
        evidence = workspace / (
            "test-results/macos/package-build.log"
            if lane == "package"
            else f"test-results/macos/{lane}.log"
        )
        assert "gRPC_DIR must resolve inside" in evidence.read_text()
        assert len(calls) == 1


def test_nightly_reports_macos_coverage_while_prs_always_leave_it_disabled():
    workflow = config()
    assert workflow["on"]["workflow_call"]["inputs"]["macos_coverage"] == {
        "description": "Collect non-gating nightly macOS coverage",
        "type": "boolean",
        "default": False,
    }
    nightly = parse_workflow(
        (ROOT / ".github/workflows/preview-packages.yml").read_text()
    )
    assert nightly["jobs"]["build"]["with"]["macos_coverage"] is True
    environment = workflow["jobs"]["macos-checks"]["env"]
    assert (
        environment["FORESIGHT_COVERAGE"]
        == "${{ (inputs.tier == 'release' || inputs.macos_coverage) && github.event_name != 'pull_request' && '1' || '0' }}"
    )
    assert environment["FORESIGHT_CORE_COVERAGE_MIN"] == "0"
    evidence = next(
        step
        for step in workflow["jobs"]["macos"]["steps"]
        if step.get("name") == "Retain development package evidence"
    )
    assert "coverage/" in evidence["with"]["path"].splitlines()
    assert "apps/desktop/coverage/lcov.info" in evidence["with"]["path"].splitlines()


@pytest.mark.parametrize(
    "event,caller,allowed",
    [
        ("schedule", "preview-packages.yml", True),
        ("workflow_dispatch", "preview-packages.yml", True),
        ("workflow_dispatch", "macos-cache-publish.yml", True),
        ("schedule", "macos-cache-publish.yml", False),
        ("schedule", "weekly-drift.yml", False),
        ("workflow_dispatch", "unrelated.yml", False),
    ],
)
def test_mac_publisher_runtime_allows_only_approved_entrypoints(
    tmp_path, event, caller, allowed
):
    binary = tmp_path / "bin"
    binary.mkdir()
    for name in ("git", "gh"):
        executable = binary / name
        executable.write_text("#!/bin/sh\nprintf '%s\\n' '" + "a" * 40 + "'\n")
        executable.chmod(0o755)
    steps = publisher()["jobs"]["publish-macos-caches"]["steps"]
    for step in steps:
        if step.get("name", "").startswith("Verify") and "current main" in step["name"]:
            result = subprocess.run(
                [
                    "/bin/bash",
                    "--noprofile",
                    "--norc",
                    "-euo",
                    "pipefail",
                    "-c",
                    step["run"],
                ],
                cwd=tmp_path,
                env=_shell_environment(
                    {
                        **os.environ,
                        "PATH": str(binary),
                        "GITHUB_REF": "refs/heads/main",
                        "GITHUB_EVENT_NAME": event,
                        "GITHUB_REPOSITORY": "owner/repo",
                        "SOURCE": "a" * 40,
                        "GITHUB_WORKFLOW_REF": f"owner/repo/.github/workflows/{caller}@refs/heads/main",
                    }
                ),
                capture_output=True,
                text=True,
                timeout=10,
            )
            assert (result.returncode == 0) == allowed, result.stdout + result.stderr


@pytest.mark.parametrize(
    "name",
    [
        "Verify current main before publishing the document toolchain cache",
        "Verify current main immediately before saving the document toolchain cache",
    ],
)
@pytest.mark.parametrize(
    "scenario",
    ["current", "advanced", "wrong-source", "pr-ref", "pr-event", "transport"],
)
def test_document_cache_guard_skips_only_superseded_cache_work(
    tmp_path, name, scenario
):
    step = next(
        step
        for step in config()["jobs"]["publish-caches"]["steps"]
        if step.get("name") == name
    )
    binary = tmp_path / "bin"
    binary.mkdir()
    for tool, script in {
        "git": 'test "$1:$2" = rev-parse:HEAD || exit 99\nprintf "%s\\n" "$FIXTURE_HEAD"\n',
        "gh": 'test "$1" = api || exit 99\nif test "$FIXTURE_TRANSPORT" = 1; then exit 42; fi\nprintf "%s\\n" "$FIXTURE_MAIN"\n',
    }.items():
        path = binary / tool
        path.write_text("#!/bin/sh\n" + script)
        path.chmod(0o755)
    source = "a" * 40
    output = tmp_path / "output"
    env = _shell_environment(os.environ)
    env.update(
        PATH=str(binary) + os.pathsep + env["PATH"],
        SOURCE=source,
        GITHUB_REF="refs/pull/999/merge" if scenario == "pr-ref" else "refs/heads/main",
        GITHUB_EVENT_NAME="pull_request" if scenario == "pr-event" else "push",
        GITHUB_REPOSITORY="example/foresight",
        GITHUB_OUTPUT=str(output),
        FIXTURE_HEAD="b" * 40 if scenario == "wrong-source" else source,
        FIXTURE_MAIN="b" * 40 if scenario == "advanced" else source,
        FIXTURE_TRANSPORT=str(int(scenario == "transport")),
    )
    result = subprocess.run(
        [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-e",
            "-o",
            "pipefail",
            "-c",
            step["run"],
        ],
        env=env,
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if scenario in {"current", "advanced"}:
        assert result.returncode == 0, result.stdout + result.stderr
        assert (
            output.read_text() == "current=" + str(scenario == "current").lower() + "\n"
        )
    else:
        assert result.returncode != 0, result.stdout + result.stderr
        assert not output.exists()


def test_mac_matrix_covers_the_public_all_stage_contract():
    source = (ROOT / "tools/build.sh").read_text()
    choices = re.search(r'case "\$task_stage" in\s*([a-z|]+)\) ;;;?', source)
    assert choices is not None
    stages = set(choices.group(1).split("|")) - {"all"}
    assert (
        set(config()["jobs"]["macos-checks"]["strategy"]["matrix"]["stage"])
        - {"contracts"}
        == stages
    )
    assert "--all-stages" in source


def test_lane_evidence_reuses_existing_reviewed_paths_and_callers_are_unique():
    jobs = config()["jobs"]
    lane = next(
        step for step in jobs["macos-checks"]["steps"] if step.get("if") == "always()"
    )
    package = next(
        step
        for step in jobs["macos"]["steps"]
        if step.get("name") == "Retain development package evidence"
    )
    assert lane["with"]["overwrite"] is True
    assert set(lane["with"]["path"].splitlines()) <= set(
        package["with"]["path"].splitlines()
    )
    for path in (ROOT / ".github/workflows").glob("*.yml"):
        workflow = parse_workflow(path.read_text())
        calls = [
            job
            for job in workflow.get("jobs", {}).values()
            if job.get("uses") == "./.github/workflows/macos.yml"
        ]
        assert len(calls) <= 1, (
            "Repeated same-source invocations need distinct evidence identities"
        )
