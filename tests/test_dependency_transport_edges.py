"""Reuse transport rejects malformed metadata before copying/building anything."""

import copy
import io
import json
from pathlib import Path
import sys
from unittest.mock import Mock

import pytest
from tools import cleanup_linux_packages as cleanup
from tools import ci_sanitizer_artifacts as sanitizers
from tools import ci_stage_environment as environment
from tools import run_ci_stage as runner
from test_ci_app_dependency_seed import seed
from test_cleanup_linux_packages import version


@pytest.mark.parametrize("failure", [None, "config-digest", "ordering", "descriptor"])
def test_dependency_seed_qualifies_manifest_and_layer_order_before_materializing(
    tmp_path, monkeypatch, failure, capsys
):
    monkeypatch.setattr(seed, "validate_recipe", Mock())
    monkeypatch.setattr(seed, "verify_producer", Mock())
    monkeypatch.setattr(seed, "sdk_profile", lambda *a, **kw: {"compiler": "verified"})
    monkeypatch.setattr(seed, "registry_token", lambda: "fixture-token")
    manifest = {
        "config": {"digest": "sha256:" + seed.CONFIG},
        "layers": [
            {"digest": "sha256:" + identity, "size": size}
            for identity, size in seed.LAYERS
        ],
    }
    layers = [{} for _ in range(15)]
    layers[8] = {"blob": "sha256:" + seed.LAYERS[1][0], "parent": 14}
    layers[14] = {"blob": "sha256:" + seed.LAYERS[0][0]}
    config = {"records": [{"layers": [{"layer": 8}]}], "layers": layers}
    if failure == "config-digest":
        manifest["config"]["digest"] = "sha256:" + "0" * 64
    elif failure == "ordering":
        config["records"][0]["layers"][0]["layer"] = 7
    elif failure == "descriptor":
        manifest["layers"][0]["size"] += 1
    fetches = []

    def fetch(cache, identity, size, route, token):
        fetches.append((identity, size, route))
        assert token == "fixture-token"
        path = tmp_path / identity
        path.write_text(
            json.dumps(
                manifest
                if identity == seed.MANIFEST
                else config
                if identity == seed.CONFIG
                else {}
            )
        )
        return path

    monkeypatch.setattr(seed, "fetch", fetch)
    materialize = Mock()
    monkeypatch.setattr(seed, "materialize", materialize)
    if failure:
        with pytest.raises(ValueError, match="approved"):
            seed.prepare("verified-image", tmp_path / "seed", tmp_path / "cache")
        materialize.assert_not_called()
    else:
        seed.prepare("verified-image", tmp_path / "seed", tmp_path / "cache")
        assert [f[0] for f in fetches] == [
            seed.MANIFEST,
            seed.CONFIG,
            *[identity for identity, _ in seed.LAYERS],
        ]
        assert materialize.call_args.args[2] == {"compiler": "verified"}
        assert json.loads(capsys.readouterr().out)["compiled"] is False


@pytest.mark.parametrize("manager", ["pacman", "dpkg"])
def test_sanitizer_environment_binds_actual_compilers_runtime_and_abi_packages(
    tmp_path, monkeypatch, manager
):
    for name in (
        "CC",
        "CXX",
        "CFLAGS",
        "CXXFLAGS",
        "CPPFLAGS",
        "LDFLAGS",
        "CPATH",
        "CPLUS_INCLUDE_PATH",
        "LIBRARY_PATH",
        "CMAKE_PREFIX_PATH",
        "CMAKE_TOOLCHAIN_FILE",
        "CMAKE_GENERATOR",
        "CMAKE_PROJECT_INCLUDE",
        "CMAKE_PROJECT_INCLUDE_BEFORE",
    ):
        monkeypatch.delenv(name, raising=False)
    for name in ("clang", "clang++", "runtime"):
        (tmp_path / name).write_bytes(name.encode())
    monkeypatch.setattr(
        sanitizers.shutil,
        "which",
        lambda name: (
            str(tmp_path / name)
            if name in ("clang", "clang++")
            else "pacman"
            if name == manager
            else None
        ),
    )
    monkeypatch.setattr(
        sanitizers, "address_runtime", lambda **kw: tmp_path / "runtime"
    )

    def output(command, **kwargs):
        if command[0] == "clang++":
            return (
                "fixture compiler" if command[1] == "--version" else "x86_64-linux-gnu"
            )
        return "clang 20.0\ncmake 3.28\nlibc6 2.39\nunrelated 99\n"

    monkeypatch.setattr(sanitizers.subprocess, "check_output", output)
    record = sanitizers.environment("address", tmp_path / "sdk")
    assert record["target"] == "x86_64-linux-gnu"
    assert "unrelated 99" not in record["packages"]
    assert record["compiler_sha256"] == sanitizers.artifacts.digest(
        tmp_path / "clang++"
    )
    assert record["runtime_sha256"] == sanitizers.artifacts.digest(tmp_path / "runtime")
    monkeypatch.setenv("CXXFLAGS", "-funqualified")
    with pytest.raises(ValueError, match="override"):
        sanitizers.environment("address", tmp_path)
    monkeypatch.delenv("CXXFLAGS")
    monkeypatch.setattr(sanitizers.shutil, "which", lambda name: None)
    with pytest.raises(FileNotFoundError, match="Both"):
        sanitizers.environment("address", tmp_path)


@pytest.mark.parametrize(
    "platform,stage",
    [
        ("linux", "native"),
        ("linux", "core"),
        ("macos", "desktop"),
        ("macos", "service"),
    ],
)
def test_stage_environment_collects_only_required_runtime_tools(
    tmp_path, monkeypatch, platform, stage
):
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/pins.json").write_text('{"fixture":"pin"}')
    monkeypatch.setattr(environment, "reject_compiler_overrides", Mock())
    calls = []

    def version(command, required=False):
        calls.append((command, required))
        return "fixture version"

    monkeypatch.setattr(environment, "version", version)
    record = environment.collect(platform, root=tmp_path, stage=stage)
    assert record["pins"] == {"fixture": "pin"}
    assert (record["dart"] is None) == (stage == "native")
    assert (record["flutter"] is None) == (stage in ("native", "core"))
    assert ("apple_sdk" in record) == (platform == "macos")
    assert (
        (["pacman", "-Q"], True) in calls
        if platform == "linux"
        else (["brew", "list", "--versions"], True) in calls
    )
    with pytest.raises(ValueError, match="platform"):
        environment.collect("unsupported", root=tmp_path)


def test_stage_tool_version_distinguishes_optional_missing_and_required_tool(
    monkeypatch,
):
    monkeypatch.setattr(environment.shutil, "which", lambda name: None)
    assert environment.version(["optional"]) is None
    with pytest.raises(RuntimeError, match="Missing stage tool"):
        environment.version(["required"], required=True)
    monkeypatch.setattr(environment.shutil, "which", lambda name: "/tool")
    monkeypatch.setattr(
        environment.subprocess, "check_output", lambda *a, **kw: "version\n"
    )
    assert environment.version(["required"], required=True) == "version"


@pytest.mark.parametrize("changed", [False, True])
def test_cleanup_plan_keeps_cache_manifest_children_and_only_retires_old_inputs(
    tmp_path, monkeypatch, changed
):
    current, old = "a" * 64, "b" * 64
    versions = [
        version(1, current),
        version(2, "buildcache"),
        version(3, old),
        version(4),
    ]
    monkeypatch.setattr(
        cleanup.subprocess, "check_output", lambda *a, **kw: "fixture-head"
    )
    monkeypatch.setattr(cleanup, "fingerprint", lambda component: current)
    monkeypatch.setattr(cleanup, "retained_identities", lambda *a: {current})

    def api(route, method="GET"):
        return {"sha": "changed-head" if changed else "fixture-head"}

    monkeypatch.setattr(cleanup, "api", api)

    def pages(route, key=None):
        return (
            [
                {"id": 1, "name": "ci-linux-core-" + old},
                {"id": 2, "name": "ci-linux-app-" + "c" * 40},
            ]
            if key
            else versions
        )

    monkeypatch.setattr(cleanup, "pages", pages)
    manifest_calls = []

    def opening(request, **kwargs):
        url = request if isinstance(request, str) else request.full_url
        assert kwargs["timeout"] == 60
        if "/token?" in url:
            return io.BytesIO(b'{"token":"fixture-token"}')
        manifest_calls.append(url)
        return io.BytesIO(
            json.dumps(
                {"manifests": [{"digest": versions[3]["name"]}]}
                if url.endswith(versions[1]["name"])
                else {}
            ).encode()
        )

    monkeypatch.setattr(cleanup.urllib.request, "urlopen", opening)
    if changed:
        with pytest.raises(RuntimeError, match="current main"):
            cleanup.make_plan()
    else:
        plan = cleanup.make_plan()
        assert [a["id"] for a in plan["artifacts"]] == [1]
        for component in cleanup.COMPONENTS:
            assert plan["packages"][component]["versions"] == [versions[2]]
        assert any(url.endswith(versions[3]["name"]) for url in manifest_calls)


def test_cleanup_pagination_and_cli_use_no_remote_mutations_for_plan(
    tmp_path, monkeypatch
):
    requests = []

    def api(route, method="GET"):
        requests.append(route)
        return {"items": list(range(100)) if len(requests) == 1 else [100]}

    monkeypatch.setattr(cleanup, "api", api)
    assert len(cleanup.pages("items?filter=yes", "items")) == 101
    assert "&per_page=100&page=2" in requests[-1]
    plan = {
        "packages": {"linux-core": {"identity": "a", "versions": []}},
        "artifacts": [],
    }
    monkeypatch.setattr(cleanup, "make_plan", lambda: plan)
    output = tmp_path / "plan.json"
    monkeypatch.setattr(sys, "argv", ["cleanup", "--output", str(output)])
    cleanup.main()
    assert json.loads(output.read_text()) == plan
    apply = Mock()
    monkeypatch.setattr(cleanup, "apply", apply)
    monkeypatch.setattr(sys, "argv", ["cleanup", "--apply", str(output)])
    cleanup.main()
    apply.assert_called_once_with(plan)


def test_cleanup_stops_if_tags_change_during_apply(monkeypatch):
    plan = {
        "repository": cleanup.REPO,
        "head": "fixture",
        "packages": {
            "linux-core": {"identity": "new", "versions": [version(3, "old")]}
        },
        "artifacts": [],
    }
    monkeypatch.setattr(cleanup, "make_plan", lambda: copy.deepcopy(plan))
    deletes = []

    def api(route, method="GET"):
        if method == "DELETE":
            deletes.append(route)
        return {"total_count": 0} if "actions/runs" in route else version(3, "current")

    monkeypatch.setattr(cleanup, "api", api)
    with pytest.raises(RuntimeError, match="tags changed"):
        cleanup.apply(plan)
    assert not deletes


def test_stage_runner_cli_rejects_duplicate_prerequisites_and_retains_metadata(
    tmp_path, monkeypatch, capsys
):
    record = tmp_path / "environment.json"
    record.write_text('{"compiler":"verified"}')
    monkeypatch.setenv("FORESIGHT_STAGE_ENVIRONMENT", str(record))
    run = Mock(return_value={"cache_hit": True})
    monkeypatch.setattr(runner, "run", run)
    args = [
        "stage",
        "--platform",
        "linux",
        "--stage",
        "core",
        "--event",
        "pull_request",
        "--parents-json",
        '{"native":"original"}',
        "--input",
        "native=/original",
        "--cmake-arg=-DFIXTURE=ON",
    ]
    monkeypatch.setattr(sys, "argv", args)
    runner.main()
    assert json.loads(capsys.readouterr().out)["cache_hit"] is True
    assert run.call_args.args[3:6] == (
        {"compiler": "verified"},
        {"native": "original"},
        {"native": Path("/original")},
    )
    assert run.call_args.args[-1] == ["-DFIXTURE=ON"]
    monkeypatch.setattr(sys, "argv", [*args, "--input", "native=/duplicate"])
    with pytest.raises(SystemExit, match="2"):
        runner.main()
    assert run.call_count == 1
