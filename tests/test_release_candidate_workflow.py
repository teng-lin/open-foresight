"""The release coordinator cannot skip required gates or rename untested bundles."""

from pathlib import Path
import subprocess

import pytest
import yaml

from tools import ci_release_candidates as candidates
from tools.release_acceptance_report import require_coordinator

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    result = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
    if True in result:
        result["on"] = result.pop(True)
    return result


def test_release_preflight_precedes_all_producers_and_candidates_only_stops_before_draft():
    release = workflow("release.yml")
    assert release["on"]["workflow_dispatch"]["inputs"]["tag"]["required"] is False
    assert (
        release["on"]["workflow_dispatch"]["inputs"]["candidates_only"]["default"]
        is False
    )
    assert release["permissions"] == {"contents": "read", "actions": "read"}
    jobs = release["jobs"]
    assert "needs" not in jobs["preflight"]
    assert "permissions" not in jobs["preflight"]
    candidate = jobs["candidates"]
    assert candidate["needs"] == "preflight"
    assert "github.event_name == 'workflow_dispatch'" in candidate["if"]
    assert "github.ref == 'refs/heads/main'" in candidate["if"]
    assert "!inputs.publish_only" in candidate["if"]
    assert "needs.preflight.outputs.reuse != 'true'" in candidate["if"]
    assert candidate["uses"] == "./.github/workflows/macos.yml"
    assert candidate["with"]["tier"] == "release"
    assert candidate["with"]["acceptance"] == "full"
    assert candidate["with"]["macos_coverage"] is True
    assert candidate["with"]["source"] == "${{ needs.preflight.outputs.source }}"
    assert candidate["secrets"] == "inherit"
    # Nested job permissions require this union even when a job is skipped.
    assert candidate["permissions"] == {
        "contents": "write",
        "actions": "read",
        "packages": "write",
        "pull-requests": "read",
    }
    assert set(jobs["candidate-receipt"]["needs"]) == {"preflight", "candidates"}
    assert "needs.candidates.result == 'success'" in jobs["candidate-receipt"]["if"]
    for name in ("prepare", "acceptance", "publish"):
        assert "!inputs.candidates_only" in jobs[name]["if"]
    assert set(jobs["prepare"]["needs"]) == {
        "preflight",
        "candidates",
        "candidate-receipt",
    }
    assert "needs.candidate-receipt.result == 'success'" in jobs["prepare"]["if"]
    assert "needs.preflight.outputs.reuse == 'true'" in jobs["prepare"]["if"]
    steps = jobs["candidate-receipt"]["steps"]
    indexes = [
        step
        for step in steps
        if step.get("with", {}).get("name", "").startswith("ci-release-")
    ]
    assert {step["with"]["name"] for step in indexes} == {
        "ci-release-candidate-${{ needs.preflight.outputs.source }}",
        "ci-release-evidence-${{ needs.preflight.outputs.source }}",
    }
    for step in indexes:
        assert step["with"]["overwrite"] is True
        assert step["with"]["if-no-files-found"] == "error"
    fresh = next(
        step for step in indexes if "ci-release-candidate-" in step["with"]["name"]
    )
    assert "reuse != 'true'" in fresh["if"]
    forwarding = next(
        step for step in indexes if "ci-release-evidence-" in step["with"]["name"]
    )
    assert "reuse == 'true'" in forwarding["if"]


def test_each_reusable_candidate_consumer_receives_its_own_source_floor():
    # Workflow-level caller env does not propagate into reusable workflows.
    for name in ("release.yml", "macos.yml", "linux-packages.yml", "macos-release.yml"):
        assert (
            workflow(name)["env"]["RELEASE_SOURCE_FLOOR"]
            == "${{ vars.RELEASE_SOURCE_FLOOR }}"
        )


def test_release_producer_outputs_names_and_full_gates_match_the_verified_index():
    platform = workflow("macos.yml")
    jobs = platform["jobs"]
    for gate in candidates.GATES:
        if gate.startswith("packaging / "):
            package = workflow("package-contracts.yml")["jobs"]
            if gate.endswith("dmg"):
                assert "dmg" in package
            else:
                assert package["linux"]["name"] == "linux-${{ matrix.format }}"
                assert gate.rsplit("-", 1)[1] in {
                    item["format"]
                    for item in package["linux"]["strategy"]["matrix"]["include"]
                }
        elif gate.startswith("sanitizers / "):
            assert (
                gate.removeprefix("sanitizers / ")
                in workflow("native-sanitizers.yml")["jobs"]
            )
        else:
            assert gate in jobs
    for job in jobs.values():
        for step in job.get("steps", []):
            if step.get("uses", "").startswith("actions/checkout@"):
                assert "inputs.source" in step["with"]["ref"]
    outputs = platform["on"]["workflow_call"]["outputs"]
    assert {
        f"{name}_bundle_{field}"
        for name in ("linux", "macos")
        for field in ("id", "digest", "attempt")
    } <= outputs.keys()
    for name in candidates.CONSUMERS:
        steps = jobs[name]["steps"]
        upload = next(
            step
            for step in steps
            if step.get("with", {}).get("name")
            == f"ci-release-input-{name}-${{{{ inputs.source || github.event.pull_request.head.sha || github.sha }}}}"
        )
        assert upload["if"] == "inputs.tier == 'release'"
        assert upload["with"]["path"].endswith("/consumption.json")
    for name in ("acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        steps = jobs[name]["steps"]
        setup = next(
            step
            for step in steps
            if step.get("uses") == "./.github/actions/setup-linux-consumer"
        )
        assert "inputs.tier != 'release'" in setup["with"]["legacy-main"]
        assert "inputs.tier != 'release'" in setup["with"]["artifact-id"]
        run = next(step for step in steps if "ACCEPTANCE_FULL" in step.get("env", {}))
        assert "inputs.tier == 'release'" in run["env"]["ACCEPTANCE_FULL"]
    assert "inputs.tier != 'release'" in jobs["linux-bundle"]["if"]
    assert "inputs.tier != 'release'" in jobs["linux-native"]["if"]
    assert "inputs.tier == 'release'" in jobs["macos"]["env"]["FORESIGHT_COVERAGE"]
    assert "inputs.tier != 'release'" in jobs["publish-caches"]["if"]
    assert jobs["sanitizers"]["with"] == {
        "source": "${{ inputs.source }}",
        "consume_only": True,
    }
    linux_upload = next(
        step for step in jobs["linux-build"]["steps"] if step.get("id") == "bundle"
    )
    assert "format('ci-linux-app-{0}', inputs.source)" in linux_upload["with"]["name"]
    ordinary_upload = next(
        step
        for step in jobs["linux-bundle"]["steps"]
        if step.get("id") == "linux-candidate"
    )
    assert ordinary_upload["with"]["name"].startswith("main-linux-bundle-")
    mac_upload = next(
        step for step in jobs["macos"]["steps"] if step.get("id") == "macos-candidate"
    )
    assert "'ci-macos-app' || 'main-macos-app'" in mac_upload["with"]["name"]


def test_only_release_candidates_publish_canonical_candidate_sidecars():
    jobs = workflow("macos.yml")["jobs"]
    for name in ("macos", "linux-build"):
        publications = [
            step
            for step in jobs[name]["steps"]
            if "publish-receipt" in step.get("run", "")
        ]
        assert len(publications) == 1
        assert "inputs.tier == 'release'" in publications[0]["if"]
        sidecars = [
            step
            for step in jobs[name]["steps"]
            if step.get("with", {}).get("name", "").startswith("receipt-ci-")
        ]
        assert len(sidecars) == 1
        assert "inputs.tier == 'release'" in sidecars[0]["if"]
    assert not any(
        "publish-receipt" in step.get("run", "")
        for step in jobs["linux-bundle"]["steps"]
    )
    assert not any(
        step.get("with", {}).get("name", "").startswith("receipt-main-")
        for job in jobs.values()
        for step in job.get("steps", [])
    )


def test_reusable_sanitizers_are_consume_only_without_probation_or_sdk_writes():
    sanitizer = workflow("native-sanitizers.yml")
    assert sanitizer["on"]["workflow_call"]["inputs"]["consume_only"]["default"] is True
    jobs = sanitizer["jobs"]
    assert (
        "!inputs.consume_only" in jobs["native-thread-sanitizer"]["continue-on-error"]
    )
    for name in ("native-sanitizers", "native-thread-sanitizer"):
        for step in jobs[name]["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                assert "inputs.source" in step["with"]["ref"]
            command = step.get("run", "")
            if (
                "build_sanitizer_sdk.py" in command
                or " pack --kind " in command
                or step.get("uses", "").startswith(
                    ("actions/cache/save@", "actions/upload-artifact@")
                )
                and "sdk" in step.get("with", {}).get("path", "")
            ):
                assert "!inputs.consume_only" in step["if"]
            if "ALLOW_BUILD" in step.get("env", {}):
                assert "!inputs.consume_only" in step["env"]["ALLOW_BUILD"]
    assert "drift-issue" not in jobs
    assert sanitizer["permissions"] == {"contents": "read", "actions": "read"}
    assert all(
        "write" not in job.get("permissions", {}).values() for job in jobs.values()
    )
    assert "issues" not in workflow("release.yml")["jobs"]["candidates"]["permissions"]


@pytest.mark.parametrize(
    "publish_only,reuse", [(False, False), (False, True), (True, True)]
)
def test_coordinator_requires_exact_candidate_and_installer_states(publish_only, reuse):
    expected = "skipped" if publish_only else "success"
    results = {job: {"result": expected} for job in ("prepare", "linux", "macos")}
    results.update(
        {
            "preflight": {"result": "success"},
            "acceptance": {"result": "success"},
            "candidates": {
                "result": "skipped" if (reuse or publish_only) else "success"
            },
            "candidate-receipt": {"result": expected},
        }
    )
    require_coordinator(results, "refs/heads/main", publish_only, reuse=reuse)
    for name in results:
        for status in ("failure", "cancelled", "skipped", "success"):
            if status == results[name]["result"]:
                continue
            with pytest.raises(ValueError, match="unpublished"):
                require_coordinator(
                    {**results, name: {"result": status}},
                    "refs/heads/main",
                    publish_only,
                    reuse=reuse,
                )
    if publish_only:
        with pytest.raises(ValueError, match="unpublished"):
            require_coordinator(results, "refs/heads/main", True)


def test_linux_release_upload_keeps_internal_metadata_private(tmp_path):
    step = next(
        step
        for step in workflow("linux-packages.yml")["jobs"]["publish"]["steps"]
        if step.get("name") == "Attach tested Linux packages to release"
    )
    expected = {
        "artifacts/portable-bundle/application.tar.gz",
        "artifacts/portable-bundle/application.tar.gz.sha256",
        "artifacts/portable-bundle/application.build.json",
        "artifacts/portable-bundle/abi.json",
        "artifacts/open-foresight-deb-x86-64/application.deb",
    }
    private = {
        "artifacts/portable-bundle/sdk-reference.json",
        "artifacts/portable-bundle/source-qualification.json",
    }
    for name in expected | private:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
    # Execute the actual asset-selection shell; intercept only remote release
    # inspection and upload, retaining the real find/read/array behavior.
    output = subprocess.check_output(
        [
            "bash",
            "-euc",
            "gh() { printf true; }\npython() { printf '%s\\0' \"$@\"; }\n"
            + step["run"],
        ],
        cwd=tmp_path,
        env={"RELEASE_TAG": "v1.2.3"},
        timeout=30,
    )
    arguments = output.decode().rstrip("\0").split("\0")
    assert arguments[:4] == ["-m", "tools.release_upload", "--tag", "v1.2.3"]
    assert len(arguments[4:]) == len(expected)
    assert set(arguments[4:]) == expected
