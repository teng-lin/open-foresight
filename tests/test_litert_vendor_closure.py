"""A wheel must carry the dynamic GPU libraries before it is published."""
import hashlib
import importlib.util
from io import BytesIO
from pathlib import Path
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import litert_extensions as extensions

spec = importlib.util.spec_from_file_location('closure_builder', ROOT / 'tools/build_litert_extensions.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class VendorClosureTest(unittest.TestCase):
    def wheel(self, system, *, omitted=None, replacement=None):
        names = (extensions.MACOS_VENDOR_LIBRARIES if system == 'Darwin'
                 else extensions.LINUX_VENDOR_LIBRARIES)
        data = BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            for name in names:
                if name != omitted:
                    payload = replacement if replacement is not None else name.encode()
                    archive.writestr('litert_lm/' + name, payload)
        return zipfile.ZipFile(data)

    def test_complete_platform_closure_is_hashed_for_the_release_manifest(self):
        for system, names in (('Darwin', extensions.MACOS_VENDOR_LIBRARIES),
                              ('Linux', extensions.LINUX_VENDOR_LIBRARIES)):
            with self.subTest(system=system), self.wheel(system) as archive:
                hashes = builder.wheel_vendor_hashes(archive, system)
                self.assertEqual(set(hashes), set(names))
                for name in names:
                    self.assertEqual(hashes[name], hashlib.sha256(name.encode()).hexdigest())

    def test_missing_dawn_or_metal_stops_publication(self):
        for system, name in (('Linux', 'libwebgpu_dawn.so'),
                             ('Darwin', 'libwebgpu_dawn.dylib'),
                             ('Darwin', 'libLiteRtMetalAccelerator.dylib'),
                             ('Darwin', 'libLiteRtTopKMetalSampler.dylib')):
            with self.subTest(system=system, name=name), self.wheel(system, omitted=name) as archive:
                with self.assertRaisesRegex(RuntimeError, 'required GPU runtime dependency'):
                    builder.wheel_vendor_hashes(archive, system)

    def test_empty_payload_or_lfs_pointer_stops_publication(self):
        for payload in (b'', b'version https://git-lfs.github.com/spec/v1\noid sha256:fixture\n'):
            with self.subTest(payload=payload), self.wheel('Darwin', replacement=payload) as archive:
                with self.assertRaises(RuntimeError):
                    builder.wheel_vendor_hashes(archive, 'Darwin')


if __name__ == '__main__':
    unittest.main()
