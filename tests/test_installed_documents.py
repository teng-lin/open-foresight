"""Installed-document acceptance must reject a successful RPC with wrong text."""

import ast
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from installed_documents import import_document_fixtures  # noqa: E402


class DocumentPeer:
    def __init__(self, *, wrong=False, index_error=False, adapter="Linux"):
        self.sources = {}
        self.calls = []
        self.wrong = wrong
        self.index_error = index_error
        self.adapter = adapter

    def call(self, method, args=None):
        self.calls.append((method, args))
        if method == "security.allow_import_root":
            assert Path(args["path"]).is_dir()
            return True
        if method == "sources.list":
            return list(self.sources.values())
        if method == "sources.import_file":
            path = Path(args["path"])
            kind = path.suffix[1:]
            if kind == "pdf":
                assert path.read_bytes().startswith(b"%PDF-1.4\n")
                text = "Installed PDF cobalt launch."
                parser = "pdftotext -layout"
            else:
                assert path.read_text().startswith(r"{\rtf1\ansi")
                text = "Installed RTF amber action."
                parser = "unrtf --text"
            self.sources[kind] = {
                "id": kind,
                "content": "corrupt extraction" if self.wrong else text + "\n\f",
                "source_uri": path.resolve().as_uri(),
                "provenance": f"{parser} ({self.adapter} adapter); {path}",
                "state": "failed" if self.index_error else "indexed",
            }
            if self.index_error:
                raise RuntimeError("No embedding model configured")
            return {"id": kind}
        if method == "sources.get":
            return self.sources[args["id"]]
        raise AssertionError(method)


def test_document_acceptance_imports_both_real_formats_and_checks_saved_text(tmp_path):
    peer = DocumentPeer()
    result = import_document_fixtures(peer, tmp_path / "docs")
    assert set(result) == {"pdf", "rtf"}
    assert all(item["status"] == "passed" for item in result.values())
    assert [call[0] for call in peer.calls].count("sources.import_file") == 2


def test_no_model_index_failure_is_distinct_from_extraction_failure(tmp_path):
    result = import_document_fixtures(
        DocumentPeer(index_error=True), tmp_path / "documents"
    )
    assert all(item["indexing"] == "not_established" for item in result.values())


@pytest.mark.parametrize("failure", ["text", "adapter"])
def test_successful_import_rpc_does_not_certify_invalid_extraction(tmp_path, failure):
    peer = DocumentPeer(wrong=failure == "text", adapter="unexpected")
    with pytest.raises(AssertionError, match="extracted|unexpected parser"):
        import_document_fixtures(peer, tmp_path / "documents")


def test_generated_pdf_contains_selectable_expected_text(tmp_path):
    extractor = shutil.which("pdftotext")
    if extractor is None:
        pytest.skip(
            "Fixture-format check requires Poppler; installed acceptance requires it"
        )
    peer = DocumentPeer()
    import_document_fixtures(peer, tmp_path / "documents")
    result = subprocess.run(
        [
            extractor,
            "-layout",
            str(tmp_path / "documents/Document With Spaces.pdf"),
            "-",
        ],
        check=True,
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert " ".join(result.stdout.split()) == "Installed PDF cobalt launch."


def test_installer_standard_and_full_paths_require_document_probe():
    for path, argument in [
        ("packaging/smoke_installed.py", "root"),
        ("tools/test_installed_release.py", "bundle"),
        ("tools/test_release_dmg.py", "destination"),
    ]:
        calls = [
            node
            for node in ast.walk(ast.parse((ROOT / path).read_text()))
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "probe_installed_documents"
        ]
        assert any(
            call.args
            and isinstance(call.args[0], ast.Name)
            and call.args[0].id == argument
            for call in calls
        ), path
