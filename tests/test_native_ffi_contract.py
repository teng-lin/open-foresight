"""Keep the public native exception/ABI contract complete as consumers grow."""

from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1]
_TOKENS = re.compile(
    r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', re.S
)


def _body(source: str, opening: int) -> str:
    depth = 0
    for token in _TOKENS.finditer(source, opening):
        if token.group() == "{":
            depth += 1
        elif token.group() == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : token.start()]
    raise AssertionError("Unclosed exported native function")


def _export_sources(root: Path) -> str:
    """Follow actual local includes so additive ABI modules cannot go unseen."""
    native = (root / "native").resolve()
    pending = [native / "foresight_native.cpp"]
    sources: dict[Path, str] = {}
    while pending:
        path = pending.pop()
        if path in sources:
            continue
        text = path.read_text()
        sources[path] = text
        for name in re.findall(r'^\s*#include\s+"([^"\n]+)"', text, re.M):
            included = (path.parent / name).resolve()
            if included.is_relative_to(native) and included.is_file():
                pending.append(included)
    return "\n".join(sources.values())


def _check_exports(root: Path) -> set[str]:
    header = (root / "native/foresight_native.h").read_text()
    source = _export_sources(root)
    declared = set(re.findall(r"\b(fs_\w+)\s*\([^;{}]*\)\s*;", header))
    definitions = {}
    for match in re.finditer(
        r'(?m)^(?:extern "C" )?(?:void\s*\*|char\s*\*|void|int|double|size_t|u?int64_t)\s*(fs_\w+)\s*\([^;{}]*\)\s*\{',
        source,
    ):
        assert match[1] not in definitions, f"Duplicate native export: {match[1]}"
        definitions[match[1]] = _body(source, match.end() - 1).strip()
    assert declared == definitions.keys()
    for name, body in definitions.items():
        scalar_capabilities = {"fs_lifetime_version": 2, "fs_pcm_output_version": 1}
        if name in scalar_capabilities:
            # Closed literal-only capabilities cannot allocate or throw.
            assert body == f"return {scalar_capabilities[name]};"
        else:
            assert body.startswith(
                ("return foresight::ffi_barrier(", "foresight::ffi_barrier_void(")
            ), name
    return declared


def test_every_public_native_export_has_the_shared_outer_exception_boundary():
    exports = _check_exports(ROOT)
    assert {
        "fs_owned_media_input_reply",
        "fs_owned_pcm_output_push",
        "fs_recording_monotonic_us",
    } <= exports


def test_nested_additive_exports_remain_subject_to_the_boundary(tmp_path):
    native = tmp_path / "native"
    native.mkdir()
    (native / "foresight_native.h").write_text("int64_t fs_added();\n")
    (native / "foresight_native.cpp").write_text('#include "owned_exports.h"\n')
    (native / "owned_exports.h").write_text('#include "nested_exports.h"\n')
    module = native / "nested_exports.h"
    module.write_text(
        "int64_t fs_added() { return foresight::ffi_barrier([] {return 1;}, -1); }\n"
    )
    assert _check_exports(tmp_path) == {"fs_added"}
    module.write_text("int64_t fs_added() { return 1; }\n")
    with pytest.raises(AssertionError, match="fs_added"):
        _check_exports(tmp_path)
    module.write_text("")
    with pytest.raises(AssertionError):
        _check_exports(tmp_path)


def test_duplicate_additive_definition_is_rejected(tmp_path):
    native = tmp_path / "native"
    native.mkdir()
    (native / "foresight_native.h").write_text("int fs_added();\n")
    (native / "foresight_native.cpp").write_text(
        '#include "extra.h"\nint fs_added() { return 1; }\n'
    )
    (native / "extra.h").write_text("int fs_added() { return 2; }\n")
    with pytest.raises(AssertionError, match="Duplicate native export"):
        _check_exports(tmp_path)


@pytest.mark.parametrize("version", [None, 2])
def test_python_loader_rejects_abi_before_resolving_other_native_symbols(
    monkeypatch, version
):
    # This direct-script consumer is intentionally retained as a native contract
    # adapter. Importing it does not load a library or invoke a helper.
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "native_contract_loader", ROOT / "tests/integration/test_native.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    queried = []

    class Version:
        def __call__(self):
            return version

    class Library:
        def __getattr__(self, name):
            queried.append(name)
            assert name == "fs_abi_version", (
                "Dependent symbol resolved before ABI acceptance"
            )
            if version is None:
                raise AttributeError(name)
            return Version()

    monkeypatch.setattr(module.C, "CDLL", lambda _: Library())
    with pytest.raises(RuntimeError, match="Incompatible native ABI"):
        module.load("unused-owned-fixture")
    assert queried == ["fs_abi_version"]
