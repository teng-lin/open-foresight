"""Cross-platform tests of Mach-O parsing, relocation and signing policy.

Tiny magic-header fixtures exercise Python policy with recorded Apple-tool
responses; the existing Darwin tests still exercise real loader/signing behavior.
"""

from pathlib import Path
import plistlib
import sys
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos_bundle as bundle
import install_macos as installer


def macho(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\xcf\xfa\xed\xfefixture")
    return path.resolve()


@pytest.fixture
def apple_tools(tmp_path, monkeypatch):
    app = tmp_path / "Fixture.app"
    executable = macho(app / "Contents/MacOS/application")
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps({"CFBundleExecutable": "application"})
    )
    state = {
        "loads": {"application": ["/usr/lib/libSystem.B.dylib"]},
        "minos": "15.0",
        "arch": "arm64",
        "changes": [],
    }

    def run(*args):
        command, operation = args[0:2]
        binary = Path(args[-1])
        if command == "lipo":
            return state["arch"]
        if command == "otool":
            if operation == "-L":
                return (
                    str(binary)
                    + ":\n"
                    + "".join(
                        f"\t{load} (compatibility version 1.0.0, current version 1.0.0)\n"
                        for load in state["loads"].get(binary.name, [])
                    )
                )
            if operation == "-l":
                return (
                    f"cmd LC_BUILD_VERSION\nminos {state['minos']}\n"
                    if state["minos"]
                    else ""
                ) + "cmd LC_RPATH\ncmdsize 48\npath @loader_path (offset 12)\n"
            if operation == "-D":
                return (
                    str(binary)
                    + "\n"
                    + (str(binary) + "\n" if binary.suffix == ".dylib" else "")
                )
            if operation == "-hv":
                return "EXECUTE" if binary.name == "application" else "DYLIB"
        if command == "install_name_tool":
            state["changes"].append(tuple(map(str, args)))
            if operation == "-change":
                _, _, old, new, binary = args
                state["loads"][Path(binary).name] = [
                    new if load == old else load
                    for load in state["loads"].get(Path(binary).name, [])
                ]
            return ""
        raise AssertionError(args)

    monkeypatch.setattr(bundle, "run", run)
    monkeypatch.setattr(bundle, "shared_cache_library", lambda path: False)
    return app.resolve(), executable, state


@pytest.mark.parametrize("framework", [False, True])
def test_relocation_copies_external_closure_and_rewrites_loader_relative_paths(
    tmp_path, apple_tools, framework
):
    app, executable, state = apple_tools
    external = macho(
        tmp_path
        / (
            "Private.framework/Versions/A/Private"
            if framework
            else "external/libprivate.dylib"
        )
    )
    dependency = macho(tmp_path / "external/libdependency.dylib")
    state["loads"]["application"] += [str(external)]
    state["loads"][external.name] = [str(dependency)]
    state["loads"][dependency.name] = ["/usr/lib/libSystem.B.dylib"]
    bundle.relocate_dependencies(app)
    records = bundle.audit_dependencies(app)
    assert len(records) == 3
    assert all(
        not load.startswith(str(tmp_path))
        for loads in records.values()
        for load in loads
    )
    assert any(
        "@loader_path/" in arg for command in state["changes"] for arg in command
    )
    assert external.is_file() and dependency.is_file()
    assert (
        app / "Contents/Resources/lib/libdependency.dylib"
    ).read_bytes() == dependency.read_bytes()
    if framework:
        assert (
            app / "Contents/Frameworks/Private.framework/Versions/A/Private"
        ).is_file()


@pytest.mark.parametrize(
    "problem",
    [
        "architecture",
        "minimum",
        "missing-minimum",
        "absolute",
        "external",
        "unresolved",
    ],
)
def test_audit_rejects_unsupported_or_nonportable_runtime_loads(
    tmp_path, apple_tools, problem
):
    app, executable, state = apple_tools
    external = macho(tmp_path / "external.dylib")
    if problem == "architecture":
        state["arch"] = "x86_64"
    elif problem == "minimum":
        state["minos"] = "15.0.1"
    elif problem == "missing-minimum":
        state["minos"] = ""
    else:
        state["loads"]["application"].append(
            str(external)
            if problem == "absolute"
            else "@loader_path/../../../external.dylib"
            if problem == "external"
            else "@rpath/missing.dylib"
        )
    with pytest.raises(
        ValueError,
        match="arm64|minimum|supported|non-system|External dependency|Unresolved",
    ):
        bundle.audit_dependencies(app)


@pytest.mark.parametrize("framework", [False, True])
def test_relocation_preserves_existing_files_on_filename_or_framework_collision(
    tmp_path, apple_tools, framework
):
    app, _, state = apple_tools
    external = macho(
        tmp_path
        / (
            "External.framework/External"
            if framework
            else "external/libcollision.dylib"
        )
    )
    state["loads"]["application"].append(str(external))
    existing = app / (
        "Contents/Frameworks/External.framework/External"
        if framework
        else "Contents/Resources/lib/libcollision.dylib"
    )
    macho(existing)
    before = existing.read_bytes()
    with pytest.raises(ValueError, match="collision|Conflicting"):
        bundle.relocate_dependencies(app)
    assert existing.read_bytes() == before


@pytest.mark.parametrize("identity", ["-", "Developer ID fixture"])
def test_signing_uses_aot_entitlements_and_seals_after_runtime_receipts(
    tmp_path, apple_tools, monkeypatch, identity
):
    app, executable, _ = apple_tools
    mcp = macho(app / "Contents/MacOS/foresight-mcp")
    service = app / "Contents/Library/Services/Open Foresight Service.app"
    macho(service / "Contents/MacOS/foresight-service")
    entitlements = tmp_path / "Release.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": False}))
    signed, timeline = {}, []

    def run(*args):
        if args[1] == "--verify":
            assert timeline[-1] == str(app)
            return ""
        target = Path(args[-1])
        selected = Path(args[args.index("--entitlements") + 1])
        signed[target] = plistlib.loads(selected.read_bytes())
        assert ("--timestamp=none" in args) == (identity == "-")
        timeline.append(str(target))
        return ""

    monkeypatch.setattr(bundle, "run", run)
    bundle.sign_application(
        app,
        identity,
        entitlements,
        before_seal=lambda: timeline.append("receipts written"),
    )
    assert signed[mcp]["com.apple.security.cs.allow-unsigned-executable-memory"] is True
    assert (
        "com.apple.security.cs.allow-unsigned-executable-memory"
        not in signed[executable]
    )
    assert signed[app].get(
        "com.apple.security.cs.disable-library-validation", False
    ) == (identity == "-")
    assert (
        timeline.index("receipts written")
        < timeline.index(str(service))
        < timeline.index(str(app))
    )
    assert plistlib.loads(entitlements.read_bytes()) == {
        "com.apple.security.app-sandbox": False
    }


def test_installer_signature_identifier_and_cli_deferred_status(
    tmp_path, monkeypatch, capsys
):
    import subprocess

    monkeypatch.setattr(installer.sys, "platform", "darwin")
    result = subprocess.CompletedProcess(
        [],
        0,
        "",
        f"Identifier={installer.IDENTIFIER}\nTeamIdentifier=fixture-team\nSignature=adhoc\n",
    )
    monkeypatch.setattr(installer.subprocess, "run", Mock(return_value=result))
    assert installer.verify_signature(tmp_path) == {
        "team": "fixture-team",
        "adhoc": True,
    }
    result.stderr = "Identifier=other\n"
    with pytest.raises(ValueError, match="identifier"):
        installer.verify_signature(tmp_path)
    operation = Mock(return_value={"installed": "fixture"})
    monkeypatch.setattr(installer, "install", operation)
    args = [
        str(tmp_path / "source"),
        "--destination",
        str(tmp_path / "destination"),
        "--allow-ad-hoc",
    ]
    assert installer.main(args) == 0
    assert json_load(capsys.readouterr().out)["installed"] == "fixture"
    operation.side_effect = installer.Deferred("recording active")
    assert installer.main(args) == 3
    assert json_load(capsys.readouterr().out)["reason"] == "recording active"
    with pytest.raises(SystemExit, match="2"):
        installer.main([*args, "--stop-services", "--defer-if-running"])
    monkeypatch.setattr(installer.sys, "platform", "linux")
    with pytest.raises(SystemExit, match="2"):
        installer.main(args)


def json_load(text):
    import json

    return json.loads(text)


def test_installer_process_ownership_uses_kernel_path_and_ignores_other_executables(
    tmp_path, monkeypatch
):
    from types import SimpleNamespace

    owned = tmp_path / "App.app/Contents/MacOS/service"
    owned.parent.mkdir(parents=True)
    owned.touch()

    def pidpath(pid, buffer, size):
        assert size == 4096
        if pid == 77:
            buffer.value = str(owned).encode()
            return len(buffer.value)
        return 0

    library = SimpleNamespace(proc_pidpath=Mock(side_effect=pidpath))
    monkeypatch.setattr(installer.sys, "platform", "darwin")
    monkeypatch.setattr(installer.ctypes, "CDLL", lambda *a, **kw: library)
    assert installer.process_path(77) == owned.resolve()
    assert installer.process_path(999) is None
    monkeypatch.setattr(
        installer.subprocess, "check_output", lambda *a, **kw: "77\n999\n"
    )
    assert installer.processes_in_bundle(tmp_path / "App.app") == {
        77: str(owned.resolve())
    }
    monkeypatch.setattr(installer.sys, "platform", "linux")
    with pytest.raises(RuntimeError, match="ownership checks"):
        installer.process_path(77)
