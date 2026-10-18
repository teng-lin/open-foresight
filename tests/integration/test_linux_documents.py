"""Explicit document sandbox gate; prerequisites must exist on CI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxDocumentImportTest(unittest.TestCase):
    def test_shipped_parser_imports_pdf_and_rtf_when_tools_exist(self):
        tool = (ROOT / "packages/foresight_core/tool/import_fixture.dart").read_text()
        self.assertIn("Parser(macOS: false).extract", tool)
        self.assertNotIn("pdftotext", tool)
        self.assertNotIn("unrtf", tool)
        missing = [
            name
            for name in ("pdftotext", "unrtf", "bwrap", "dart")
            if shutil.which(name) is None
        ]
        if missing:
            diagnostic = "PDF/RTF import prerequisites missing: " + ", ".join(missing)
            if (
                os.environ.get("FORESIGHT_REQUIRE_DOCUMENT_SANDBOX") == "1"
                or os.environ.get("CI", "").lower() == "true"
            ):
                self.fail(diagnostic)
            self.skipTest(diagnostic)
        phrase = "Foresight import fixture"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pdf = root / "fixture.pdf"
            rtf = root / "fixture.rtf"
            pdf.write_bytes(_minimal_pdf(phrase))
            rtf.write_bytes(b"{\\rtf1\\ansi\\pard Foresight import fixture\\par}")
            for path, adapter in (
                (pdf, "pdftotext -layout (Linux adapter)"),
                (rtf, "unrtf --text (Linux adapter)"),
            ):
                result = subprocess.run(
                    ["dart", "run", "tool/import_fixture.dart", str(path)],
                    cwd=ROOT / "packages/foresight_core",
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                parsed = json.loads(result.stdout)
                self.assertEqual(parsed["adapter"], adapter)
                self.assertIn(phrase, parsed["text"])
                print(
                    f"Imported {path.name} via shipped Parser.extract ({adapter})",
                    flush=True,
                )


def _minimal_pdf(phrase):
    stream = f"BT /F1 24 Tf 72 120 Td ({phrase}) Tj ET\n".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += (
        f"trailer<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
    ).encode()
    return bytes(out)


if __name__ == "__main__":
    unittest.main()
