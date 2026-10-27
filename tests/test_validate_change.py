"""The validation planner is conservative, explainable and honest about what ran."""

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

import pytest

from tests.source_export import ROOT, export_tree
from tools import boundary_inventory, check_local_validation, ci_changes, validate_change as vc

INVENTORY = boundary_inventory.load(ROOT)
FILES = boundary_inventory.repo_files(ROOT)
BOUNDARIES = {boundary["id"] for boundary in INVENTORY["boundaries"]}
GATES = set(INVENTORY["gates"])
COMMAND_GATES = {name for name, gate in INVENTORY["gates"].items() if gate["kind"] == "command"}


def plan_for(paths, *, host="linux", environ=None, boundaries=(), include_long=False, bundle=None, models=None):
    context = vc.Context(ROOT, environ or {}, host=host, bundle=bundle, models=models)
    return vc.build_plan(
        INVENTORY, vc.explicit_change_set(ROOT, paths), ROOT, context,
        requested_boundaries=boundaries, include_long=include_long, files=FILES,
    )


def selected(plan):
    return {item["id"] for item in plan["boundaries"]}, {item["id"] for item in plan["checks"]}


# ---------------------------------------------------------------- change sets


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("tools/build.sh", "tools/build.sh"),
        ("a/./b", "a/b"),
        ("", None),
        ("/etc/passwd", None),
        ("a/../../b", None),
        ("..", None),
        ("a\\b", None),
        ("a\0b", None),
        (".", None),
    ],
)
def test_path_normalization(raw, expected):
    assert vc.normalize_path(raw) == expected


@pytest.fixture
def repository_with_git(tmp_path, monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    repo = tmp_path / "repo"
    repo.mkdir()

    def git(*arguments):
        return subprocess.run(
            ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", *arguments],
            check=True, capture_output=True, timeout=60,
        ).stdout.decode().strip()

    git("init", "-q", "-b", "main")
    (repo / "a.txt").write_text("a\n")
    (repo / "b.txt").write_text("b\n")
    git("add", ".")
    git("commit", "-qm", "base")
    git("checkout", "-qb", "feature")
    (repo / "c.txt").write_text("c\n")
    (repo / "a.txt").write_text("a2\n")
    git("add", ".")
    git("commit", "-qm", "feature work")
    git("mv", "b.txt", "r.txt")
    git("commit", "-qm", "rename")
    git("checkout", "-q", "main")
    (repo / "d.txt").write_text("d\n")
    git("add", ".")
    git("commit", "-qm", "main advanced")
    git("checkout", "-q", "feature")
    return repo, git


@pytest.fixture
def repository(repository_with_git):
    return repository_with_git[0]


@pytest.fixture
def git(repository_with_git):
    return repository_with_git[1]


def test_git_change_set_classifies_committed_staged_unstaged_and_untracked(repository, git):
    (repository / "staged.txt").write_text("s\n")
    git("add", "staged.txt")
    (repository / "c.txt").write_text("edited\n")
    (repository / "untracked.txt").write_text("u\n")
    change = vc.collect_git(repository, "main")
    by_path = {entry["path"]: entry["classes"] for entry in change["entries"]}
    # merge-base semantics: main's later commit (d.txt) is not part of the change.
    assert "d.txt" not in by_path
    assert by_path["a.txt"] == ["committed"] and by_path["c.txt"] == ["committed", "unstaged"]
    # A rename is a delete plus an add so both locations select consumers.
    assert {"b.txt", "r.txt"} <= set(by_path)
    assert by_path["staged.txt"] == ["staged"] and by_path["untracked.txt"] == ["untracked"]
    assert change["counts"] == {"committed": 4, "staged": 1, "unstaged": 1, "untracked": 1}
    assert change["dirty"] and change["dirty_paths"] == ["c.txt", "staged.txt", "untracked.txt"]
    assert change["mode"] == "git" and change["merge_base"] and change["revision"]
    assert change["paths"] == sorted(by_path)


def test_include_selects_classes_and_no_base_means_no_committed_class(repository):
    (repository / "untracked.txt").write_text("u\n")
    assert vc.collect_git(repository, None)["paths"] == ["untracked.txt"]
    only = vc.collect_git(repository, "main", include=["committed"])
    assert only["paths"] == ["a.txt", "b.txt", "c.txt", "r.txt"] and not only["dirty"]
    assert vc.collect_git(repository, "main", include=["untracked"])["paths"] == ["untracked.txt"]
    assert vc.collect_git(repository, "main", include=["staged", "unstaged"])["paths"] == []


def test_identity_is_bound_to_content_and_revision(repository):
    first = vc.collect_git(repository, "main")["identity_sha256"]
    assert vc.collect_git(repository, "main")["identity_sha256"] == first
    (repository / "untracked.txt").write_text("one\n")
    second = vc.collect_git(repository, "main")["identity_sha256"]
    (repository / "untracked.txt").write_text("two\n")
    third = vc.collect_git(repository, "main")["identity_sha256"]
    assert len({first, second, third}) == 3
    (repository / "untracked.txt").unlink()
    assert vc.collect_git(repository, "main")["identity_sha256"] == first


def test_git_failures_are_actionable(repository, tmp_path, monkeypatch):
    with pytest.raises(vc.PlanError, match="merge-base"):
        vc.collect_git(repository, "no-such-ref")
    with pytest.raises(vc.PlanError, match="rev-parse"):
        vc.collect_git(tmp_path, "main")
    monkeypatch.setenv("PATH", "")
    with pytest.raises(vc.PlanError, match="--files"):
        vc.collect_git(repository, "main")


def test_explicit_change_set_never_touches_git_and_keeps_invalid_paths(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", "")
    (tmp_path / "x.txt").write_text("x")
    change = vc.explicit_change_set(tmp_path, ["./x.txt", "x.txt", "../escape", "missing.txt"], revision="fixture-rev", base_revision="fixture-base")
    assert change["mode"] == "explicit" and change["revision"] == "fixture-rev" and change["base"] == "fixture-base"
    assert change["paths"] == ["../escape", "missing.txt", "x.txt"] and change["revision_declared"] is True
    digests = {entry["path"]: entry["sha256"] for entry in change["entries"]}
    assert digests["x.txt"] and digests["missing.txt"] is None and digests["../escape"] is None
    assert not change["dirty"]
    assert vc.explicit_change_set(tmp_path, [])["revision_declared"] is False


def test_empty_change_set_for_boundary_requests():
    change = vc.empty_change_set("boundary-request")
    assert change["paths"] == [] and change["mode"] == "boundary-request"


# --------------------------------------------------------- representative edits


def test_shared_test_support_selects_every_dart_consumer_and_reports_importers():
    plan = plan_for(["packages/foresight_test_support/lib/service_fault_proxy.dart"])
    boundaries, checks = selected(plan)
    assert {"desktop-service", "mcp-service", "frontend-worker-isolate", "service-helper", "service-sqlite-read-worker", "launcher-service-handoff"} <= boundaries
    assert {"core-stage", "desktop-stage", "service-stage"} <= checks
    closure = plan["closure"][0]
    assert "packages/foresight_core/test/service_closing_protocol_test.dart" in closure["consumers"]
    assert closure["consumer_count"] >= 5 and "desktop-service" in closure["boundaries"]
    assert not plan["conservative"]


def test_support_closure_follows_transitive_imports_and_python_twin(tmp_path):
    def write(path, text=""):
        target = tmp_path / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    write("packages/foresight_test_support/lib/a.dart", "import 'b.dart';\nexport 'dart:async';\nimport 'package:other/x.dart';\n")
    write("packages/foresight_test_support/lib/b.dart")
    write("packages/foresight_test_support/lib/gated_helper.py")
    write("packages/foresight_core/test/x_test.dart", "import 'package:foresight_test_support/a.dart';\n")
    write("packages/foresight_core/test/y_test.dart", "import '../../foresight_test_support/lib/b.dart';\n")
    write("packages/foresight_core/test/unrelated_test.dart", "import 'package:test/test.dart';\n")
    write("tests/service/test_service_process.py", "GATED = 'gated_helper.py'\n")
    write("tests/service/gated_helper.py")
    files = boundary_inventory.repo_files(tmp_path)
    assert vc.support_consumers(tmp_path, ["packages/foresight_test_support/lib/b.dart"], files) == [
        "packages/foresight_core/test/x_test.dart",
        "packages/foresight_core/test/y_test.dart",
        "packages/foresight_test_support/lib/a.dart",
    ]
    assert vc.support_consumers(tmp_path, ["tests/service/gated_helper.py"], files) == ["tests/service/test_service_process.py"]
    assert "packages/foresight_test_support/lib/gated_helper.py" not in vc.support_consumers(tmp_path, ["packages/foresight_test_support/lib/gated_helper.py"], files)
    everything = vc.support_consumers(tmp_path, ["packages/foresight_test_support/pubspec.yaml"], files)
    assert "packages/foresight_core/test/unrelated_test.dart" in everything and len(everything) == len(files) - 1 or everything
    assert "packages/foresight_core/test/unrelated_test.dart" in everything


def test_native_abi_change_reaches_bindings_workers_and_packaged_products():
    plan = plan_for(["native/foresight_native.h"])
    boundaries, checks = selected(plan)
    assert {"dart-native-ffi", "service-sqlite-read-worker", "desktop-service", "mcp-service", "build-installed-product"} <= boundaries
    assert {"native-stage", "core-stage", "desktop-stage", "service-stage", "platform-contracts", "native-sanitizers"} <= checks


def test_schema_and_generated_binding_changes_select_wire_consumers():
    for path in ("proto/linux/helper_control.proto", "packages/foresight_core/lib/src/generated/helper_control.pb.dart"):
        boundaries, checks = selected(plan_for([path]))
        assert {"schema-bindings", "service-helper", "desktop-service", "mcp-service", "frontend-worker-isolate"} <= boundaries
        assert {"bindings-check", "core-stage", "desktop-stage", "service-stage"} <= checks


def test_runtime_configuration_change_reaches_model_and_installed_consumers():
    boundaries, checks = selected(plan_for(["native/model_registry.json"]))
    assert {"model-runtime-acceptance", "service-helper", "build-installed-product", "harness-os"} <= boundaries
    assert {"integration-models", "native-stage", "service-stage"} <= checks


def test_package_layout_change_reaches_installers_and_acceptance():
    boundaries, checks = selected(plan_for(["packaging/ci/test-release-package.sh"]))
    assert {"build-installed-product", "document-import-sandbox", "launcher-service-handoff"} <= boundaries
    assert {"hosted-packaging", "installed-acceptance", "dmg-contracts", "document-sandbox"} <= checks


def test_toolchain_and_orchestration_inputs_select_everything_downstream():
    for path in ("tools/pins.json", "apps/desktop/pubspec.lock", "requirements-dev.lock", "tools/build.sh", ".github/workflows/macos.yml", "tools/integration_gates.py"):
        plan = plan_for([path])
        boundaries, checks = selected(plan)
        assert boundaries == BOUNDARIES, path
        assert {"shared-guards", "python-coverage", "core-stage", "service-stage", "hosted-packaging"} <= checks, path


def test_unknown_and_invalid_inputs_select_every_boundary_and_gate_conservatively():
    for path in ("brand/new/area/file.xyz", "../outside", "/absolute", "tools/some_new_tool.py"):
        plan = plan_for([path])
        boundaries, checks = selected(plan)
        assert boundaries == BOUNDARIES and checks == GATES, path
        assert plan["conservative"] and path in plan["conservative_reasons"]
    assert plan_for(["brand/new/file"])["paths"][0]["matches"][0]["kind"] == "unknown"
    assert plan_for(["../outside"])["paths"][0]["matches"][0]["rule"] == "invalid-path"


def test_known_benign_inputs_stay_small_but_keep_the_baseline():
    docs = plan_for(["docs/testing.md", "README.md"])
    assert selected(docs) == (set(), {"shared-guards"}) and not docs["conservative"]
    dart_test = plan_for(["packages/foresight_core/test/audio_store_test.dart"])
    assert not dart_test["conservative"] and "core-stage" in selected(dart_test)[1]
    desktop_test = selected(plan_for(["apps/desktop/test/account_button_test.dart"]))[1]
    integration = selected(plan_for(["apps/desktop/integration_test/first_run_models_test.dart"]))[1]
    assert "desktop-stage" in desktop_test and {"desktop-stage", "service-stage"} <= integration
    root_test = plan_for(["tests/test_ci_stats.py"])
    assert not root_test["conservative"] and {"shared-guards", "python-coverage"} <= selected(root_test)[1]
    host_contract = plan_for(["tests/test_build_stages.py"])
    assert "platform-contracts" in selected(host_contract)[1]
    assert selected(plan_for([]))[1] == {"shared-guards"}


def test_direct_triggers_and_cited_tests_select_their_boundary():
    plan = plan_for(["packages/foresight_core/lib/src/helper_transport.dart"])
    assert "service-helper" in selected(plan)[0] and not plan["conservative"]
    cited = plan_for(["packages/foresight_core/test/sqlite_store_reader_test.dart"])
    assert "service-sqlite-read-worker" in selected(cited)[0]
    match = next(item for item in cited["paths"][0]["matches"] if item["kind"] == "direct-test")
    assert "cited test" in match["reason"]


def test_planning_unions_ci_selection_and_never_narrows_it():
    paths = ["tools/build.sh", "packaging/notices/x.md", "docs/testing.md", "tests/test_dmg_contract.py", "apps/desktop/macos/Runner.swift"]
    for path in paths:
        plan = plan_for([path])
        ci = plan["ci_selection"]
        authoritative = ci_changes.select_gates([path])
        assert all(ci["effective"][gate] for gate, value in authoritative.items() if value), path
        assert ci["authoritative"] == authoritative and ci["candidate_error"] is None
        for gate, value in ci["effective"].items():
            if value:
                assert set(INVENTORY["ci_gate_map"][gate]["gates"]) <= selected(plan)[1]
    assert "dmg-contracts" in selected(plan_for(["tests/test_dmg_contract.py"]))[1]


def test_candidate_selector_failure_broadens_instead_of_aborting(monkeypatch):
    def broken(*_, **__):
        raise RuntimeError("selector drift")

    monkeypatch.setattr(vc.ci_selection, "select", broken)
    plan = plan_for(["docs/testing.md"])
    assert plan["ci_selection"]["candidate_error"] == "RuntimeError: selector drift"
    assert all(plan["ci_selection"]["effective"].values()) and plan["conservative"]
    assert any("ci_selection error" in reason for reason in plan["conservative_reasons"])


# --------------------------------------------------- mapping, reuse, availability


def test_every_boundary_maps_to_a_real_gate_or_an_explicit_requirement():
    for name in sorted(BOUNDARIES):
        plan = plan_for([], boundaries=[name])
        boundary = next(item for item in plan["boundaries"] if item["id"] == name)
        assert boundary["mapping"] in ("executable", "ci-only", "manual")
        assert boundary["owner_responsibility"] and boundary["unverified"] is not None
        owning = next(item for item in plan["checks"] if item["id"] == boundary["owning_gate"])
        if boundary["mapping"] == "executable":
            script = [token for token in owning["entrypoint"]["argv"] if token.endswith((".py", ".sh"))]
            assert script and all((ROOT / token).is_file() for token in script if token.startswith("tools/"))
        else:
            assert boundary["requirement"] and owning["requirement"]
        assert any(entry["source"] == "request" for entry in boundary["why"])


def test_unknown_boundary_request_lists_the_choices():
    with pytest.raises(vc.PlanError, match="service-helper"):
        plan_for([], boundaries=["nope"])


def test_platform_and_prerequisite_unavailability_is_explained(monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: None)
    plan = plan_for(["packaging/ci/test-release-package.sh"], host="macos")
    checks = {check["id"]: check for check in plan["checks"]}
    assert checks["document-sandbox"]["availability"] == "unavailable"
    assert "requires linux; this host is macos" in checks["document-sandbox"]["unavailable_reasons"]
    assert checks["dmg-contracts"]["availability"] == "unavailable"
    assert any("hdiutil is not on PATH" in reason for reason in checks["dmg-contracts"]["unavailable_reasons"])
    assert checks["hosted-packaging"]["availability"] == "ci-only" and checks["installed-acceptance"]["availability"] == "manual"
    assert checks["installed-acceptance"]["requirement"]
    linux = plan_for(["packaging/ci/test-release-package.sh"], host="linux")
    assert any("requires macos; this host is linux" in reason for check in linux["checks"] if check["id"] == "dmg-contracts" for reason in check["unavailable_reasons"])


def test_python_version_requirement(monkeypatch):
    monkeypatch.setattr(vc.sys, "version_info", (3, 11, 0, "final", 0))
    check = next(item for item in plan_for([])["checks"] if item["id"] == "shared-guards")
    assert check["availability"] == "unavailable" and any("needs 3.13" in reason for reason in check["unavailable_reasons"])


def test_prerequisites_produced_earlier_in_the_run_are_distinguished_from_present_files(tmp_path, monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    build = tmp_path / "build"
    environ = {"FORESIGHT_BUILD_DIR": str(build)}
    plan = plan_for(["native/foresight_native.h"], environ=environ)
    core = next(item for item in plan["checks"] if item["id"] == "core-stage")
    produced = [item for item in core["prerequisites"] if item.get("satisfied_by")]
    assert produced and produced[0]["satisfied_by"] == "native-stage" and core["availability"] == "runnable"
    native = next(item for item in plan["checks"] if item["id"] == "native-stage")
    assert native["reuse"][0]["present"] is False and "absent" in native["reuse"][0]["presented_as"]

    (build / "native").mkdir(parents=True)
    library = build / "native" / "libforesight_native.so"
    library.write_bytes(b"native bytes")
    present = plan_for(["native/foresight_native.h"], environ=environ)
    core = next(item for item in present["checks"] if item["id"] == "core-stage")
    assert all(not item.get("satisfied_by") for item in core["prerequisites"][1:2])
    reuse = core["reuse"][0]
    assert reuse["present"] and "reused existing output" in reuse["presented_as"] and "not freshly built" in reuse["presented_as"]
    import hashlib

    assert reuse["sha256"][str(library)] == hashlib.sha256(b"native bytes").hexdigest()
    assert "never presented as a fresh build" in present["reuse_policy"]


def test_missing_prerequisite_without_a_producer_is_unavailable(tmp_path, monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    plan = plan_for([], boundaries=["model-runtime-acceptance"], bundle=tmp_path / "no-bundle", models=tmp_path / "no-models")
    models = next(item for item in plan["checks"] if item["id"] == "integration-models")
    assert models["availability"] == "unavailable" and any("no-bundle is missing" in reason for reason in models["unavailable_reasons"])
    (tmp_path / "bundle").mkdir()
    (tmp_path / "models").mkdir()
    ready = plan_for([], boundaries=["model-runtime-acceptance"], bundle=tmp_path / "bundle", models=tmp_path / "models")
    models = next(item for item in ready["checks"] if item["id"] == "integration-models")
    assert models["availability"] == "runnable" and str(tmp_path / "bundle") in models["entrypoint"]["argv"]
    assert models["deferred"] and models["long"]


def test_context_expands_placeholders_per_platform_and_environment(tmp_path):
    mac = vc.Context(tmp_path, {}, host="macos")
    assert mac.expand("{build_dir}/native/{native_library}") == f"{tmp_path}/build/native/libforesight_native.dylib"
    assert mac.expand("{output}") == "<evidence-dir>" and mac.path("x/y") == tmp_path / "x" / "y"
    linux = vc.Context(tmp_path, {"FORESIGHT_BUILD_DIR": "out"}, host="linux", output=tmp_path / "ev")
    assert linux.expand("{build_dir}/{native_library}") == f"{tmp_path}/out/libforesight_native.so"
    assert linux.expand("{output}") == str(tmp_path / "ev")
    absolute = vc.Context(tmp_path, {"FORESIGHT_BUILD_DIR": "/abs/build"}, host="linux")
    assert absolute.path("{build_dir}") == Path("/abs/build")


def test_long_checks_are_deferred_in_the_plan_but_never_hidden():
    plan = plan_for(["native/foresight_native.h"])
    native = next(item for item in plan["checks"] if item["id"] == "native-stage")
    assert native["long"] and native.get("deferred") if native["availability"] == "runnable" else True
    assert plan_for(["native/foresight_native.h"], include_long=True)["include_long"] is True


def test_subsumption_when_the_full_python_gate_will_run(monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    plan = plan_for(["tools/build.sh"], include_long=True)
    guards = next(item for item in plan["checks"] if item["id"] == "shared-guards")
    assert guards["subsumed_by"] == "python-coverage"
    assert "subsumed_by" not in next(item for item in plan_for(["tools/build.sh"])["checks"] if item["id"] == "shared-guards")


# ------------------------------------------------------------------ execution


def fake_runner(statuses, calls=None):
    def run(argv, *, cwd, env, log_path, timeout, stream=None):
        key = next((name for name in statuses if name in " ".join(argv)), None)
        if calls is not None:
            calls.append((list(argv), dict(env), timeout))
        log_path.write_text("raw log\n")
        code = statuses.get(key, 0)
        return {"returncode": code, "timed_out": code == "timeout", "seconds": 0.5, "log": str(log_path)}

    return run


@pytest.fixture
def private_output(tmp_path, monkeypatch):
    monkeypatch.setattr(check_local_validation, "TEMP_PARENT", tmp_path.resolve())
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    return tmp_path / "evidence"


def test_a_documentation_only_run_can_be_a_full_validation_of_its_own_scope(private_output, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}, calls))
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output), "--skip-inventory-check"], root=ROOT, environ={"GITHUB_TOKEN": "secret"})
    assert code == 0 and len(calls) == 1 and calls[0][0][-1] == "tools.check_local_validation"
    summary = json.loads((private_output / "evidence.json").read_text())
    assert summary["status"] == "full-validation-passed" and summary["unexecuted_platforms"] == []
    assert summary["source"]["mode"] == "explicit" and summary["tools"]["python"]
    assert "secret" not in (private_output / "evidence.json").read_text()
    assert (private_output / "plan.json").is_file() and (private_output / "logs/shared-guards.log").is_file()
    assert "Result: full-validation-passed" in capsys.readouterr().out


def test_an_incomplete_run_is_never_a_successful_full_validation(private_output, monkeypatch, capsys):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    arguments = ["--files", "native/foresight_native.h", "--output", str(private_output), "--skip-inventory-check"]
    code = vc.main(arguments, root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 3 and summary["status"] == "partial" and not summary["full_validation"]
    statuses = {check["id"]: check["status"] for check in summary["checks"]}
    assert statuses["native-stage"] == "not-run" and statuses["hosted-packaging"] == "ci-only"
    assert statuses["installed-acceptance"] == "manual" and statuses["platform-contracts"] == "passed"
    assert summary["unexecuted_platforms"]
    assert any("unexecuted platforms" in reason for reason in summary["not_full_validation_reasons"])
    capsys.readouterr()


def test_allow_partial_changes_only_the_exit_status(tmp_path, private_output, monkeypatch):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    arguments = ["--files", "native/foresight_native.h", "--skip-inventory-check", "--allow-partial"]
    assert vc.main([*arguments, "--output", str(private_output)], root=ROOT, environ={}) == 0
    assert json.loads((private_output / "evidence.json").read_text())["status"] == "partial"


def test_a_failed_check_fails_the_run_and_blocks_its_dependents(private_output, monkeypatch):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({"platform_python_tests": 1, "tools/build.sh": 5}))
    arguments = ["--files", "native/foresight_native.h", "--output", str(private_output), "--skip-inventory-check", "--include-long"]
    code = vc.main(arguments, root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 1 and summary["status"] == "failed"
    by_id = {check["id"]: check for check in summary["checks"]}
    assert by_id["platform-contracts"]["status"] == "failed" and by_id["platform-contracts"]["reason"] == "exit status 1"
    assert by_id["native-stage"]["status"] == "failed"
    assert by_id["core-stage"]["status"] == "not-run" and "native-stage did not pass" in by_id["core-stage"]["reason"]
    assert by_id["shared-guards"]["status"] == "subsumed" or by_id["shared-guards"]["status"] == "passed"


def test_subsumed_guards_follow_the_full_python_gate(private_output, monkeypatch):
    plan = plan_for(["tools/build.sh"], include_long=True)
    assert next(item for item in plan["checks"] if item["id"] == "shared-guards")["subsumed_by"] == "python-coverage"
    (private_output).mkdir(mode=0o700)
    results, _ = vc.execute(plan, private_output, {}, include_long=True, runner=fake_runner({"--full-python": 1}))
    by_id = {item["id"]: item for item in results}
    assert by_id["python-coverage"]["status"] == "failed"
    assert by_id["shared-guards"]["status"] == "failed" and "subsuming check python-coverage" in by_id["shared-guards"]["reason"]

    ok_output = private_output.parent / "ok"
    ok_output.mkdir(mode=0o700)
    results, _ = vc.execute(plan, ok_output, {}, include_long=True, runner=fake_runner({}))
    assert {item["id"]: item["status"] for item in results}["shared-guards"] == "subsumed"


def test_timeout_is_a_failure_with_its_reason(private_output, monkeypatch):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({"check_local_validation": "timeout"}))
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output), "--skip-inventory-check"], root=ROOT, environ={})
    check = json.loads((private_output / "evidence.json").read_text())["checks"][0]
    assert code == 1 and check["status"] == "failed" and check["reason"] == "timed out"


def test_unavailable_prerequisites_are_recorded_not_skipped_silently(private_output, monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: None)
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output), "--skip-inventory-check"], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    check = summary["checks"][0]
    assert code == 3 and check["status"] == "unavailable" and check["unavailable"]
    assert summary["full_validation"] is False


def test_child_processes_get_private_temp_roots_unless_already_compliant(tmp_path):
    output = tmp_path / "out"
    output.mkdir(mode=0o700)
    env, policy = vc.child_environment({"PATH": "/bin"}, output)
    assert env["TMPDIR"] == str(output / "tmp") and env["FORESIGHT_TEST_TEMP_ROOT"] == str(output / "t")
    assert policy["source"].startswith("created") and (output / "tmp").stat().st_mode & 0o077 == 0
    assert env["FORESIGHT_PYTHON"] == sys.executable
    root = Path(os.path.realpath(tmp_path)) / "s"
    root.mkdir(mode=0o700)
    original = vc.validation_evidence.SHORT_TEMP_LIMIT
    vc.validation_evidence.SHORT_TEMP_LIMIT = 500
    try:
        env, policy = vc.child_environment({"TMPDIR": str(root), "FORESIGHT_TEST_TEMP_ROOT": str(root)}, output)
    finally:
        vc.validation_evidence.SHORT_TEMP_LIMIT = original
    assert env["TMPDIR"] == str(root) and policy["source"] == "inherited"


def test_real_streaming_tees_output_and_reports_the_exit_status(tmp_path):
    log = tmp_path / "log"
    stream = io.StringIO()
    script = "import sys;print('out');print('err', file=sys.stderr);sys.exit(7)"
    result = vc.run_streaming([sys.executable, "-c", script], cwd=tmp_path, env=os.environ, log_path=log, timeout=30, stream=stream)
    assert result["returncode"] == 7 and not result["timed_out"]
    # The child's stderr and stdout buffering is independent; the two sinks must agree.
    assert sorted(log.read_text().splitlines()) == ["err", "out"] and stream.getvalue() == log.read_text()


def test_streaming_defaults_to_standard_output(tmp_path, capsys):
    log = tmp_path / "log"
    result = vc.run_streaming([sys.executable, "-c", "print('x')"], cwd=tmp_path, env=os.environ, log_path=log, timeout=30)
    assert result["returncode"] == 0 and log.read_text() == "x\n" and capsys.readouterr().out == "x\n"


def test_a_hung_entrypoint_and_its_children_are_killed_at_the_deadline(tmp_path, monkeypatch):
    monkeypatch.setattr(vc, "KILL_GRACE_SECONDS", 1)
    marker = tmp_path / "child-pid"
    script = (
        "import os,subprocess,sys,time;"
        f"c=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);open({str(marker)!r},'w').write(str(c.pid));"
        "print('started',flush=True);time.sleep(60)"
    )
    started = time.monotonic()
    result = vc.run_streaming([sys.executable, "-c", script], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=2, stream=io.StringIO())
    assert result["timed_out"] and result["returncode"] != 0 and time.monotonic() - started < 30
    assert (tmp_path / "log").read_text() == "started\n"
    child = int(marker.read_text())
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    else:
        pytest.fail("the entrypoint's child outlived the deadline")


def test_signalling_a_finished_group_is_harmless(tmp_path):
    process = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
    process.wait(timeout=30)
    vc._signal_group(process, 15)


# ----------------------------------------------------------------- CLI surface


def cli(arguments, capsys, root=ROOT):
    code = vc.main(["--skip-inventory-check", *arguments], root=root, environ={})
    return code, capsys.readouterr()


def test_plan_json_has_the_documented_shape_and_runs_nothing(capsys):
    code, captured = cli(["--files", "native/foresight_native.h", "--plan", "--json"], capsys)
    data = json.loads(captured.out)
    assert code == 0 and data["evidence"]["status"] == "plan-only" and data["evidence"]["full_validation"] is False
    plan = data["plan"]
    assert {"change_set", "paths", "closure", "ci_selection", "boundaries", "checks", "reuse_policy", "required_platforms"} <= plan.keys()
    assert plan["kind"] == vc.PLAN_KIND and plan["schema"] == vc.PLAN_SCHEMA
    assert all(check["why"] for check in plan["checks"]) and all("entries" not in plan["change_set"] for _ in [0])


def test_human_plan_explains_selection_prerequisites_reuse_and_unverified_items(capsys):
    code, captured = cli(["--files", "native/foresight_native.h", "--plan"], capsys)
    assert code == 0
    for text in ("Boundaries", "why:", "unverified:", "prerequisite", "run:", "deferred:", "never presented as a fresh build", "CI selection"):
        assert text in captured.out, text
    code, captured = cli(["--files", "brand/new/file", "--plan"], capsys)
    assert "Conservative selection (unknown inputs)" in captured.out


def test_boundary_request_without_a_change_set(capsys):
    code, captured = cli(["--boundary", "service-helper", "--plan", "--json"], capsys)
    plan = json.loads(captured.out)["plan"]
    assert code == 0 and plan["change_set"]["mode"] == "boundary-request" and plan["change_set"]["paths"] == []
    assert [boundary["id"] for boundary in plan["boundaries"]] == ["service-helper"]
    assert {"service-stage", "core-stage", "native-stage", "shared-guards"} <= {check["id"] for check in plan["checks"]}


def test_list_boundaries(capsys):
    code, captured = cli(["--list-boundaries"], capsys)
    assert code == 0 and "service-helper\tservice-stage" in captured.out


def test_invalid_input_exits_two_with_a_message(capsys):
    code, captured = cli(["--boundary", "nope", "--plan"], capsys)
    assert code == 2 and "Unknown boundary" in captured.err
    code, captured = cli(["--base", "no-such-ref-anywhere", "--plan"], capsys)
    assert code == 2 and "validate_change:" in captured.err


def test_inventory_drift_fails_closed_before_planning(tmp_path, capsys, monkeypatch):
    def broken(root):
        raise ValueError("Boundary inventory drift: x")

    monkeypatch.setattr(vc.boundary_inventory, "verify", broken)
    code = vc.main(["--files", "docs/testing.md", "--plan"], root=ROOT, environ={})
    assert code == 2 and "inventory drift" in capsys.readouterr().err


def test_the_inventory_is_verified_by_default(capsys):
    code = vc.main(["--files", "docs/testing.md", "--plan"], root=ROOT, environ={})
    assert code == 0 and "Checks" in capsys.readouterr().out


def test_files_from_file_and_stdin(tmp_path, capsys, monkeypatch):
    listing = tmp_path / "files.txt"
    listing.write_text("docs/testing.md\nnative/foresight_native.h\n")
    code, captured = cli(["--files-from", str(listing), "--plan", "--json"], capsys)
    assert json.loads(captured.out)["plan"]["change_set"]["paths"] == ["docs/testing.md", "native/foresight_native.h"]
    listing.write_text("docs/testing.md\0tools/build.sh\0")
    code, captured = cli(["--files-from", str(listing), "--plan", "--json"], capsys)
    assert json.loads(captured.out)["plan"]["change_set"]["paths"] == ["docs/testing.md", "tools/build.sh"]
    monkeypatch.setattr(vc.sys, "stdin", io.StringIO("docs/testing.md\n"))
    code, captured = cli(["--files-from", "-", "--plan", "--json"], capsys)
    assert json.loads(captured.out)["plan"]["change_set"]["paths"] == ["docs/testing.md"]


def test_argument_validation(capsys):
    for arguments in (
        ["--files", "a", "--base", "main"],
        ["--files", "a", "--files-from", "x"],
        ["--include", "committed,bogus"],
        ["--include", ","],
    ):
        with pytest.raises(SystemExit):
            vc.parse_arguments(arguments)
    capsys.readouterr()


# ------------------------------------------------------------ no-.git exports


@pytest.fixture(scope="module")
def export(tmp_path_factory):
    return export_tree(tmp_path_factory.mktemp("planner-export") / "tree")


def export_plan(export, *files, extra=(), environ=None):
    env = {"PATH": "/nonexistent", "HOME": str(export)}
    env.update(environ or {})
    completed = subprocess.run(
        [sys.executable, "-m", "tools.validate_change", "--plan", "--json", "--revision", "fixture-rev", "--base-revision", "fixture-base", *extra, "--files", *files],
        cwd=export, env=env, capture_output=True, text=True, timeout=120, check=False,
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


def test_complete_export_without_git_plans_from_explicit_files_alone(export):
    data = export_plan(export, "packages/foresight_test_support/lib/service_fault_proxy.dart", "native/foresight_native.h")
    plan = data["plan"]
    assert plan["change_set"]["mode"] == "explicit" and plan["change_set"]["revision"] == "fixture-rev"
    assert plan["change_set"]["base"] == "fixture-base"
    assert "desktop-service" in {boundary["id"] for boundary in plan["boundaries"]}
    assert data["evidence"]["source"]["revision"] == "fixture-rev"
    assert not (export / ".git").exists()


def test_export_selection_ignores_inherited_ci_refs_and_records_them(export):
    results = {}
    for name, environ in {
        "unset": {},
        "pull": {"GITHUB_REF": "refs/pull/7/merge", "GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "fixture/repo"},
        "main": {"GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "push", "GITHUB_TOKEN": "must-not-be-recorded"},
    }.items():
        data = export_plan(export, "tools/build.sh", environ=environ)
        results[name] = data
        assert "must-not-be-recorded" not in json.dumps(data)
    identities = {data["plan"]["change_set"]["identity_sha256"] for data in results.values()}
    selections = {json.dumps([check["id"] for check in data["plan"]["checks"]]) for data in results.values()}
    assert len(identities) == 1 and len(selections) == 1
    assert results["unset"]["evidence"]["environment"].get("GITHUB_REF") is None
    assert results["pull"]["evidence"]["environment"]["GITHUB_REF"] == "refs/pull/7/merge"
    assert results["main"]["evidence"]["environment"]["GITHUB_EVENT_NAME"] == "push"


def test_export_without_git_refuses_git_mode_with_the_explicit_alternative(export):
    completed = subprocess.run(
        [sys.executable, "-m", "tools.validate_change", "--base", "origin/main", "--plan"],
        cwd=export, env={"PATH": "/nonexistent"}, capture_output=True, text=True, timeout=120, check=False,
    )
    assert completed.returncode == 2 and "--files" in completed.stderr


def test_export_inventory_is_verified_without_git(export):
    completed = subprocess.run(
        [sys.executable, "-m", "tools.boundary_inventory"], cwd=export, env={"PATH": "/nonexistent"},
        capture_output=True, text=True, timeout=120, check=False,
    )
    assert completed.returncode == 0, completed.stderr


def test_concurrent_streaming_runs_do_not_share_logs(tmp_path):
    results = []

    def run(index):
        results.append(vc.run_streaming([sys.executable, "-c", f"print({index})"], cwd=tmp_path, env=os.environ, log_path=tmp_path / f"{index}.log", timeout=30, stream=io.StringIO()))

    threads = [threading.Thread(target=run, args=(index,)) for index in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=60)
    assert [(tmp_path / f"{index}.log").read_text() for index in range(4)] == [f"{index}\n" for index in range(4)]
