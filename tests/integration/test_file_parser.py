#!/usr/bin/env python3
"""Exercise the actual Mac PDFKit/AppKit extractor with generated documents.

Usage: python3 tests/integration/test_file_parser.py /path/foresight-file-parser
Requires macOS and the SDK for fixture generation; installed-app smoke tests can
reuse the retained fixtures without an SDK.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PARSER = Path(sys.argv.pop(1)).resolve()
TEXT = 'Foresight café Ω — Tuesday 42'
FIXTURE = r'''
import Foundation
import AppKit
import PDFKit
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let text = "Foresight café Ω — Tuesday 42"
let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
try rtf.write(to: root.appendingPathComponent("Unicode ; café.rtf"))
let empty = try NSAttributedString(string: "").data(from: NSRange(location: 0, length: 0),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
try empty.write(to: root.appendingPathComponent("empty.rtf"))
func pdf(_ name: String, _ content: Bool) throws {
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 200)
    let context = CGContext(root.appendingPathComponent(name) as CFURL, mediaBox: &bounds, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    if content { attributed.draw(at: NSPoint(x: 24, y: 120)) }
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
}
try pdf("Unicode ; café.pdf", true)
try pdf("scanned.pdf", false)
let document = PDFDocument(url: root.appendingPathComponent("Unicode ; café.pdf"))!
assert(document.write(to: root.appendingPathComponent("locked.pdf"), withOptions: [
    .userPasswordOption: "private", .ownerPasswordOption: "owner"
]))
'''


@unittest.skipUnless(sys.platform == 'darwin', 'PDFKit/AppKit require macOS')
class FileParserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='foresight parser ; café ')
        cls.root = Path(cls.temporary.name)
        source = cls.root / 'fixtures.swift'
        source.write_text(FIXTURE)
        generator = cls.root / 'generate'
        subprocess.run(['swiftc', str(source), '-o', str(generator)], check=True)
        subprocess.run([str(generator), str(cls.root)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def extract(self, flag, name):
        return subprocess.run([str(PARSER), flag, str(self.root / name)], capture_output=True, text=True)

    def test_real_unicode_pdf_and_rtf_without_shell_path_interpretation(self):
        for flag, name in [('--pdf', 'Unicode ; café.pdf'), ('--rtf', 'Unicode ; café.rtf')]:
            with self.subTest(name=name):
                result = self.extract(flag, name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), TEXT)
                self.assertEqual(result.stderr, '')

    def test_locked_pdf_requires_explicit_unlocked_copy(self):
        result = self.extract('--pdf', 'locked.pdf')
        self.assertEqual(result.returncode, 4)
        self.assertEqual(result.stdout, '')
        self.assertIn('password protected', result.stderr)

    def test_empty_and_image_only_inputs_do_not_silently_import_empty_sources(self):
        for flag, name in [('--pdf', 'scanned.pdf'), ('--rtf', 'empty.rtf')]:
            result = self.extract(flag, name)
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertEqual(result.stdout, '')
        self.assertIn('OCR', self.extract('--pdf', 'scanned.pdf').stderr)

    def test_invalid_missing_and_denied_files_return_actionable_errors(self):
        for flag, name in [('--pdf', 'invalid.pdf'), ('--rtf', 'invalid.rtf')]:
            (self.root / name).write_text('plain text is not this document format')
            result = self.extract(flag, name)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
        missing = self.extract('--pdf', 'missing.pdf')
        self.assertEqual(missing.returncode, 1)
        self.assertIn('Files and Folders', missing.stderr)
        if os.getuid() != 0:
            denied = self.root / 'denied.pdf'
            denied.write_bytes((self.root / 'Unicode ; café.pdf').read_bytes())
            denied.chmod(0)
            try:
                result = self.extract('--pdf', denied.name)
                self.assertEqual(result.returncode, 1)
                self.assertIn('readable copy', result.stderr)
            finally:
                denied.chmod(0o600)

    def test_invalid_arguments_are_stderr_only(self):
        result = subprocess.run([str(PARSER), '--unknown'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertIn('Usage:', result.stderr)


if __name__ == '__main__':
    unittest.main()
