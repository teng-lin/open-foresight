"""Receipt/closed-snapshot mechanics with synthetic compiler outputs only."""

import json
from pathlib import Path
import subprocess
from unittest import mock

import pytest

from test_diagnostic_worker_context import complete_candidate as complete_candidate
from tools import build_diagnostic_worker as build
from tools import diagnostic_build_identity as identity
from tools import diagnostic_worker_context as context


@pytest.fixture
def product(complete_candidate):
    root, output, sdk, config = complete_candidate
    (output / "native").mkdir(parents=True, mode=0o700)
    return root, output, sdk, config


def fake_compiler(arguments, **kwargs):
    assert set(kwargs["env"]) == {"PATH", "LANG", "LC_ALL", "TMPDIR"}
    assert kwargs["timeout"] == 300 and kwargs["stdin"] == subprocess.DEVNULL
    resolver = Path(
        next(
            a.removeprefix("--packages=")
            for a in arguments
            if a.startswith("--packages=")
        )
    )
    names = {entry["name"] for entry in json.loads(resolver.read_bytes())["packages"]}
    assert names == {*context.PACKAGES, "foresight_core"}
    assert "worker-" in arguments[-1] and arguments[-1].endswith(context.ENTRY)
    Path(arguments[arguments.index("-o") + 1]).write_bytes(
        b"synthetic compiler bytes; never executable acceptance"
    )
    return subprocess.CompletedProcess(arguments, 0)


@pytest.mark.parametrize("mode", ["jit", "kernel", "aot"])
def test_finished_bytes_and_public_definitions_are_bound(product, mode):
    with (
        mock.patch.object(
            context.products, "verify", return_value={"native_id": "a" * 64}
        ),
        mock.patch.object(
            build.subprocess, "run", side_effect=fake_compiler
        ) as compiler,
    ):
        receipt = build.build_worker(*product, mode)
        assert compiler.call_count == (0 if mode == "jit" else 1)
        assert build.verify_worker_build(*product, mode) == receipt
        assert (
            receipt["defines"]["FORESIGHT_DIAGNOSTIC_BUILD_ID"] == receipt["worker_id"]
        )
        if mode != "jit":
            artifact = product[1] / receipt["artifact"]["path"]
            artifact.write_bytes(b"changed artifact")
            with pytest.raises(identity.IdentityError):
                build.verify_worker_build(*product, mode)


@pytest.mark.parametrize("change", ["schema", "extra", "defines", "mode"])
def test_receipt_exact_types_and_complete_definition_map(product, change):
    with mock.patch.object(
        context.products, "verify", return_value={"native_id": "a" * 64}
    ):
        build.build_worker(*product, "jit")
        path = product[1] / "application/diagnostic-worker-build.json"
        receipt = json.loads(path.read_bytes())
        if change == "schema":
            receipt["schema"] = True
        elif change == "extra":
            receipt["extra"] = "unbound"
        elif change == "defines":
            receipt["defines"]["FORESIGHT_DIAGNOSTIC_BUILD_ID"] = "b" * 64
        else:
            receipt["mode"] = "aot"
        path.write_bytes(identity._canonical(receipt) + b"\n")
        with pytest.raises(identity.IdentityError):
            build.verify_worker_build(*product, "jit")


def test_failed_compile_invalidates_previous_worker_context(product):
    with mock.patch.object(
        context.products, "verify", return_value={"native_id": "a" * 64}
    ):
        build.build_worker(*product, "jit")
        with (
            mock.patch.object(
                build.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)
            ),
            pytest.raises(identity.IdentityError),
        ):
            build.build_worker(*product, "aot")
        assert not (product[1] / "application/diagnostic-worker-build.json").exists()
        assert json.loads(
            (product[1] / "native/diagnostic-worker-inputs.json").read_bytes()
        ) == {"schema": 1, "available": False}
        assert (product[1] / "application/diagnostic-worker-aot.log").exists()


def test_changed_source_during_compile_cannot_publish(product):
    root = product[0]

    def changed(arguments, **kwargs):
        result = fake_compiler(arguments, **kwargs)
        (root / context.CORE / "pubspec.lock").write_text(
            "changed original after snapshot"
        )
        return result

    with (
        mock.patch.object(
            context.products, "verify", return_value={"native_id": "a" * 64}
        ),
        mock.patch.object(build.subprocess, "run", side_effect=changed),
        pytest.raises(identity.IdentityError),
    ):
        build.build_worker(*product, "aot")
    assert not (product[1] / "application/diagnostic-worker-build.json").exists()


def test_symlink_output_cannot_modify_other_products(product, tmp_path):
    outside = tmp_path / "unrelated"
    outside.mkdir()
    sentinel = outside / "diagnostic-worker-build.json"
    sentinel.write_text("unrelated product")
    (product[1] / "application").symlink_to(outside, target_is_directory=True)
    with pytest.raises(identity.IdentityError):
        build.build_worker(*product, "jit")
    assert sentinel.read_text() == "unrelated product"


def test_cli_emits_only_verified_sorted_nul_defines(tmp_path):
    destination = tmp_path / "defines.nul"
    argv = [
        "build_worker",
        "--root",
        str(tmp_path),
        "--build",
        str(tmp_path),
        "--sdk",
        str(tmp_path),
        "--package-config",
        str(tmp_path / "config.json"),
        "--mode",
        "aot",
        "--verify",
        "--defines-output",
        str(destination),
    ]
    with (
        mock.patch.object(build.sys, "argv", argv),
        mock.patch.object(
            build,
            "verify_worker_build",
            return_value={"defines": {"B": "value with spaces", "A": "a=b"}},
        ),
    ):
        assert build.main() == 0
    assert destination.read_bytes() == b"-DA=a=b\0-DB=value with spaces\0"


def test_cli_refuses_symlink_defines_output(tmp_path):
    sentinel = tmp_path / "unrelated"
    sentinel.write_text("unchanged")
    destination = tmp_path / "defines.nul"
    destination.symlink_to(sentinel)
    argv = [
        "build_worker",
        "--root",
        str(tmp_path),
        "--build",
        str(tmp_path),
        "--sdk",
        str(tmp_path),
        "--package-config",
        str(tmp_path / "config.json"),
        "--mode",
        "aot",
        "--verify",
        "--defines-output",
        str(destination),
    ]
    with (
        mock.patch.object(build.sys, "argv", argv),
        mock.patch.object(build, "verify_worker_build", return_value={"defines": {}}),
    ):
        assert build.main() == 1
    assert sentinel.read_text() == "unchanged"
