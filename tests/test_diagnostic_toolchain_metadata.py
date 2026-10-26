"""Only explicit public selected-toolchain fields participate in this fingerprint."""

from copy import deepcopy
import hashlib
from pathlib import Path
from unittest import mock

import pytest

from tools import diagnostic_toolchain_metadata as toolchain
from tools import diagnostic_build_identity as identity


def linux_fixture(tmp_path):
    compiler = tmp_path / "gcc"
    compiler.write_bytes(b"synthetic compiler bytes, never executed")
    packages = {name: "2.39-0ubuntu8.6" for name in toolchain.LINUX_PACKAGES}

    def command(arguments):
        if arguments == [str(compiler), "--version"]:
            return "gcc (Ubuntu 13.3.0-6ubuntu2) 13.3.0\npublic copyright"
        assert arguments[0] == "/usr/bin/dpkg-query"
        assert arguments[-len(packages) :] == list(toolchain.LINUX_PACKAGES)
        return "\n".join(f"{name}={version}" for name, version in packages.items())

    return compiler, packages, command


def test_linux_actual_selected_gnu_recipe_is_deterministic_and_changes(tmp_path):
    compiler, packages, command = linux_fixture(tmp_path)
    with mock.patch.object(toolchain, "_command", side_effect=command):
        first = toolchain.metadata("linux-x86_64", compiler, "gcc", "13.3.0")
        assert first == toolchain.metadata("linux-x86_64", compiler, "gcc", "13.3.0")
        assert (
            first["record"]["compiler"]["sha256"]
            == hashlib.sha256(compiler.read_bytes()).hexdigest()
        )
        assert first["record"]["system"]["packages"] == packages
        assert "not-whole-sdk-byte" in first["record"]["assurance"]
        assert str(tmp_path) not in str(first)
        packages["libc6"] = "2.39-0ubuntu8.7"
        assert (
            toolchain.metadata("linux-x86_64", compiler, "gcc", "13.3.0")["fingerprint"]
            != first["fingerprint"]
        )
        packages["libc6"] = "2.39-0ubuntu8.6"
        compiler.write_bytes(b"changed selected compiler")
        assert (
            toolchain.metadata("linux-x86_64", compiler, "gcc", "13.3.0")["fingerprint"]
            != first["fingerprint"]
        )


@pytest.mark.parametrize(
    "family,target",
    [
        ("apple-clang", "linux-x86_64"),
        ("gcc", "darwin-arm64"),
        ("unknown", "linux-x86_64"),
    ],
)
def test_unreviewed_cross_family_profiles_refuse_before_compiler_read(
    tmp_path, family, target
):
    with (
        mock.patch.object(
            toolchain, "_command", side_effect=AssertionError("compiler executed")
        ),
        pytest.raises(toolchain.MetadataError),
    ):
        toolchain.metadata(target, tmp_path / "unknown", family, "13.3.0")


@pytest.mark.parametrize("change", ["missing", "duplicate", "foreign", "invalid"])
def test_linux_metadata_is_exact_closed_package_set(tmp_path, change):
    compiler, _, original = linux_fixture(tmp_path)

    def command(arguments):
        output = original(arguments)
        if arguments[-1] == "--version":
            return output
        rows = output.splitlines()
        if change == "missing":
            rows.pop()
        if change == "duplicate":
            rows.append(rows[0])
        if change == "foreign":
            rows.append("private-config=secret-canary")
        if change == "invalid":
            rows[0] = "libc6=not a version"
        return "\n".join(rows)

    with (
        mock.patch.object(toolchain, "_command", side_effect=command),
        pytest.raises(toolchain.MetadataError),
    ):
        toolchain.metadata("linux-x86_64", compiler, "gcc", "13.3.0")


def test_mac_public_sdk_metadata_is_selected_not_app_sdk(tmp_path):
    compiler = tmp_path / "clang"
    compiler.write_bytes(b"synthetic Apple clang")
    sdk = tmp_path / "MacOSX27.sdk"
    sdk.mkdir()
    settings = sdk / "SDKSettings.json"
    settings.write_bytes(b'{"Version":"27.0"}')

    def command(arguments):
        if arguments[-1] == "--version":
            return "Apple clang version 18.0.0 (clang-1800.0.0)"
        return {
            "--show-sdk-path": str(sdk),
            "--show-sdk-version": "27.0",
            "--show-sdk-build-version": "27A123",
        }[arguments[-1]]

    with mock.patch.object(toolchain, "_command", side_effect=command):
        result = toolchain.metadata("darwin-arm64", compiler, "apple-clang", "18.0.0")
        assert result["record"]["system"] == {
            "kind": "selected-apple-os-sdk-metadata",
            "version": "27.0",
            "build": "27A123",
            "sdk_settings_sha256": hashlib.sha256(settings.read_bytes()).hexdigest(),
        }
        assert str(sdk) not in str(result)
        settings.write_bytes(b'{"Version":"27.0","changed":true}')
        assert (
            result["fingerprint"]
            != toolchain.metadata("darwin-arm64", compiler, "apple-clang", "18.0.0")[
                "fingerprint"
            ]
        )


def test_native_profile_explicitly_accepts_actual_gnu_without_changing_clang(tmp_path):
    # Reuse the checked-in contract against a Git-free synthetic native source.
    import json

    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / identity.DEFAULT_CONTRACT).read_text())
    config["scope"] = "fixture"
    config["native"]["inputs"] = [
        {
            "path": "native/diagnostic_fixture.c",
            "targets": ["linux-x86_64", "darwin-arm64"],
        }
    ]
    native = tmp_path / "native"
    native.mkdir()
    (native / "diagnostic_fixture.c").write_text("int diagnostic_fixture;\n")
    path = tmp_path / identity.DEFAULT_CONTRACT
    path.parent.mkdir()
    path.write_text(json.dumps(config))
    contract = identity.Contract(tmp_path)
    clang = identity.Compiler("clang", "22.1.8", "a" * 64, "b" * 64)
    gcc = identity.Compiler("gcc", "13.3.0", "a" * 64, "b" * 64)
    first = contract.native_identity("linux-x86_64", clang, ["-std=c11", "-O2"])
    second = contract.native_identity("linux-x86_64", gcc, ["-std=c11", "-O2"])
    assert first["native_id"] != second["native_id"]
    assert second["record"]["compiler"]["family"] == "gcc"
    with pytest.raises(identity.IdentityError, match="invalid_toolchain"):
        contract.native_identity(
            "darwin-arm64", gcc, ["-std=c11", "-mmacosx-version-min=15.0"]
        )
    bad = deepcopy(config)
    bad["native"]["targets"]["linux-x86_64"]["compiler"].append("unknown")
    path.write_text(json.dumps(bad))
    with pytest.raises(identity.IdentityError, match="invalid_target"):
        identity.Contract(tmp_path).native_identity("linux-x86_64", gcc, ["-std=c11"])


def test_selected_apple_cmake_build_suffix_uses_only_closed_public_macros(tmp_path):
    compiler = tmp_path / "clang"
    compiler.write_bytes(b"synthetic selected Apple compiler")
    sdk = tmp_path / "sdk"
    sdk.mkdir()
    (sdk / "SDKSettings.json").write_text("{}")

    def command(arguments):
        if arguments[-1] == "--version":
            return "Apple clang version 21.0.0 (clang-2100.3.3.4)"
        if arguments[-1] == "/dev/null":
            return "\n".join(
                f"#define {key} {value}"
                for key, value in [
                    ("__clang_major__", "21"),
                    ("__clang_minor__", "0"),
                    ("__clang_patchlevel__", "0"),
                    ("__apple_build_version__", "21000334"),
                    ("UNRELATED_VALUE", "DO_NOT_HASH_CANARY"),
                ]
            )
        return {
            "--show-sdk-path": str(sdk),
            "--show-sdk-version": "27.0",
            "--show-sdk-build-version": "27A123",
        }[arguments[-1]]

    with mock.patch.object(toolchain, "_command", side_effect=command):
        result = toolchain.metadata(
            "darwin-arm64", compiler, "apple-clang", "21.0.0.21000334"
        )
        assert result["record"]["compiler"]["version"] == "21.0.0.21000334"
        assert "DO_NOT_HASH_CANARY" not in str(result)
        with pytest.raises(toolchain.MetadataError):
            toolchain.metadata(
                "darwin-arm64", compiler, "apple-clang", "21.0.0.21000335"
            )


def test_cli_unknown_input_is_closed_without_echo(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["metadata", "--private-canary=do-not-persist"])
    assert toolchain.main() == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == '{"error":"diagnostic_toolchain_metadata_unavailable"}\n'


def test_explicit_other_sdk_refuses_before_settings_read(tmp_path):
    compiler = tmp_path / "clang"
    compiler.write_bytes(b"synthetic Apple compiler")
    sdk = tmp_path / "selected-sdk"
    sdk.mkdir()
    other = tmp_path / "other-sdk"
    other.mkdir()

    def command(arguments):
        if arguments[-1] == "--version":
            return "Apple clang version 18.0.0"
        assert arguments[-1] == "--show-sdk-path"
        return str(sdk)

    with (
        mock.patch.object(toolchain, "_command", side_effect=command),
        pytest.raises(toolchain.MetadataError),
    ):
        toolchain.metadata("darwin-arm64", compiler, "apple-clang", "18.0.0", other)
