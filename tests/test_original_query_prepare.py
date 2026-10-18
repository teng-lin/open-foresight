"""Pure preparation guards; never copy/load the original application."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "oracle_prepare",
    Path(__file__).resolve().parents[1] / "tools/original_query_oracle/prepare.py",
)
if spec is None or spec.loader is None:
    raise RuntimeError("Packaged module has no loader")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PreparationTest(unittest.TestCase):
    def fixture(self):
        pagezero = struct.pack(
            "<II16sQQQQiiII", 0x19, 72, b"__PAGEZERO", 0, 0x100000000, 0, 0, 0, 0, 0, 0
        )
        commands = (
            pagezero
            + struct.pack("<IIQQ", 0x80000028, 24, 1234, 0)
            + struct.pack("<II", 0xE, 8)
            + struct.pack("<II", 0x1B, 8)
        )
        header = struct.pack(
            "<8I", 0xFEEDFACF, 0x100000C, 0, 2, 4, len(commands), 0x200001, 0
        )
        return header + commands + b"original-code-unchanged"

    def test_owned_conversion_preserves_code_and_compacts_only_header(self):
        data = self.fixture()
        converted = module.bundle_copy(data)
        self.assertEqual(len(converted), len(data))
        self.assertEqual(converted[-23:], data[-23:])
        header = struct.unpack_from("<8I", converted)
        self.assertEqual(header[3:7], (8, 1, 8, 1))
        self.assertEqual(converted[32:40], struct.pack("<II", 0x1B, 8))
        self.assertTrue(all(value == 0 for value in converted[40:-23]))

    def test_rejects_wrong_image_type_before_conversion(self):
        data = bytearray(self.fixture())
        struct.pack_into("<I", data, 12, 6)
        with self.assertRaisesRegex(ValueError, "MH_EXECUTE"):
            module.bundle_copy(data)

    def test_private_root_rejects_original_path_before_writing(self):
        with self.assertRaisesRegex(ValueError, "original application"):
            module.private_root(module.APP / "oracle-must-not-be-created")
        self.assertFalse((module.APP / "oracle-must-not-be-created").exists())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            root.mkdir(mode=0o755)
            with self.assertRaisesRegex(ValueError, "0700"):
                module.private_root(root)
            link = Path(directory) / "link"
            link.symlink_to(root)
            with self.assertRaisesRegex(ValueError, "symlink"):
                module.private_root(link)

    def test_environment_has_no_user_credentials_or_home_override(self):
        value = module.environment(Path("/private/task"))
        self.assertNotIn("HOME", value)
        self.assertEqual(set(value), {"TMPDIR", "CFFIXED_USER_HOME", "PATH", "LANG"})


def uleb(value):
    result = bytearray()
    while True:
        byte = value & 127
        value >>= 7
        result.append(byte | (128 if value else 0))
        if not value:
            return bytes(result)


def sleb(value):
    result = bytearray()
    while True:
        byte = value & 127
        value >>= 7
        done = (value == 0 and not byte & 64) or (value == -1 and byte & 64)
        result.append(byte | (0 if done else 128))
        if done:
            return bytes(result)


class FixupTest(unittest.TestCase):
    segments = [
        {"vmsize": 0x100000000, "initprot": 0},
        {"vmsize": 0x1000, "initprot": 5},
        {"vmsize": 0x1000, "initprot": 3},
        {"vmsize": 0x1000, "initprot": 3},
    ]

    def test_variable_integers_signed_unsigned_limits_and_payload_positions(self):
        for value in [0, 127, 128, 0x7273, (1 << 64) - 1]:
            data = uleb(value)
            self.assertEqual(module._fixups.leb(data, 0), (value, len(data)))
        for value in [0, -1, -12345, -(1 << 63), (1 << 63) - 1]:
            data = sleb(value)
            self.assertEqual(module._fixups.leb(data, 0, True), (value, len(data)))
        for data in [b"\x80", b"\x80" * 10, b"\xff" * 9 + b"\x02"]:
            with self.assertRaises(ValueError):
                module._fixups.leb(data, 0)

    def test_rebase_changes_only_segment_opcodes_not_uleb_payloads(self):
        first = (
            b"\x11\x22" + uleb(0x123) + b"\x52\x30" + uleb(0x22) + b"\x70" + uleb(0x20)
        )
        second = b"\x23" + uleb(0x30) + b"\x80" + uleb(2) + uleb(0x23) + b"\0"
        data = first + second
        expected = bytearray(data)
        expected[1] = 0x21
        expected[len(first)] = 0x22
        result, changes = module._fixups.remap_stream(data, "rebase", self.segments)
        self.assertEqual(changes, 2)
        self.assertEqual(result, expected)

    def test_32bit_fixups_still_use_64bit_image_pointer_stride(self):
        segments = [*self.segments[:2], {"vmsize": 12, "initprot": 3}]
        result, count = module._fixups.remap_stream(
            b"\x12\x22\x00\x52\0", "rebase", segments
        )
        self.assertEqual(result, b"\x12\x21\x00\x52\0")
        self.assertEqual(count, 1)
        segments[2] = {"vmsize": 10, "initprot": 3}
        with self.assertRaisesRegex(ValueError, "bounds"):
            module._fixups.remap_stream(b"\x12\x22\x00\x52\0", "rebase", segments)

    def test_all_bind_forms_preserve_symbol_addends_and_wrapped_backward_offsets(self):
        first = (
            b"\x20" + uleb(0x7273) + b"\x40_symbol\x72\x73\x22\0\x51\x60" + sleb(-12345)
        )
        select = b"\x72" + uleb(0x123)
        rest = b"\x90\x80" + uleb((1 << 64) - 8) + b"\x90\xa0\x08\xb1\xc0\x02\x10\0"
        data = first + select + rest
        expected = bytearray(data)
        expected[len(first)] = 0x71
        for kind in ["bind", "weak", "lazy"]:
            result, changes = module._fixups.remap_stream(data, kind, self.segments)
            self.assertEqual(changes, 1)
            self.assertEqual(result, expected)
        lazy = b"\x40_a\0\x72\x00\x90\0\x40_b\0\x73\x10\x90\0"
        result, changes = module._fixups.remap_stream(lazy, "lazy", self.segments)
        self.assertEqual(changes, 2)
        self.assertEqual(result, b"\x40_a\0\x71\x00\x90\0\x40_b\0\x72\x10\x90\0")

    def test_rejects_malformed_unsupported_and_invalid_target_rebases(self):
        cases = [
            b"\x22\x80",
            b"\x22" + b"\x80" * 10,
            b"\x20\x00\x51\0",
            b"\x24\x00\x51\0",
            b"\x22\xff\x7f\x51\0",
            b"\x21\x00\x51\0",
            b"\x51\0",
            b"\x22\x00\x51",
            b"\x22\x00\x51\0\x22",
            b"\xf0",
            b"\x22\x00\x61\x00\0",
            b"\x22\x00\x80" + uleb((1 << 64) - 1) + b"\x08\0",
        ]
        for data in cases:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    module._fixups.remap_stream(data, "rebase", self.segments)
        for data in [
            b"\x72\0\x90\0",
            b"\x40_unterminated",
            b"\xd0\x01\0",
            b"\x40_a\0\x70\0\x90\0",
            b"\x40_a\0\x72\0\x91\0",
            b"\x40_a\0\x72\0\x60" + b"\x80" * 10,
        ]:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    module._fixups.remap_stream(data, "bind", self.segments)

    def test_converter_rejects_other_fixup_formats_and_bad_commands(self):
        fixture = PreparationTest().fixture()
        command_end = 32 + struct.unpack_from("<I", fixture, 20)[0]
        for command in [
            struct.pack("<4I", 0x80000034, 16, 0, 0),
            struct.pack("<4I", 0x1E, 16, 0, 1),
        ]:
            data = bytearray(fixture[:command_end] + command + fixture[command_end:])
            struct.pack_into("<II", data, 16, 5, command_end - 32 + len(command))
            with self.assertRaises(ValueError):
                module.bundle_copy(data)
        for data in [b"", fixture[:40]]:
            with self.assertRaises(ValueError):
                module.bundle_copy(data)


if __name__ == "__main__":
    unittest.main()
