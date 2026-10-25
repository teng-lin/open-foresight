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


def test_every_public_native_export_has_the_shared_outer_exception_boundary():
    header = (ROOT / "native/foresight_native.h").read_text()
    source = "\n".join(
        (ROOT / path).read_text()
        for path in ("native/foresight_native.cpp", "native/owned_exports.h")
    )
    declared = set(re.findall(r"\b(fs_\w+)\s*\([^;{}]*\)\s*;", header))
    definitions = {}
    for match in re.finditer(
        r'(?m)^(?:extern "C" )?(?:void\s*\*|char\s*\*|void|int|double|size_t|uint64_t)\s*(fs_\w+)\s*\([^;{}]*\)\s*\{',
        source,
    ):
        definitions[match[1]] = _body(source, match.end() - 1).strip()
    assert declared == definitions.keys()
    for name, body in definitions.items():
        if name == "fs_lifetime_version":
            assert body == "return 2;"  # Explicitly nonthrowing scalar capability.
        else:
            assert body.startswith(
                ("return foresight::ffi_barrier(", "foresight::ffi_barrier_void(")
            ), name


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
