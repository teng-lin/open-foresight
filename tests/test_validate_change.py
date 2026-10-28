"""The validation planner is conservative, explainable and honest about what ran."""

import io
import json
import os
from pathlib import Path
import signal
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


def plan_for(paths, *, host="linux", environ=None, boundaries=(), include_long=False, bundle=None, models=None, inventory=None):
    context = vc.Context(ROOT, environ or {}, host=host, bundle=bundle, models=models)
    return vc.build_plan(
        inventory or INVENTORY, vc.explicit_change_set(ROOT, paths), ROOT, context,
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
    # Excluding a class narrows the paths but never hides a dirty tree.
    assert only["paths"] == ["a.txt", "b.txt", "c.txt", "r.txt"]
    assert only["dirty"] is True and only["dirty_paths"] == ["untracked.txt"]
    assert only["excluded_classes"] == ["staged", "unstaged", "untracked"]
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
    # The rule's static list plus nothing else: every closure-derived owner is already in it.
    assert boundaries == {
        "dart-native-ffi", "desktop-service", "frontend-worker-isolate", "harness-os",
        "launcher-service-handoff", "mcp-service", "service-helper", "service-sqlite-read-worker",
    }
    assert {"core-stage", "desktop-stage", "service-stage"} <= checks
    closure = plan["closure"][0]
    assert "packages/foresight_core/test/service_closing_protocol_test.dart" in closure["consumers"]
    assert closure["boundaries"] == ["desktop-service", "launcher-service-handoff", "mcp-service"]
    assert closure["consumer_count"] == len(vc.support_consumers(ROOT, ["packages/foresight_test_support/lib/service_fault_proxy.dart"], FILES))
    assert not plan["conservative"]


def test_closure_alone_selects_a_boundary_the_rule_does_not_list():
    # model-runtime-acceptance is absent from the rule's static list; only the import graph reaches it.
    rule = next(item for item in INVENTORY["impact_rules"] if item["id"] == "shared-test-support")
    assert "model-runtime-acceptance" not in rule["boundaries"]
    plan = plan_for(["packages/foresight_test_support/lib/test_paths.dart"])
    boundary = next(item for item in plan["boundaries"] if item["id"] == "model-runtime-acceptance")
    assert [entry["kind"] for entry in boundary["why"]] == ["import-graph"]
    assert "model-runtime-acceptance" in plan["closure"][0]["boundaries"]
    assert selected(plan)[0] == BOUNDARIES - {"build-installed-product", "document-import-sandbox", "schema-bindings"}


def test_closure_owner_outside_an_empty_rule_list_is_still_selected():
    import copy

    inventory = copy.deepcopy(INVENTORY)
    next(item for item in inventory["impact_rules"] if item["id"] == "shared-test-support")["boundaries"] = []
    plan = plan_for(["packages/foresight_test_support/lib/service_fault_proxy.dart"], inventory=inventory)
    assert selected(plan)[0] == {"desktop-service", "launcher-service-handoff", "mcp-service"}
    assert all(entry["kind"] == "import-graph" for item in plan["boundaries"] for entry in item["why"])


def test_dart_fixture_edits_select_the_python_tests_that_read_them_and_their_twins():
    consumers = vc.support_consumers(ROOT, ["packages/foresight_test_support/lib/gated_helper.dart"], FILES)
    assert {
        "packages/foresight_core/test/service_gate_test.dart",
        "packages/foresight_core/test/service_closing_protocol_test.dart",
        "tests/service/gated_helper.py",
        "tests/service/test_service_process.py",
        "packages/foresight_test_support/lib/gated_helper.py",
    } <= set(consumers)
    hygiene = vc.support_consumers(ROOT, ["packages/foresight_test_support/lib/test_paths.dart"], FILES)
    assert "tests/test_dart_fixture_hygiene.py" in hygiene
    assert "tests/test_dart_fixture_hygiene.py" in plan_for(["packages/foresight_test_support/lib/test_paths.dart"])["closure"][0]["consumers"] or len(hygiene) > vc.LIST_LIMIT * 4


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
    assert everything == sorted(
        [
            "packages/foresight_core/test/unrelated_test.dart",
            "packages/foresight_core/test/x_test.dart",
            "packages/foresight_core/test/y_test.dart",
            "packages/foresight_test_support/lib/a.dart",
            "packages/foresight_test_support/lib/b.dart",
            "packages/foresight_test_support/lib/gated_helper.py",
            "tests/service/gated_helper.py",
            "tests/service/test_service_process.py",
        ]
    )


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
    library_prerequisite = next(item for item in core["prerequisites"] if item["requirement"]["kind"] == "path")
    assert library_prerequisite["met"] and "satisfied_by" not in library_prerequisite and library_prerequisite["detail"] == str(library)
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


def test_long_checks_are_deferred_in_the_plan_but_never_hidden(monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    native = next(item for item in plan_for(["native/foresight_native.h"])["checks"] if item["id"] == "native-stage")
    assert native["availability"] == "runnable" and native["long"]
    assert native["deferred"] == "long-running; add --include-long to execute it"
    included = plan_for(["native/foresight_native.h"], include_long=True)
    assert included["include_long"] is True
    assert "deferred" not in next(item for item in included["checks"] if item["id"] == "native-stage")


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
        # "timeout" models an entrypoint that exited 0 but only after the deadline had fired.
        return {"returncode": 0 if code == "timeout" else code, "timed_out": code == "timeout", "seconds": 0.5, "log": str(log_path)}

    return run


@pytest.fixture
def private_output(tmp_path, monkeypatch):
    monkeypatch.setattr(check_local_validation, "TEMP_PARENT", tmp_path.resolve())
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    # pytest's temp paths exceed the Unix-socket policy; enforcement has its own tests.
    monkeypatch.setattr(vc.validation_evidence, "SHORT_TEMP_LIMIT", 500)
    return tmp_path / "evidence"


def test_a_documentation_only_run_can_be_a_full_validation_of_its_own_scope(private_output, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}, calls))
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output)], root=ROOT, environ={"GITHUB_TOKEN": "secret"})
    assert code == 0 and len(calls) == 1 and calls[0][0][-1] == "tools.check_local_validation"
    summary = json.loads((private_output / "evidence.json").read_text())
    assert summary["status"] == "full-validation-passed" and summary["unexecuted_platforms"] == []
    assert summary["source"]["mode"] == "explicit" and summary["tools"]["python"]
    assert "secret" not in (private_output / "evidence.json").read_text()
    assert (private_output / "plan.json").is_file() and (private_output / "logs/shared-guards.log").is_file()
    assert "Result: full-validation-passed" in capsys.readouterr().out


@pytest.fixture
def accepting_junit(monkeypatch):
    """For tests about other behavior; JUnit verdicts have their own tests."""
    monkeypatch.setattr(vc.validation_evidence, "junit_problems", lambda reports: [])


def test_an_incomplete_run_is_never_a_successful_full_validation(private_output, accepting_junit, monkeypatch, capsys):
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


def test_allow_partial_changes_only_the_exit_status(tmp_path, private_output, accepting_junit, monkeypatch):
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
    # A native ABI edit does not select the full Python gate, so the guards run on their own.
    assert "python-coverage" not in by_id and by_id["shared-guards"]["status"] == "passed"


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


def test_child_processes_get_private_temp_roots_unless_already_compliant(tmp_path, monkeypatch):
    output = tmp_path / "out"
    output.mkdir(mode=0o700)
    monkeypatch.setattr(vc.validation_evidence, "SHORT_TEMP_LIMIT", 500)
    env, policy = vc.child_environment({"PATH": "/bin"}, output)
    assert env["TMPDIR"] == str(output / "tmp") and env["FORESIGHT_TEST_TEMP_ROOT"] == str(output / "t")
    assert policy["source"].startswith("created") and (output / "tmp").stat().st_mode & 0o077 == 0
    assert env["FORESIGHT_PYTHON"] == sys.executable
    root = Path(os.path.realpath(tmp_path)) / "s"
    root.mkdir(mode=0o700)
    env, policy = vc.child_environment({"TMPDIR": str(root), "FORESIGHT_TEST_TEMP_ROOT": str(root)}, output)
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
    assert all(check["why"] for check in plan["checks"]) and "entries" not in plan["change_set"]


def test_human_plan_explains_selection_prerequisites_reuse_and_unverified_items(capsys):
    code, captured = cli(["--files", "native/foresight_native.h", "--plan"], capsys)
    assert code == 0
    for text in ("Boundaries", "why:", "unverified:", "prerequisite", "run:", "deferred:", "never presented as a fresh build", "CI selection"):
        assert text in captured.out, text
    code, captured = cli(["--files", "brand/new/file", "--plan"], capsys)
    assert "Conservative selection (unknown inputs)" in captured.out


def test_boundary_request_records_the_real_source_state_and_honors_include(capsys, monkeypatch):
    seen = {}

    def collect(root, base, include):
        seen.update(base=base, include=list(include))
        return vc.build_change_set(
            root, mode="git", paths_by_class={}, revision="abc123", base=base, merge_base=None,
            dirty=True, dirty_paths=["untracked.txt"], excluded_classes=["staged", "unstaged", "untracked"],
        )

    monkeypatch.setattr(vc, "collect_git", collect)
    code, captured = cli(["--boundary", "service-helper", "--include", "committed", "--plan", "--json"], capsys)
    plan = json.loads(captured.out)["plan"]
    assert code == 0 and seen == {"base": None, "include": ["committed"]}
    assert plan["change_set"]["mode"] == "git" and plan["change_set"]["revision"] == "abc123"
    assert plan["change_set"]["dirty"] is True and plan["change_set"]["excluded_classes"] == ["staged", "unstaged", "untracked"]
    assert plan["change_set"]["paths"] == [] and plan["empty_change_set"]
    assert [boundary["id"] for boundary in plan["boundaries"]] == ["service-helper"]
    assert {"service-stage", "core-stage", "native-stage", "shared-guards"} <= {check["id"] for check in plan["checks"]}


def test_boundary_request_without_git_records_that_nothing_was_collected(capsys, monkeypatch):
    def refuse(root, base, include):
        raise vc.PlanError("git is not available")

    monkeypatch.setattr(vc, "collect_git", refuse)
    code, captured = cli(["--boundary", "service-helper", "--plan", "--json"], capsys)
    change = json.loads(captured.out)["plan"]["change_set"]
    assert code == 0 and change["mode"] == "boundary-request" and change["dirty"] is None
    assert change["dirty_unknown"] == "no change set was collected: git is not available" and change["revision"] is None
    # An explicit --base is never silently dropped.
    assert vc.main(["--skip-inventory-check", "--boundary", "service-helper", "--base", "main", "--plan"], root=ROOT, environ={}) == 2
    assert "git is not available" in capsys.readouterr().err


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


# ------------------------------------------------- review fixes: required jobs


def test_required_ci_jobs_beyond_the_gates_reach_a_gate_and_block_a_full_claim(private_output, accepting_junit, monkeypatch):
    plan = plan_for(["tests/test_measure_service_rpc.py"], host="linux")
    ci = plan["ci_selection"]
    assert {"acceptance-cpu", "acceptance-audio", "acceptance-deb", "linux-native"} <= set(ci["required_jobs"])
    assert not ci["unmapped_jobs"] and set(ci["job_gates"]) == {"acceptance-cpu", "acceptance-audio", "acceptance-deb", "linux-native"}
    checks = {check["id"]: check for check in plan["checks"]}
    assert checks["hosted-acceptance"]["availability"] == "ci-only" and checks["hosted-linux-native"]["availability"] == "ci-only"
    assert {"integration-models", "integration-virtual-audio"} <= set(checks)
    assert any(entry["rule"] == "ci-job:acceptance-deb" for entry in checks["hosted-acceptance"]["why"])
    # A run therefore cannot be a full validation while those required jobs never ran.
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    code = vc.main(["--files", "tests/test_measure_service_rpc.py", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 3 and summary["status"] == "partial"
    statuses = {check["id"]: check["status"] for check in summary["checks"]}
    assert statuses["hosted-acceptance"] == statuses["hosted-linux-native"] == "ci-only"
    assert "acceptance-cpu" in summary["selection"]["ci_required_jobs"]


def test_a_required_job_without_a_mapping_selects_everything(monkeypatch):
    real = vc.ci_selection.required_jobs
    monkeypatch.setattr(vc.ci_selection, "required_jobs", lambda *a, **k: [*real(*a, **k), "brand-new-job"])
    plan = plan_for(["tests/test_measure_service_rpc.py"])
    assert plan["ci_selection"]["unmapped_jobs"] == ["brand-new-job"]
    assert plan["conservative"] and {check["id"] for check in plan["checks"]} == GATES


# ------------------------------------------------------ review fixes: sanitizers


@pytest.mark.parametrize(
    "path",
    [
        "proto/linux/helper_control.proto",
        "services/helper/main.cpp",
        "tests/helper/contract.cpp",
        "tests/inference/fd_stream.cpp",
        "tests/integration/test_native.py",
        "tests/test_sanitizer_runtime.py",
        "tests/test_native_leak_sanitizer.py",
        "packaging/sanitizer-grpc.cmake",
        "tools/run_native_sanitizers.sh",
        ".github/workflows/native-sanitizers.yml",
    ],
)
def test_the_sanitizer_workflow_path_filter_selects_the_sanitizer_gate(path):
    plan = plan_for([path])
    assert plan["ci_selection"]["sanitizers"] is True
    check = next(item for item in plan["checks"] if item["id"] == "native-sanitizers")
    assert check["availability"] == "ci-only" and "linux" in plan["required_platforms"]


def test_documentation_does_not_select_sanitizers_and_a_broken_selector_does(monkeypatch):
    docs = plan_for(["docs/testing.md"])
    assert docs["ci_selection"]["sanitizers"] is False and "native-sanitizers" not in selected(docs)[1]
    monkeypatch.setattr(vc.ci_selection, "select", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("drift")))
    assert "native-sanitizers" in selected(plan_for(["docs/testing.md"]))[1]


# -------------------------------------------------- review fixes: empty changes


def clean_empty_checkout(monkeypatch):
    """A clean checkout with nothing changed, independent of this working tree's state."""
    monkeypatch.setattr(
        vc, "collect_git",
        lambda root, base, include: vc.build_change_set(
            root, mode="git", paths_by_class={}, revision="abc123", base=base, merge_base=None,
            dirty=False, dirty_paths=[], excluded_classes=[name for name in vc.CLASSES if name not in include],
        ),
    )


def test_an_empty_change_set_is_partial_unless_the_baseline_is_explicit(private_output, accepting_junit, monkeypatch, tmp_path, capsys):
    clean_empty_checkout(monkeypatch)
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    code = vc.main(["--include", "committed", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 3 and summary["status"] == "partial" and not summary["full_validation"]
    assert any("empty change set" in reason for reason in summary["not_full_validation_reasons"])
    assert summary["source"]["path_count"] == 0

    second = tmp_path / "second"
    code = vc.main(["--include", "committed", "--baseline-only", "--output", str(second)], root=ROOT, environ={})
    summary = json.loads((second / "evidence.json").read_text())
    assert code == 0 and summary["status"] == "full-validation-passed" and summary["invocation"]["baseline_only"] is True
    capsys.readouterr()


def test_boundary_request_alone_is_partial_with_a_nothing_selected_reason(private_output, accepting_junit, monkeypatch):
    clean_empty_checkout(monkeypatch)
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    code = vc.main(["--boundary", "service-helper", "--include", "committed", "--allow-partial", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 0 and summary["status"] == "partial"
    assert any("empty change set" in reason and "requested boundaries" in reason for reason in summary["not_full_validation_reasons"])


def test_empty_files_input_is_rejected(tmp_path, capsys, monkeypatch):
    listing = tmp_path / "empty.txt"
    listing.write_text("\n\n")
    assert vc.main(["--files-from", str(listing), "--plan"], root=ROOT, environ={}) == 2
    assert "lists no paths" in capsys.readouterr().err
    monkeypatch.setattr(vc.sys, "stdin", io.StringIO(""))
    assert vc.main(["--files-from", "-", "--plan"], root=ROOT, environ={}) == 2


# ---------------------------------------------------- review fixes: JUnit verdict


def junit_plan(tmp_path, report):
    plan = plan_for(["tests/test_build_stages.py"], host="linux")
    check = next(item for item in plan["checks"] if item["id"] == "platform-contracts")
    check["junit"] = [str(report)]
    plan["checks"] = [check]
    return plan


def junit_runner(report, text):
    def run(argv, *, cwd, env, log_path, timeout, stream=None):
        if text is not None:
            report.write_text(text)
        log_path.write_text("log\n")
        return {"returncode": 0, "timed_out": False, "leaked_descendants": False, "seconds": 0.1, "log": str(log_path)}

    return run


@pytest.mark.parametrize(
    ("text", "fragment"),
    [
        (None, "report missing"),
        ('<testsuite tests="3" failures="1" errors="0" skipped="0"/>', "1 failure(s)"),
        ('<testsuite tests="3" failures="0" errors="2" skipped="0"/>', "2 error(s)"),
        ('<testsuite tests="3" failures="0" errors="0" skipped="3"/>', "no executed tests"),
        ('<testsuites/>', "no executed tests"),
        ("<testsuite", "unreadable (ParseError)"),
        ('<testsuite tests="many" failures="0" errors="0"/>', "malformed count attribute"),
    ],
)
def test_declared_junit_evidence_that_does_not_support_a_pass_fails_the_check(tmp_path, text, fragment):
    report = tmp_path / "r.xml"
    output = tmp_path / "o"
    output.mkdir(mode=0o700)
    original = vc.validation_evidence.SHORT_TEMP_LIMIT
    vc.validation_evidence.SHORT_TEMP_LIMIT = 500
    try:
        results, _ = vc.execute(junit_plan(tmp_path, report), output, {}, include_long=False, runner=junit_runner(report, text))
    finally:
        vc.validation_evidence.SHORT_TEMP_LIMIT = original
    assert results[0]["status"] == "failed" and fragment in results[0]["reason"]


def test_fresh_passing_junit_supports_a_pass_and_stale_junit_does_not(tmp_path):
    report = tmp_path / "r.xml"
    output = tmp_path / "o"
    output.mkdir(mode=0o700)
    vc.validation_evidence.SHORT_TEMP_LIMIT, original = 500, vc.validation_evidence.SHORT_TEMP_LIMIT
    try:
        good = '<testsuite tests="4" failures="0" errors="0" skipped="1"/>'
        results, _ = vc.execute(junit_plan(tmp_path, report), output, {}, include_long=False, runner=junit_runner(report, good))
        assert results[0]["status"] == "passed" and results[0]["junit"][0]["executed"] == 3
        old = time.time() - 3600
        report.write_text(good)
        os.utime(report, (old, old))
        results, _ = vc.execute(junit_plan(tmp_path, report), output, {}, include_long=False, runner=junit_runner(report, None))
        assert results[0]["status"] == "failed" and "not written during this run" in results[0]["reason"]
    finally:
        vc.validation_evidence.SHORT_TEMP_LIMIT = original


def test_junit_paths_resolve_against_the_context_root(tmp_path):
    context = vc.Context(tmp_path, {}, host="linux")
    plan = vc.build_plan(INVENTORY, vc.explicit_change_set(ROOT, ["tests/test_build_stages.py"]), ROOT, context, files=FILES)
    check = next(item for item in plan["checks"] if item["id"] == "platform-contracts")
    assert check["junit"] == [str(tmp_path / "coverage/python/linux-contracts.xml")]
    assert next(item for item in plan_for(["tests/test_build_stages.py"], host="linux")["checks"] if item["id"] == "platform-contracts")["junit"] == [str(ROOT / "coverage/python/linux-contracts.xml")]


# ------------------------------------------------------ review fixes: watchdog


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_an_escaped_grandchild_cannot_extend_the_deadline_and_is_reported_as_leaked(tmp_path, monkeypatch):
    monkeypatch.setattr(vc, "KILL_GRACE_SECONDS", 1)
    monkeypatch.setattr(vc, "READER_GRACE_SECONDS", 1)
    marker = tmp_path / "pid"
    script = (
        "import subprocess,sys;"
        "c=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],start_new_session=True);"
        f"open({str(marker)!r},'w').write(str(c.pid));print('parent done',flush=True)"
    )
    started = time.monotonic()
    result = vc.run_streaming([sys.executable, "-c", script], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=2, stream=io.StringIO())
    child = int(marker.read_text())
    try:
        assert time.monotonic() - started < 12
        # The entrypoint exited 0 before the deadline: that is not a timeout.
        assert result["returncode"] == 0 and result["timed_out"] is False and result["leaked_descendants"] is True
        assert vc._outcome_status(result)[0] == "failed" and "escaped the process group" in vc._outcome_status(result)[1]
    finally:
        os.kill(child, 9)


def test_a_clean_exit_is_neither_leaked_nor_timed_out(tmp_path):
    result = vc.run_streaming([sys.executable, "-c", "print(1)"], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=30, stream=io.StringIO())
    assert (result["returncode"], result["timed_out"], result["leaked_descendants"], result["error"]) == (0, False, False, None)
    assert vc._outcome_status(result) == ("passed", None)


def test_the_process_group_is_killed_when_the_run_is_interrupted(tmp_path):
    import _thread

    marker = tmp_path / "pid"
    script = f"import os,time;open({str(marker)!r},'w').write(str(os.getpid()));time.sleep(60)"
    # nohup, a background job or a CI wrapper can leave SIGINT ignored, which makes
    # interrupt_main a no-op; install the default handler for the test's duration.
    previous = signal.signal(signal.SIGINT, signal.default_int_handler)
    timer = threading.Timer(1.5, _thread.interrupt_main)
    timer.start()
    try:
        with pytest.raises(KeyboardInterrupt):
            # Bounded: a lost interrupt fails in a few seconds, not after the entrypoint's sleep.
            vc.run_streaming([sys.executable, "-c", script], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=8, stream=io.StringIO())
    finally:
        timer.cancel()
        signal.signal(signal.SIGINT, previous)
    pid = int(marker.read_text())
    deadline = time.monotonic() + 10
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    assert not alive(pid)


def test_the_interrupt_test_passes_when_sigint_is_inherited_as_ignored(tmp_path):
    node = "tests/test_validate_change.py::test_the_process_group_is_killed_when_the_run_is_interrupted"
    program = (
        "import signal, sys\n"
        "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
        "assert signal.getsignal(signal.SIGINT) == signal.SIG_IGN\n"
        "import pytest\n"
        f"sys.exit(pytest.main([{node!r}, '-q', '-p', 'no:cacheprovider', '--basetemp', {str(tmp_path / 'inner')!r}]))\n"
    )
    completed = subprocess.run([sys.executable, "-c", program], cwd=ROOT, capture_output=True, text=True, timeout=120, check=False)
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "1 passed" in completed.stdout


def test_start_and_log_failures_are_failed_outcomes_not_exceptions(tmp_path):
    missing = vc.run_streaming([str(tmp_path / "no-such-binary")], cwd=tmp_path, env={}, log_path=tmp_path / "log", timeout=5, stream=io.StringIO())
    assert "cannot start" in missing["error"] and vc._outcome_status(missing)[0] == "failed"
    nolog = vc.run_streaming([sys.executable, "-c", "pass"], cwd=tmp_path, env=os.environ, log_path=tmp_path / "absent" / "log", timeout=5, stream=io.StringIO())
    assert "cannot open the log" in nolog["error"]


def test_a_failing_terminal_or_log_does_not_wedge_the_entrypoint(tmp_path):
    class Broken(io.StringIO):
        def write(self, text):
            raise BrokenPipeError

    result = vc.run_streaming([sys.executable, "-c", "print('x'*100000)"], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=30, stream=Broken())
    assert result["returncode"] == 0 and (tmp_path / "log").stat().st_size > 100000


def test_runner_oserror_is_a_failed_check_and_interruption_keeps_results(tmp_path, private_output, accepting_junit, monkeypatch):
    plan = plan_for(["tests/test_build_stages.py"], host="linux")
    plan["checks"] = [c for c in plan["checks"] if c["id"] in ("shared-guards", "platform-contracts")]
    output = tmp_path / "a"
    output.mkdir(mode=0o700)

    def failing(*a, **k):
        raise OSError("disk exploded")

    monkeypatch.setattr(vc.validation_evidence, "SHORT_TEMP_LIMIT", 500)
    results, _ = vc.execute(plan, output, {}, include_long=False, runner=failing)
    assert {r["status"] for r in results} == {"failed"} and "disk exploded" in results[0]["reason"]

    calls = []

    def interrupting(argv, **keywords):
        calls.append(argv)
        if len(calls) == 2:
            raise KeyboardInterrupt
        keywords["log_path"].write_text("x")
        return {"returncode": 0, "timed_out": False, "leaked_descendants": False, "seconds": 0, "log": str(keywords["log_path"])}

    second = tmp_path / "b"
    second.mkdir(mode=0o700)
    results, _ = vc.execute(plan, second, {}, include_long=False, runner=interrupting)
    assert [r["status"] for r in results] == ["passed", "failed"] and results[1]["interrupted"] and results[1]["reason"] == "interrupted"


def test_main_writes_evidence_and_exits_130_when_interrupted(private_output, accepting_junit, monkeypatch):
    def interrupting(argv, **keywords):
        raise KeyboardInterrupt

    monkeypatch.setattr(vc, "run_streaming", interrupting)
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 130 and summary["status"] == "failed" and summary["checks"][0]["interrupted"] is True


# --------------------------------------------------------- review fixes: editorial


def test_markdown_fixtures_under_test_trees_are_not_editorial():
    fixture = "apps/desktop/test/fixtures/reference_meeting_export.md"
    plan = plan_for([fixture])
    assert plan["conservative"] and selected(plan)[0] == BOUNDARIES and fixture in plan["conservative_reasons"]
    assert vc.editorial("README.md", ["*.md"]) and vc.editorial("docs/a/b.md", ["docs/**"])
    assert not vc.editorial("apps/desktop/lib/README.md", ["*.md"])
    assert not plan_for(["docs/testing.md", "CONTRIBUTING.md"])["conservative"]


# --------------------------------------------------- review fixes: source identity


def test_explicit_mode_does_not_claim_a_clean_tree_and_separates_deleted_from_unreadable(tmp_path):
    (tmp_path / "locked.txt").write_text("x")
    (tmp_path / "locked.txt").chmod(0)
    try:
        change = vc.explicit_change_set(tmp_path, ["locked.txt", "deleted.txt", "../escape"])
    finally:
        (tmp_path / "locked.txt").chmod(0o600)
    states = {entry["path"]: entry["content"] for entry in change["entries"]}
    if os.geteuid() != 0:
        assert states["locked.txt"] == "unreadable" and change["unreadable_paths"] == ["locked.txt"]
    assert states["deleted.txt"] == "absent" and states["../escape"] == "invalid-path"
    assert change["dirty"] is None and "not inspected" in change["dirty_unknown"]


def test_unreadable_content_makes_a_run_partial(private_output, accepting_junit, monkeypatch, tmp_path):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    monkeypatch.setattr(vc, "_content", lambda path: (None, "unreadable"))
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 3 and any("unreadable" in reason for reason in summary["not_full_validation_reasons"])


def test_a_source_export_inside_another_checkout_is_refused(repository):
    export = repository / "nested-export"
    export.mkdir()
    with pytest.raises(vc.PlanError, match="--files"):
        vc.collect_git(export, "main")
    assert vc.collect_git(repository, "main")["mode"] == "git"


def test_the_nested_export_is_refused_by_the_cli(tmp_path, monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=60)
    export = export_tree(tmp_path / "inner")
    completed = subprocess.run(
        [sys.executable, "-m", "tools.validate_change", "--base", "HEAD", "--plan", "--skip-inventory-check"],
        cwd=export, capture_output=True, text=True, timeout=120, check=False, env={"PATH": os.environ["PATH"], "GIT_CONFIG_GLOBAL": os.devnull},
    )
    assert completed.returncode == 2 and "not the top of a Git checkout" in completed.stderr and "--files" in completed.stderr


# ----------------------------------------------------- review fixes: honesty flags


def test_skipping_the_inventory_check_is_recorded_and_downgrades_the_run(private_output, accepting_junit, monkeypatch):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    code = vc.main(["--files", "docs/testing.md", "--skip-inventory-check", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 3 and summary["status"] == "partial" and summary["invocation"]["inventory_verified"] is False
    assert any("--skip-inventory-check" in reason for reason in summary["not_full_validation_reasons"])


def test_temp_root_policy_is_enforced_not_just_recorded(tmp_path, capsys, monkeypatch):
    output = tmp_path / ("deep" * 20)
    output.mkdir(mode=0o700)
    with pytest.raises(vc.PlanError, match="Temp-root policy"):
        vc.child_environment({}, output)
    monkeypatch.setattr(check_local_validation, "TEMP_PARENT", tmp_path.resolve())
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    code = vc.main(["--files", "docs/testing.md", "--output", str(tmp_path / ("x" * 60))], root=ROOT, environ={})
    assert code == 2 and "Temp-root policy" in capsys.readouterr().err


# ------------------------------------------------------- review fixes: errors


def test_input_and_inventory_loading_errors_exit_two(tmp_path, capsys):
    assert vc.main(["--files", "a", "--plan", "--skip-inventory-check"], root=tmp_path, environ={}) == 2
    assert "FileNotFoundError" in capsys.readouterr().err
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/boundary_inventory.json").write_text("{not json")
    assert vc.main(["--files", "a", "--plan", "--skip-inventory-check"], root=tmp_path, environ={}) == 2
    assert "JSONDecodeError" in capsys.readouterr().err
    (tmp_path / "tools/boundary_inventory.json").write_text(json.dumps({"schema": 1, "boundaries": [], "impact_rules": []}))
    assert vc.main(["--files", "a", "--plan", "--skip-inventory-check"], root=tmp_path, environ={}) == 2
    assert "KeyError" in capsys.readouterr().err
    assert vc.main(["--files-from", str(tmp_path / "missing"), "--plan"], root=ROOT, environ={}) == 2


def test_results_are_printed_before_evidence_is_written(private_output, accepting_junit, monkeypatch, capsys):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))

    def refuse(summary, destination):
        raise OSError("read-only file system")

    monkeypatch.setattr(vc.validation_evidence, "write_summary", refuse)
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output)], root=ROOT, environ={})
    captured = capsys.readouterr()
    assert code == 2 and "Result: full-validation-passed" in captured.out and "evidence could not be written" in captured.err
    monkeypatch.setattr(vc, "run_streaming", fake_runner({"check_local_validation": 1}))
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output.parent / "again")], root=ROOT, environ={})
    assert code == 1


# ------------------------------------------------------ review fixes: low items


def test_reuse_is_observed_again_at_execution(tmp_path):
    build = tmp_path / "build"
    plan = plan_for(["native/foresight_native.h"], environ={"FORESIGHT_BUILD_DIR": str(build)}, host="linux")
    plan["checks"] = [c for c in plan["checks"] if c["id"] == "native-stage"]
    assert plan["checks"][0]["reuse"][0]["present"] is False
    (build / "native").mkdir(parents=True)
    library = build / "native" / "libforesight_native.so"
    library.write_bytes(b"built after the plan")
    output = tmp_path / "o"
    output.mkdir(mode=0o700)
    vc.validation_evidence.SHORT_TEMP_LIMIT, original = 500, vc.validation_evidence.SHORT_TEMP_LIMIT
    try:
        results, _ = vc.execute(plan, output, {}, include_long=True, runner=fake_runner({}))
    finally:
        vc.validation_evidence.SHORT_TEMP_LIMIT = original
    reuse = results[0]["reuse"][0]
    assert reuse["present"] is False and reuse["at_execution"]["present"] is True
    assert list(reuse["at_execution"]["sha256"].values()) == [hashlib_sha(b"built after the plan")]
    record = {"path": str(build), "digest_files": [str(build), str(tmp_path / "gone")]}
    observed = vc.observe_reuse(dict(record))
    assert "not a regular file" in observed["digest_skipped"][str(build)] and "FileNotFoundError" in observed["digest_skipped"][str(tmp_path / "gone")]
    big = tmp_path / "big"
    big.write_bytes(b"12345")
    original_limit = vc.DIGEST_LIMIT
    vc.DIGEST_LIMIT = 2
    try:
        assert "larger than" in vc.observe_reuse({"path": str(big), "digest_files": [str(big)]})["digest_skipped"][str(big)]
    finally:
        vc.DIGEST_LIMIT = original_limit


def hashlib_sha(data):
    import hashlib

    return hashlib.sha256(data).hexdigest()


def test_closure_scan_keeps_unreadable_consumers_and_follows_parts_and_conditional_imports(tmp_path):
    def write(path, text=""):
        target = tmp_path / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    write("packages/foresight_test_support/lib/a.dart")
    write("packages/foresight_core/test/lib_test.dart", "import 'package:foresight_test_support/a.dart';\npart 'lib_part.dart';\n")
    write("packages/foresight_core/test/lib_part.dart", "part of 'lib_test.dart';\n")
    write("packages/foresight_core/test/conditional_test.dart", "import 'stub.dart'\n    if (dart.library.io) 'package:foresight_test_support/a.dart';\n")
    write("packages/foresight_core/test/locked_test.dart", "import 'package:foresight_test_support/a.dart';\n")
    files = boundary_inventory.repo_files(tmp_path)
    locked = tmp_path / "packages/foresight_core/test/locked_test.dart"
    locked.chmod(0)
    errors = []
    try:
        consumers = vc.support_consumers(tmp_path, ["packages/foresight_test_support/lib/a.dart"], files, errors)
    finally:
        locked.chmod(0o600)
    assert "packages/foresight_core/test/conditional_test.dart" in consumers
    assert "packages/foresight_core/test/lib_part.dart" in consumers  # reached through its library
    if os.geteuid() != 0:
        assert "packages/foresight_core/test/locked_test.dart" in consumers and any("locked_test.dart" in e for e in errors)


def test_closure_read_errors_make_the_plan_conservative(monkeypatch):
    def unreadable(root, changed, files, errors=None):
        errors.append("closure scan could not read x.dart (PermissionError); it is treated as a consumer")
        return []

    monkeypatch.setattr(vc, "support_consumers", unreadable)
    plan = plan_for(["packages/foresight_test_support/lib/poll.dart"])
    assert plan["conservative"] and any("closure scan could not read" in reason for reason in plan["conservative_reasons"])


def test_deferred_long_gates_are_listed_as_unverified_and_subsumption_is_a_claim(tmp_path, monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    plan = plan_for([], boundaries=["dart-native-ffi"])
    boundary = plan["boundaries"][0]
    assert any(item.startswith("native-stage: deferred - long-running") for item in boundary["unverified"])
    plan = plan_for(["tools/build.sh"], include_long=True)
    output = tmp_path / "o"
    output.mkdir(mode=0o700)
    monkeypatch.setattr(vc.validation_evidence, "SHORT_TEMP_LIMIT", 500)
    results, _ = vc.execute(plan, output, {}, include_long=True, runner=fake_runner({}))
    guards = next(r for r in results if r["id"] == "shared-guards")
    assert guards["status"] == "subsumed" and guards["reason"].startswith("claimed:") and "not independently verified" in guards["reason"]


def test_reproduction_line_quotes_arguments():
    plan = {"change_set": {"mode": "explicit", "identity_sha256": "0" * 64}}
    line = vc.reproduction_lines(plan, ["--files", "a file with spaces.txt", "$(touch x)"])[0]
    assert "'a file with spaces.txt'" in line and "'$(touch x)'" in line


# ----------------------------------------------- second review: verdict mutants


def test_a_zero_exit_after_the_deadline_is_still_a_timeout_failure():
    outcome = {"returncode": 0, "timed_out": True, "leaked_descendants": False, "error": None}
    assert vc._outcome_status(outcome) == ("failed", "timed out")
    assert vc._outcome_status({**outcome, "timed_out": False}) == ("passed", None)
    assert vc._outcome_status({**outcome, "timed_out": False, "returncode": 3}) == ("failed", "exit status 3")
    assert vc._outcome_status({**outcome, "timed_out": False, "error": "disk"}) == ("failed", "disk")


def check_record(identifier, status, scope="host", kind="command"):
    return {"id": identifier, "status": status, "scope": scope, "kind": kind}


def test_unexecuted_platforms_counts_only_passing_host_scoped_checks():
    plan = {"required_platforms": ["linux", "macos"]}
    passed = [check_record("a", "passed"), check_record("b", "subsumed")]
    assert vc.unexecuted_platforms(plan, passed, "linux") == ["macos"]
    assert vc.unexecuted_platforms(plan, passed, "macos") == ["linux"]
    # Neutral checks (shared guards) say nothing about a platform.
    assert vc.unexecuted_platforms(plan, [check_record("guards", "passed", scope="neutral")], "linux") == ["linux", "macos"]
    # A failed or unavailable host-scoped command check means the host did not execute.
    assert vc.unexecuted_platforms(plan, [*passed, check_record("c", "failed")], "linux") == ["linux", "macos"]
    assert vc.unexecuted_platforms(plan, [*passed, check_record("c", "unavailable")], "linux") == ["linux", "macos"]
    # CI-only and manual checks do not make a passing host unexecuted; they block the claim themselves.
    assert vc.unexecuted_platforms(plan, [*passed, check_record("d", "ci-only", kind="ci-only")], "linux") == ["macos"]
    assert vc.unexecuted_platforms({"required_platforms": []}, passed, "linux") == []
    assert vc.unexecuted_platforms({"required_platforms": ["linux"]}, passed, "linux") == []


# ---------------------------------------- second review: run mode without Git


def test_export_run_mode_and_inventory_guard_never_call_git(tmp_path, monkeypatch, accepting_junit):
    export = export_tree(tmp_path / "tree")
    # Only the export path is on PATH: any attempt to start git fails loudly.
    monkeypatch.setenv("PATH", "/nonexistent")
    git_calls = []

    def spy(root, *arguments):
        git_calls.append(arguments)
        raise AssertionError("git was called")

    monkeypatch.setattr(vc, "_git", spy)
    assert boundary_inventory.main(["--root", str(export)]) == 0
    monkeypatch.setattr(check_local_validation, "TEMP_PARENT", tmp_path.resolve())
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}" if name != "git" else None)
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    monkeypatch.setattr(vc.validation_evidence, "SHORT_TEMP_LIMIT", 500)
    code = vc.main(
        ["--files", "docs/testing.md", "--revision", "fixture-rev", "--base-revision", "fixture-base", "--output", str(tmp_path / "ev")],
        root=export, environ={"PATH": "/nonexistent"},
    )
    summary = json.loads((tmp_path / "ev/evidence.json").read_text())
    assert code == 0 and git_calls == []
    assert summary["status"] == "full-validation-passed" and summary["source"]["mode"] == "explicit"
    assert summary["source"]["revision"] == "fixture-rev" and summary["source"]["dirty"] is None
    assert summary["tools"]["git"] is None


# --------------------------------------------- third review: include and identity


def dirty_branch_repo(tmp_path, monkeypatch):
    """A branch that commits a documentation change while native/h.h is dirty."""
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    repo = tmp_path / "dirty-repo"
    repo.mkdir()

    def git(*arguments):
        subprocess.run(
            ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", *arguments],
            check=True, capture_output=True, timeout=60,
        )

    git("init", "-q", "-b", "main")
    (repo / "native").mkdir()
    (repo / "native/h.h").write_text("int a;\n")
    git("add", ".")
    git("commit", "-qm", "base")
    git("checkout", "-qb", "feature")
    (repo / "docs").mkdir()
    (repo / "docs/note.md").write_text("note\n")
    git("add", ".")
    git("commit", "-qm", "docs")
    return repo


def test_include_cannot_hide_a_dirty_path_from_the_identity_or_the_verdict(tmp_path, monkeypatch, private_output, accepting_junit):
    repo = dirty_branch_repo(tmp_path, monkeypatch)
    clean = vc.collect_git(repo, "main", include=["committed"])
    (repo / "native/h.h").write_text("int a; int b;\n")  # unstaged, outside the selected class
    dirty = vc.collect_git(repo, "main", include=["committed"])
    assert clean["paths"] == dirty["paths"] == ["docs/note.md"]
    assert clean["identity_sha256"] != dirty["identity_sha256"]
    assert dirty["dirty"] is True and dirty["excluded_dirty_paths"] == ["native/h.h"] and clean["excluded_dirty_paths"] == []
    (repo / "native/h.h").write_text("int a; int c;\n")
    assert vc.collect_git(repo, "main", include=["committed"])["identity_sha256"] != dirty["identity_sha256"]
    # The full selection sees the file, so nothing is hidden.
    assert vc.collect_git(repo, "main")["excluded_dirty_paths"] == []

    real = vc.collect_git
    monkeypatch.setattr(vc, "collect_git", lambda root, base, include: real(repo, base, include))
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    code = vc.main(["--base", "main", "--include", "committed", "--output", str(private_output)], root=ROOT, environ={})
    summary = json.loads((private_output / "evidence.json").read_text())
    assert code == 3 and summary["status"] == "partial"
    assert any("dirty paths in excluded classes" in reason and "native/h.h" in reason for reason in summary["not_full_validation_reasons"])
    assert summary["source"]["excluded_dirty_paths"] == ["native/h.h"]


# ---------------------------------------------------- third review: CI closure


def test_a_gate_added_only_by_the_ci_closure_selects_its_local_equivalent(monkeypatch):
    only_packaging = dict.fromkeys(vc.ci_changes.GATES, False) | {"packaging": True}
    monkeypatch.setattr(vc.ci_changes, "select_gates", lambda paths: dict.fromkeys(vc.ci_changes.GATES, False))
    monkeypatch.setattr(vc.ci_selection, "select", lambda paths, **k: {"selection": only_packaging, "sanitizers": False, "required_jobs": []})
    plan = plan_for(["docs/testing.md"], host="linux")
    ci = plan["ci_selection"]
    assert ci["authoritative"]["linux-document-imports"] is False
    assert ci["effective"]["linux-document-imports"] is True and ci["effective"]["linux-build"] is True
    checks = {check["id"]: check for check in plan["checks"]}
    assert "document-sandbox" in checks and "platform-contracts" in checks
    assert any(entry["rule"] == "ci:linux-document-imports" for entry in checks["document-sandbox"]["why"])


def test_the_dmg_contract_edit_reaches_the_document_sandbox_through_required_jobs():
    plan = plan_for(["tests/test_dmg_contract.py"], host="linux")
    assert plan["ci_selection"]["effective"]["linux-document-imports"] is True
    assert "document-sandbox" in selected(plan)[1]


# ----------------------------------------------------------- third review: signals


def test_sigterm_and_sighup_are_routed_like_ctrl_c_and_handlers_are_restored():
    before = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}
    with vc.interrupt_signals():
        for number in (signal.SIGTERM, signal.SIGHUP):
            with pytest.raises(vc.SignalInterrupt) as raised:
                os.kill(os.getpid(), number)
                time.sleep(1)
            assert raised.value.signum == number
    assert {number: signal.getsignal(number) for number in before} == before


def test_deferred_signals_hold_every_interrupt_until_publication_finishes():
    before = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    with vc.deferred_signals() as received:
        for number in (signal.SIGINT, signal.SIGTERM):
            os.kill(os.getpid(), number)
        time.sleep(0.2)
        assert received == [signal.SIGINT, signal.SIGTERM]
    assert {number: signal.getsignal(number) for number in before} == before


def test_signal_routing_is_skipped_outside_the_main_thread():
    problems = []

    def attempt():
        try:
            with vc.interrupt_signals(), vc.deferred_signals():
                pass
        except Exception as error:  # noqa: BLE001
            problems.append(error)

    thread = threading.Thread(target=attempt)
    thread.start()
    thread.join(timeout=30)
    assert problems == []


@pytest.mark.parametrize(("number", "code"), [(signal.SIGTERM, 143), (signal.SIGHUP, 129), (signal.SIGINT, 130)])
def test_a_signalled_run_records_the_interruption_and_exits_with_128_plus_the_signal(private_output, accepting_junit, monkeypatch, number, code):
    def interrupted(argv, **keywords):
        raise vc.SignalInterrupt(number) if number != signal.SIGINT else KeyboardInterrupt

    monkeypatch.setattr(vc, "run_streaming", interrupted)
    assert vc.main(["--files", "docs/testing.md", "--output", str(private_output)], root=ROOT, environ={}) == code
    summary = json.loads((private_output / "evidence.json").read_text())
    assert summary["status"] == "failed" and summary["checks"][0]["interrupted"] is True


def test_a_signal_while_publishing_does_not_lose_the_evidence(private_output, accepting_junit, monkeypatch):
    monkeypatch.setattr(vc, "run_streaming", fake_runner({}))
    real = vc.validation_evidence.write_summary

    def signalled(summary, destination):
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(0.2)
        return real(summary, destination)

    monkeypatch.setattr(vc.validation_evidence, "write_summary", signalled)
    code = vc.main(["--files", "docs/testing.md", "--output", str(private_output)], root=ROOT, environ={})
    assert code == 143 and json.loads((private_output / "evidence.json").read_text())["status"] == "full-validation-passed"


def test_a_signal_during_reuse_observation_is_recorded_and_the_rest_is_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    plan = plan_for(["native/foresight_native.h"], environ={"FORESIGHT_BUILD_DIR": str(tmp_path / "b")}, host="linux", include_long=True)
    plan["checks"] = [c for c in plan["checks"] if c["id"] in ("native-stage", "core-stage")]
    output = tmp_path / "o"
    output.mkdir(mode=0o700)
    monkeypatch.setattr(vc.validation_evidence, "SHORT_TEMP_LIMIT", 500)
    monkeypatch.setattr(vc, "observe_reuse", lambda record: (_ for _ in ()).throw(vc.SignalInterrupt(signal.SIGTERM)))
    results, _ = vc.execute(plan, output, {}, include_long=True, runner=fake_runner({}))
    assert [r["status"] for r in results] == ["failed", "not-run"]
    assert results[0]["interrupt_signal"] == signal.SIGTERM and results[1]["reason"] == "the run was interrupted"


def test_a_signal_during_planning_exits_without_evidence(monkeypatch, capsys):
    def signalled(*a, **k):
        os.kill(os.getpid(), signal.SIGHUP)
        time.sleep(1)

    monkeypatch.setattr(vc, "build_plan", signalled)
    assert vc.main(["--files", "docs/testing.md", "--plan", "--skip-inventory-check"], root=ROOT, environ={}) == 129
    assert "no evidence was written" in capsys.readouterr().err


WRAPPER = (
    "import sys\n"
    "from pathlib import Path\n"
    "from tools import check_local_validation as c, validate_change as v, validation_evidence as e\n"
    "c.TEMP_PARENT = Path(sys.argv[1]).resolve()\n"
    "e.SHORT_TEMP_LIMIT = 500\n"
    "raise SystemExit(v.main(sys.argv[2:], root=Path.cwd()))\n"
)
HANG = (
    "import os, sys, time\n"
    "open(os.environ['HANG_PID_FILE'], 'w').write(str(os.getpid()))\n"
    "print('entrypoint started', flush=True)\n"
    "time.sleep(600)\n"
)


@pytest.mark.parametrize("number", [signal.SIGTERM, signal.SIGHUP])
def test_end_to_end_a_signalled_planner_leaves_no_entrypoint_and_writes_evidence(tmp_path, number):
    export = export_tree(tmp_path / "tree")
    inventory_path = export / "tools/boundary_inventory.json"
    data = json.loads(inventory_path.read_text())
    data["gates"]["shared-guards"].update(argv=["{python}", "tools/hang_fixture.py"], requires=[])
    inventory_path.write_text(json.dumps(data))
    (export / "tools/hang_fixture.py").write_text(HANG)
    pid_file = tmp_path / "entrypoint.pid"
    process = subprocess.Popen(
        [sys.executable, "-c", WRAPPER, str(tmp_path), "--files", "docs/testing.md", "--skip-inventory-check", "--output", str(tmp_path / "evidence")],
        cwd=export, env={"PATH": os.environ["PATH"], "HANG_PID_FILE": str(pid_file)}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        deadline = time.monotonic() + 60
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        assert pid_file.exists(), "the entrypoint never started"
        time.sleep(0.3)
        entrypoint = int(pid_file.read_text())
        assert alive(entrypoint)
        process.send_signal(number)
        output, _ = process.communicate(timeout=60)
    finally:
        if process.poll() is None:
            process.kill()
    assert process.returncode == 128 + number
    deadline = time.monotonic() + 10
    while alive(entrypoint) and time.monotonic() < deadline:
        time.sleep(0.1)
    assert not alive(entrypoint), output
    summary = json.loads((tmp_path / "evidence/evidence.json").read_text())
    assert summary["status"] == "failed" and summary["checks"][0]["interrupted"] is True
    assert summary["checks"][0]["reason"] == "interrupted"


# ------------------------------------------------ third review: runner internals


def test_a_sigkill_that_does_not_take_effect_is_a_failed_outcome_not_a_traceback(tmp_path, monkeypatch):
    started = []
    real_popen = vc.subprocess.Popen

    def recording(*a, **k):
        process = real_popen(*a, **k)
        started.append(process)
        return process

    monkeypatch.setattr(vc.subprocess, "Popen", recording)
    monkeypatch.setattr(vc, "_signal_group", lambda process, number: None)
    monkeypatch.setattr(vc, "KILL_GRACE_SECONDS", 0.2)
    try:
        result = vc.run_streaming([sys.executable, "-c", "import time; time.sleep(60)"], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=1, stream=io.StringIO())
        assert result["timed_out"] is True and result["returncode"] is None
        assert result["error"] == "the entrypoint did not exit after SIGKILL"
        assert vc._outcome_status(result) == ("failed", "the entrypoint did not exit after SIGKILL")
    finally:
        for process in started:
            process.kill()
            process.wait(timeout=30)


def test_the_group_is_signalled_only_while_its_leader_is_unreaped(tmp_path, monkeypatch):
    seen = []
    real = vc._signal_group

    def spy(process, number):
        seen.append(process.returncode)  # None while the leader is a pinned, unreaped zombie
        real(process, number)

    monkeypatch.setattr(vc, "_signal_group", spy)
    script = "import subprocess, sys; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], stdout=subprocess.DEVNULL)"
    result = vc.run_streaming([sys.executable, "-c", script], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=30, stream=io.StringIO())
    assert result["returncode"] == 0 and seen and set(seen) == {None}


def test_a_leaked_reader_never_writes_to_a_closed_log(tmp_path, monkeypatch):
    errors = []
    monkeypatch.setattr(threading, "excepthook", lambda arguments: errors.append(arguments.exc_value))
    monkeypatch.setattr(vc, "READER_GRACE_SECONDS", 0.3)
    marker = tmp_path / "pid"
    script = (
        "import subprocess, sys;"
        "c = subprocess.Popen([sys.executable, '-c', 'import time\\nfor i in range(80):\\n    print(i, flush=True)\\n    time.sleep(0.05)'], start_new_session=True);"
        f"open({str(marker)!r}, 'w').write(str(c.pid))"
    )
    result = vc.run_streaming([sys.executable, "-c", script], cwd=tmp_path, env=os.environ, log_path=tmp_path / "log", timeout=30, stream=io.StringIO())
    child = int(marker.read_text())
    try:
        assert result["leaked_descendants"] is True
        time.sleep(1.5)  # the leaked reader keeps receiving output after the log closed
        assert errors == []
    finally:
        os.kill(child, signal.SIGKILL)


# ------------------------------------------------------ third review: skip markers


def test_python_skip_detection_covers_class_module_and_setup_level_skips():
    from tools import boundary_inventory as bi

    source = """
import sys, unittest, pytest
@unittest.skipUnless(sys.platform == 'darwin', 'mac only')
class Decorated(unittest.TestCase):
    def test_a(self): pass
class Setup(unittest.TestCase):
    def setUp(self):
        self.skipTest('no device')
    def test_b(self): pass
class SetupClass(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise unittest.SkipTest('no device')
    def test_c(self): pass
class Marked:
    pytestmark = pytest.mark.skipif(True, reason='r')
    def test_d(self): pass
class Plain:
    def test_e(self): pass
def test_f(): pass
"""
    assert bi._python_tests(source) == {"test_a": True, "test_b": True, "test_c": True, "test_d": True, "test_e": False, "test_f": False}
    module = "import pytest\npytestmark = pytest.mark.skip(reason='r')\ndef test_g(): pass\n"
    assert bi._python_tests(module) == {"test_g": True}
    assert bi._python_tests("import pytest\npytest.skip('x', allow_module_level=True)\ndef test_h(): pass\n") == {"test_h": True}
    assert bi._python_tests("import pytest\ndef test_i(): pass\n") == {"test_i": False}


# --------------------------------------------- fourth review: the batch's own files


BATCH_FILES = [
    "tests/source_export.py", "tests/test_validate_change.py", "tests/test_boundary_inventory.py",
    "tests/test_validation_evidence.py", "tests/test_workflow_lint_export.py", "tests/test_local_validation.py",
    "tools/validate_change.py", "tools/validation_evidence.py", "tools/boundary_inventory.py",
    "tools/boundary_inventory.json", "tools/check_local_validation.py", "docs/boundary-validation.md",
    "CONTRIBUTING.md", "docs/README.md", "docs/testing.md",
]


def test_the_batchs_own_files_resolve_without_falling_through_to_unknown():
    plan = plan_for(BATCH_FILES)
    assert not plan["conservative"], plan["conservative_reasons"]
    assert all(not item["unknown"] for item in plan["paths"])
    assert {item["id"] for item in plan["checks"]} < GATES  # not everything


def test_the_python_export_helper_belongs_to_the_harness_boundary_and_names_its_importers():
    plan = plan_for(["tests/source_export.py"])
    assert not plan["conservative"] and selected(plan)[0] == {"harness-os"}
    assert {"shared-guards", "python-coverage"} <= selected(plan)[1]
    consumers = plan["closure"][0]["consumers"]
    assert {"tests/test_boundary_inventory.py", "tests/test_validate_change.py", "tests/test_workflow_lint_export.py"} <= set(consumers)
    assert [entry["kind"] for entry in plan["paths"][0]["matches"]] == ["shared-test-support"]


def test_a_prerequisite_produced_by_an_earlier_stage_is_not_shown_as_satisfied(monkeypatch, capsys):
    monkeypatch.setattr(vc.shutil, "which", lambda name: f"/usr/bin/{name}")
    plan = plan_for(["native/foresight_native.h"], environ={"FORESIGHT_BUILD_DIR": "/var/tmp/of-wp1/absent-build"})
    core = next(item for item in plan["checks"] if item["id"] == "core-stage")
    pending = next(item for item in core["prerequisites"] if item.get("satisfied_by"))
    assert pending["detail"].endswith("is not present yet; it is produced by the earlier selected stage native-stage, if that stage passes in this run")
    assert "missing now" not in pending["detail"]
    text = vc.render(plan)
    assert "prerequisite pending (native-stage): " in text and "prerequisite ok: /var/tmp/of-wp1/absent-build" not in text


# --------------------------------------------- batch 3a review: core test support


def test_core_test_support_helpers_are_shared_test_support():
    for path in ("packages/foresight_core/test/support/current_read.dart", "packages/foresight_core/test/support/admission_lock_evidence.dart"):
        plan = plan_for([path])
        assert not plan["conservative"], path
        assert [entry["kind"] for entry in plan["paths"][0]["matches"]] == ["shared-test-support"]
        assert {"core-stage", "desktop-stage", "service-stage"} <= selected(plan)[1]
        assert "desktop-service" in selected(plan)[0]
    consumers = vc.support_consumers(ROOT, ["packages/foresight_core/test/support/current_read.dart"], FILES)
    assert "packages/foresight_core/test/remote_domain_test.dart" in consumers
