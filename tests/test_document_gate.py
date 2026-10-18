"""CI document prerequisites cannot silently turn into a skip."""

import importlib.util
from pathlib import Path
from unittest.mock import patch

import pytest


def test_ci_document_prerequisites_fail_instead_of_skip(monkeypatch):
    path = Path(__file__).parent / "integration/test_linux_documents.py"
    spec = importlib.util.spec_from_file_location("document_gate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("CI", "true")
    with patch.object(module.shutil, "which", return_value=None):
        with pytest.raises(AssertionError, match="prerequisites missing"):
            module.LinuxDocumentImportTest().test_shipped_parser_imports_pdf_and_rtf_when_tools_exist()
