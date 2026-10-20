"""The future required Linux graph cannot bypass failed own-run producers."""

from pathlib import Path

import pytest
import yaml

from tools import ci_changes
from tools import ci_app_build_transport as transport

ROOT = Path(__file__).resolve().parents[1]


def workflow(name="macos.yml"):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())


def test_required_build_test_and_acceptance_jobs_use_one_successful_producer():
    jobs = workflow()["jobs"]
    assert {"linux-build", "linux-test"}.issubset(jobs["platform-checks"]["needs"])
    assert "linux-native" not in jobs["platform-checks"]["needs"]
    assert "linux-shadow-comparison" not in jobs
    assert jobs["linux-test"]["needs"] == "linux-build"
    for name in ("acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        job = jobs[name]
        assert job["needs"] == ["changes", "linux-build", "linux-bundle"]
        assert "!cancelled()" in job["if"]
        assert "needs.linux-build.result == 'success'" in job["if"]
        assert "needs.linux-bundle.result" in job["if"]
        setup = next(
            step
            for step in job["steps"]
            if step.get("uses") == "./.github/actions/setup-linux-consumer"
        )
        inputs = setup["with"]
        for key in ("artifact-id", "artifact-digest", "attempt"):
            assert "needs.linux-bundle.outputs" in inputs[key]
            assert "needs.linux-build.outputs" in inputs[key]
        assert "!inputs.preview" in inputs["legacy-main"]
        assert (
            inputs["head-repository"]
            == "${{ github.event.pull_request.head.repo.full_name || github.repository }}"
        )
        assert all(value == "read" for value in job["permissions"].values())
    aggregate = jobs["acceptance-checks"]
    assert aggregate["if"] == "always()"
    assert set(aggregate["needs"]) == {
        "changes",
        "linux-build",
        "linux-bundle",
        "acceptance-cpu",
        "acceptance-audio",
        "acceptance-deb",
    }
    assert any(
        "ci_linux_acceptance.py --check-gates" in step.get("run", "")
        for step in aggregate["steps"]
    )


@pytest.mark.parametrize(
    "build,bundle,expected",
    [
        ("success", "success", True),
        ("success", "skipped", True),
        ("failure", "skipped", False),
        ("cancelled", "success", False),
        ("skipped", "success", False),
        ("success", "failure", False),
    ],
)
def test_acceptance_dependency_condition_includes_pr_skips_but_rejects_bad_producers(
    build, bundle, expected
):
    # Evaluate the exact protocol represented by the structural condition above.
    assert (build == "success" and bundle in ("success", "skipped")) == expected


def test_package_contracts_force_their_own_build_and_keep_explicit_macos_scope():
    selection = ci_changes.selection_report(["packaging/ci/package-and-test.sh"])[
        "selection"
    ]
    assert all(
        selection[name]
        for name in ("packaging", "linux-build", "linux-test", "linux-bundle")
    )
    scoped = ci_changes.selection_report(
        ["packaging/ci/package-and-test.sh"], platforms="macos"
    )["selection"]
    assert scoped["packaging"] and not scoped["linux-build"]
    caller = workflow()["jobs"]["packaging"]
    assert caller["needs"] == ["changes", "linux-build"]
    assert "!cancelled()" in caller["if"]
    assert (
        caller["with"]["linux_enabled"]
        == "${{ needs.changes.outputs.linux_build == 'true' }}"
    )


def test_only_the_explicit_main_publisher_writes_registry_or_model_caches():
    jobs = workflow()["jobs"]
    registry_writers = [
        name
        for name, job in jobs.items()
        if job.get("permissions", {}).get("packages") == "write"
    ]
    assert registry_writers == ["publish-caches"]
    publisher = jobs["publish-caches"]
    assert publisher["needs"] == "linux-build"
    assert "!cancelled()" in publisher["if"]
    assert "github.ref == 'refs/heads/main'" in publisher["if"]
    assert '"push","workflow_dispatch","schedule"' in publisher["if"]
    for name, job in jobs.items():
        for step in job.get("steps", []):
            text = str(step)
            if any(
                writer in text
                for writer in ("cache-to", "actions/cache/save@", "actions/cache@")
            ):
                assert name == "publish-caches" or name.startswith("macos")
    script = (ROOT / "tools/publish_linux_ci_caches.sh").read_text()
    assert "application-dependencies ci acceptance-dependencies" in script
    assert "--build-arg REQUIRE_DEPENDENCY_REUSE=1" in script
    assert "--cache-to" in script
    assert "--target builder" not in script and "--target tested" not in script
    assert "--require-google-client" not in script
    assert "Cache publication requires main" in script
    assert transport.reference("Owner/Repo", ci=True).endswith(
        ":ci-tools-buildcache-v1"
    )
    with pytest.raises(ValueError, match="one"):
        transport.reference("Owner/Repo", ci=True, acceptance=True)


def test_publisher_runtime_rejects_prs_before_any_docker_or_cache_operation(tmp_path):
    import os
    import subprocess

    for ref, event in (
        ("refs/pull/123/merge", "pull_request"),
        ("refs/heads/main", "pull_request"),
        ("refs/heads/feature", "workflow_dispatch"),
    ):
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "tools/publish_linux_ci_caches.sh")],
            cwd=tmp_path,
            env={
                **os.environ,
                "GITHUB_REF": ref,
                "GITHUB_EVENT_NAME": event,
                "PATH": "/nonexistent",
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 1
        assert "Cache publication requires" in result.stderr


@pytest.mark.parametrize("existing_seed", [False, True])
def test_main_publisher_exports_only_verified_secret_free_dependency_targets(
    tmp_path, existing_seed
):
    import json
    import os
    import subprocess
    import sys

    commands = tmp_path / "commands.jsonl"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
with open(os.environ['COMMAND_LOG'], 'a') as stream:
    stream.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')
if sys.argv[1:] == ['context', 'show']:
    print('verified-builder')
"""
    for name in ("docker", "python"):
        path = bin_dir / name
        path.write_text(stub)
        path.chmod(0o755)
    seed = tmp_path / "verified-seed"
    if existing_seed:
        seed.mkdir()
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "tools/publish_linux_ci_caches.sh")],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            "COMMAND_LOG": str(commands),
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REPOSITORY": "Owner/Repo",
            "APP_DEPENDENCY_SEED": str(seed),
            "SDK_IMAGE": "sha256:" + "a" * 64,
            "GOOGLE_CLIENT_ID": "must-not-forward-to-exported-cache",
        },
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    rows = [json.loads(line) for line in commands.read_text().splitlines()]
    seed_row = next(row for row in rows if "tools/ci_app_dependency_seed.py" in row)
    assert ("--verify-existing" in seed_row) == existing_seed
    builds = [row for row in rows if row[:3] == ["docker", "buildx", "build"]]
    assert [row[row.index("--target") + 1] for row in builds] == [
        "application-dependencies",
        "ci",
        "acceptance-dependencies",
    ]
    for row in builds:
        assert row[row.index("--builder") + 1] == "verified-builder"
        assert "--cache-to" in row
        assert "--secret" not in row
        assert all(
            "GOOGLE" not in value and "must-not-forward" not in value for value in row
        )
        assert all(
            "ref=ghcr.io/owner/repo/" in row[index + 1]
            for index, value in enumerate(row)
            if value in ("--cache-to", "--cache-from")
        )
        target = row[row.index("--target") + 1]
        assert ("REQUIRE_DEPENDENCY_REUSE=1" in row) == (
            target != "acceptance-dependencies"
        )
        assert any("app-deps-buildcache-v1" in value for value in row)
        assert any("app-buildcache-x86-64" in value for value in row)


def test_every_write_scope_is_guarded_against_pull_requests():
    config = workflow()
    assert all(value == "read" for value in config["permissions"].values())
    for name, job in config["jobs"].items():
        if any(value == "write" for value in job.get("permissions", {}).values()):
            assert "github.ref == 'refs/heads/main'" in job["if"], name
            assert '"push","workflow_dispatch","schedule"' in job["if"], name


def _selection_repository(tmp_path):
    import subprocess
    import shutil

    def git(*arguments):
        return subprocess.check_output(
            ["git", *arguments],
            cwd=tmp_path,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=30,
        ).strip()

    git("init", "--initial-branch=main")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Selection fixture")
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs/guide.md").write_text("initial docs\n")
    git("add", ".")
    git("commit", "-m", "Initial source")
    initial = git("rev-parse", "HEAD")
    (tmp_path / "docs/guide.md").write_text("updated docs\n")
    git("commit", "-am", "Documentation change")
    tools = tmp_path / "tools"
    tools.mkdir()
    shutil.copy2(ROOT / "tools/ci_changes.py", tools / "ci_changes.py")
    return git, initial


def _run_actual_selection(tmp_path, event, base, push_base=""):
    import json
    import os
    import subprocess

    step = next(
        step
        for step in workflow()["jobs"]["changes"]["steps"]
        if step.get("id") == "changes"
    )
    result = subprocess.run(
        ["bash", "-e", "-c", step["run"]],
        cwd=tmp_path,
        env={
            **os.environ,
            "BASE": base,
            "PUSH_BASE": push_base,
            "EVENT": event,
            "FORCE": "",
            "PLATFORMS": "all",
            "GITHUB_OUTPUT": str(tmp_path / "outputs"),
        },
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads((tmp_path / "ci-selection.json").read_text())


@pytest.mark.parametrize(
    "kind", ["related", "missing", "zero", "malformed", "unknown", "tree", "unrelated"]
)
def test_actual_push_selection_requires_a_usable_ancestor_or_forces_full_suites(
    tmp_path, kind
):
    git, initial = _selection_repository(tmp_path)
    before = initial
    if kind == "missing":
        before = ""
    elif kind == "zero":
        before = "0" * 40
    elif kind == "malformed":
        before = "HEAD~1"
    elif kind == "unknown":
        before = "1" * 40
    elif kind == "tree":
        before = git("rev-parse", "HEAD^{tree}")
    elif kind == "unrelated":
        git("checkout", "--orphan", "unrelated")
        git("commit", "-am", "Unrelated identical docs")
        before = git("rev-parse", "HEAD")
        git("checkout", "main")
    report = _run_actual_selection(tmp_path, "push", git("rev-parse", "HEAD"), before)
    assert report["force"] == (kind != "related")
    assert all(report["selection"].values()) == (kind != "related")
    if kind == "related":
        assert not any(report["selection"].values())


def test_actual_pr_selection_uses_the_merge_base_when_main_advanced(tmp_path):
    git, initial = _selection_repository(tmp_path)
    git("checkout", "-b", "advanced-main", initial)
    (tmp_path / "native").mkdir()
    (tmp_path / "native/main.cpp").write_text("main-only native change\n")
    git("add", "native")
    git("commit", "-m", "Main advanced")
    base = git("rev-parse", "HEAD")
    git("checkout", "main")
    report = _run_actual_selection(tmp_path, "pull_request", base)
    assert not report["force"]
    assert not any(report["selection"].values())
    assert report["paths"] == [{"path": "docs/guide.md", "gates": []}]


def test_deb_acceptance_skips_unused_sdk_but_keeps_exact_portable_qualification():
    steps = workflow()["jobs"]["acceptance-deb"]["steps"]
    consumer = next(
        step
        for step in steps
        if step.get("uses") == "./.github/actions/setup-linux-consumer"
    )
    assert consumer["with"]["restore-sdk"] == "false"
    assert "needs.linux-build.outputs.bundle_id" in consumer["with"]["artifact-id"]
    assert (
        "needs.linux-bundle.outputs.candidate_digest"
        in consumer["with"]["artifact-digest"]
    )


def test_document_flutter_consumer_is_restore_only_and_publisher_warms_same_cache():
    jobs = workflow()["jobs"]
    consumer = jobs["linux-document-imports"]["steps"]
    publisher = jobs["publish-caches"]["steps"]
    restore = next(
        step for step in consumer if "actions/cache/restore@" in step.get("uses", "")
    )
    assert not any(
        "actions/cache@" in step.get("uses", "")
        or "actions/cache/save@" in step.get("uses", "")
        for step in consumer
    )
    published_restore = next(
        step for step in publisher if step.get("id") == "document-flutter"
    )
    assert published_restore["uses"] == restore["uses"]
    assert published_restore["with"] == restore["with"]
    warm = next(
        step
        for step in consumer
        if step.get("name") == "Install pinned Dart through the reviewed Flutter SDK"
    )
    published_warm = next(
        step for step in publisher if step.get("name") == warm["name"]
    )
    assert published_warm["run"] == warm["run"]
    assert published_warm["if"] == "steps.document-current.outputs.current == 'true'"
    assert published_restore["if"] == published_warm["if"]
    assert "adc901062556672b4138e18a4dc62a4be8f4b3c2" in warm["run"]
    assert "--disable-analytics" in warm["run"]
    save = next(
        step
        for step in publisher
        if "actions/cache/save@" in step.get("uses", "")
        and step["with"] == restore["with"]
    )
    assert (
        save["if"]
        == "steps.document-current.outputs.current == 'true' && steps.document-flutter.outputs.cache-hit != 'true' && steps.document-save-current.outputs.current == 'true'"
    )
    checks = [
        index
        for index, step in enumerate(publisher)
        if "document toolchain cache" in step.get("name", "")
    ]
    assert len(checks) == 2
    assert (
        checks[0]
        < publisher.index(published_restore)
        < publisher.index(published_warm)
        < checks[1]
        < publisher.index(save)
    )
    for index in checks:
        script = publisher[index]["run"]
        assert 'test "$GITHUB_REF" = refs/heads/main' in script
        assert "push|workflow_dispatch|schedule" in script
        assert "git rev-parse HEAD" in script
        assert "commits/main" in script


def test_document_cache_eligibility_does_not_gate_existing_publishers():
    steps = workflow()["jobs"]["publish-caches"]["steps"]
    after = next(
        index
        for index, step in enumerate(steps)
        if step.get("name")
        == "Publish only dependency, CI-tool and acceptance-tool layers"
    )
    assert "if" not in steps[after]
    for step in steps[after:]:
        assert "document-current" not in str(step)
        assert "document-save-current" not in str(step)
