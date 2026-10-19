"""Packaging verifies actual bytes, compatibility requirements and license trees."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
from unittest.mock import Mock
import zipfile

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import query_worker_packaging as query
import prepare_litert as litert


def test_query_runtime_introspection_enforces_version_and_dependency_pins(
    tmp_path, monkeypatch
):
    result = {"version": [3, 13], "dependencies": query.DEPENDENCIES, "licenses": {}}

    def output(command, **kwargs):
        assert command[1:4] == ["-I", "-B", "-c"]
        assert "sentencepiece" in command
        assert kwargs["timeout"] == 300
        return json.dumps(result)

    monkeypatch.setattr(query.subprocess, "check_output", output)
    assert query.inspect_runtime(tmp_path / "python")["version"] == [3, 13]
    for replacement in (
        {"version": [3, 11]},
        {"dependencies": {"numpy": "unqualified"}},
    ):
        previous = dict(result)
        result.update(replacement)
        with pytest.raises(ValueError, match="requires Python"):
            query.inspect_runtime(tmp_path / "python")
        result.clear()
        result.update(previous)


@pytest.mark.parametrize("problem", [None, "venv", "symlink", "missing-license"])
def test_query_runtime_copy_rejects_escapes_and_preserves_complete_licenses(
    tmp_path, monkeypatch, problem
):
    source, target, notices = (
        tmp_path / "python",
        tmp_path / "bundled",
        tmp_path / "notices",
    )
    for relative, content in (
        ("bin/python3", b"interpreter"),
        ("lib/python3.13/stdlib.py", b"stdlib"),
        ("lib/python3.13/test/unnecessary.py", b"tests"),
        (
            "lib/python3.13/site-packages/numpy.dist-info/licenses/vendor/NOTICE",
            b"vendor license",
        ),
        ("cache.pyc", b"bytecode"),
        ("lib/libstatic.a", b"static archive"),
    ):
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    if problem == "symlink":
        (source / "external").symlink_to(tmp_path)

    def inspect(python):
        prefix = python.parent.parent
        return {
            "base": "/usr/system" if problem == "venv" else str(prefix),
            "stdlib": str(prefix / "lib/python3.13"),
            "licenses": {
                "numpy": []
                if problem == "missing-license"
                else [
                    str(
                        prefix
                        / "lib/python3.13/site-packages/numpy.dist-info/licenses/vendor/NOTICE"
                    )
                ],
                "sentencepiece": [],
            },
        }

    monkeypatch.setattr(query, "inspect_runtime", inspect)
    if problem:
        with pytest.raises(ValueError, match="standalone|escapes|licenses"):
            query.copy_runtime(source, target, notices)
    else:
        query.copy_runtime(source, target, notices)
        assert (target / "bin/python3").read_bytes() == b"interpreter"
        assert not list(target.rglob("*.pyc"))
        assert not list(target.rglob("*.a"))
        assert not (target / "lib/python3.13/test").exists()
        assert (
            notices / "numpy-licenses/vendor/NOTICE"
        ).read_bytes() == b"vendor license"
        assert (notices / "sentencepiece-licenses/LICENSE").read_bytes() == (
            query.ROOT / "third_party/sentencepiece/LICENSE"
        ).read_bytes()
    if problem == "venv":
        assert not target.exists()


@pytest.mark.parametrize("failure", [None, "transport", "archive", "library"])
def test_litert_extraction_requires_official_transport_and_both_checksums(
    tmp_path, monkeypatch, failure
):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("litert_lm/liblitert-lm.so", b"native bytes")
        archive.writestr("litert_lm/__init__.py", b"must not be bundled")
    data = stream.getvalue()
    monkeypatch.setattr(
        litert,
        "WHEEL_SHA256",
        "0" * 64 if failure == "archive" else hashlib.sha256(data).hexdigest(),
    )
    monkeypatch.setattr(
        litert,
        "LIBRARY_SHA256",
        "0" * 64
        if failure == "library"
        else hashlib.sha256(b"native bytes").hexdigest(),
    )
    if failure == "transport":
        monkeypatch.setattr(litert, "WHEEL_URL", "https://unqualified.invalid/wheel")
    opening = Mock(return_value=io.BytesIO(data))
    monkeypatch.setattr(litert.urllib.request, "urlopen", opening)
    destination = tmp_path / "lib/runtime.so"
    destination.parent.mkdir()
    destination.write_bytes(b"existing verified library")
    monkeypatch.setattr(sys, "argv", ["extract", str(destination)])
    if failure:
        with pytest.raises((ValueError, RuntimeError)):
            litert.main()
        assert destination.read_bytes() == b"existing verified library"
    else:
        litert.main()
        assert destination.read_bytes() == b"native bytes"
        assert not list(tmp_path.rglob("*.py"))
        assert not destination.with_suffix(".part").exists()
    if failure == "transport":
        opening.assert_not_called()
    else:
        assert opening.call_args.kwargs["timeout"] == 120


@pytest.mark.parametrize(
    "requirements,passed",
    [
        ("GLIBC_2.39 GLIBC_2.9 GLIBCXX_3.4.33", True),
        ("GLIBC_2.40", False),
        ("GLIBCXX_3.4.34", False),
        ("", True),
    ],
)
def test_abi_audit_compares_required_versions_numerically_and_retains_report(
    tmp_path, monkeypatch, requirements, passed
):
    spec = importlib.util.spec_from_file_location(
        "abi_audit_under_test",
        Path(__file__).resolve().parents[1] / "packaging/check_abi.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    elf = tmp_path / "runtime"
    elf.write_bytes(b"\x7fELFfixture")
    (tmp_path / "alias").symlink_to(elf)
    (tmp_path / "text").write_text("not ELF")
    monkeypatch.setattr(
        module.subprocess,
        "check_output",
        lambda *a, **kw: "GLIBC_9999\nVersion needs section\n" + requirements,
    )
    report = module.inspect(tmp_path, "2.39")
    assert report["passed"] is passed
    assert len(report["files"]) == 1
    if "GLIBC_2.39" in requirements:
        assert report["files"][0]["GLIBC"] == "2.39"
    destination = tmp_path / "reports/abi.json"
    monkeypatch.setattr(
        sys, "argv", ["abi", str(tmp_path), "--report", str(destination)]
    )
    if passed:
        module.main()
    else:
        with pytest.raises(SystemExit, match="exceeds"):
            module.main()
    assert json.loads(destination.read_text()) == report
    elf.unlink()
    assert module.inspect(tmp_path, "2.39")["failures"] == [
        "No ELF files found; refusing an empty compatibility audit"
    ]
