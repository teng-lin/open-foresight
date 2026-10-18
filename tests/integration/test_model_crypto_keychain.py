"""Opt-in persistence check for the signed production helper's Keychain API.

Only a unique fixture service is used. This does not test a Developer ID signed
application bundle, and never reads/deletes the production or original entry.
"""

import os
from pathlib import Path
import platform
import stat
import subprocess
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_SERVICE = "com.openforesight.encryption"
ACCOUNT = "dataEncryptionKey"


@unittest.skipUnless(
    os.environ.get("FORESIGHT_MODEL_CRYPTO_KEYCHAIN_TEST") == "1"
    and platform.system() == "Darwin"
    and platform.machine() == "arm64",
    "Requires explicit opt-in on an arm64 Mac; uses only a unique fixture Keychain service",
)
class ModelCryptoKeychainPersistenceTest(unittest.TestCase):
    def command(self, arguments, *, success=True, timeout=120):
        # Captured output is deliberately omitted from assertions: neither a
        # helper regression nor a tool failure should print cryptographic data.
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        if success:
            self.assertEqual(result.returncode, 0, "Fixture command failed")
        else:
            self.assertNotEqual(
                result.returncode, 0, "Fixture command unexpectedly succeeded"
            )
        return result

    def test_separate_processes_share_only_the_fixture_key(self):
        service = f"{PRODUCTION_SERVICE}.test.{uuid.uuid4().hex}"
        self.assertTrue(service.startswith(PRODUCTION_SERVICE + ".test."))
        self.assertNotEqual(service, PRODUCTION_SERVICE)
        with tempfile.TemporaryDirectory(
            prefix="foresight-model-keychain-"
        ) as temporary:
            directory = Path(temporary)
            directory.chmod(0o700)
            source = (ROOT / "native/model_crypto.swift").read_text()
            original_literal = f'private let keychainService = "{PRODUCTION_SERVICE}"'
            self.assertEqual(
                source.count(original_literal),
                1,
                "The production service declaration must match exactly once",
            )
            fixture_source = source.replace(
                original_literal,
                f'private let keychainService = "{service}"',
                1,
            )
            self.assertEqual(fixture_source.count(service), 1)
            self.assertTrue(
                fixture_source.replace(service, PRODUCTION_SERVICE, 1) == source,
                "The fixture must change only the service literal",
            )
            swift = directory / "model_crypto.swift"
            swift.write_text(fixture_source)
            swift.chmod(0o600)
            helper = directory / "foresight-model-crypto-fixture"
            try:
                self.command(
                    [
                        "/usr/bin/xcrun",
                        "swiftc",
                        "-O",
                        "-target",
                        "arm64-apple-macosx15.0",
                        str(swift),
                        "-o",
                        str(helper),
                    ]
                )
                self.command(
                    [
                        "/usr/bin/codesign",
                        "--force",
                        "--sign",
                        "-",
                        "--identifier",
                        "com.openforesight.model-crypto.keychain-fixture",
                        str(helper),
                    ]
                )
                self.command(["/usr/bin/codesign", "--verify", "--strict", str(helper)])
                plain = directory / "fixture.bin"
                payload = b"Nonsecret model encryption persistence fixture.\n"
                plain.write_bytes(payload)
                plain.chmod(0o600)

                def invoke(operation, input_path, output_path, *, success=True):
                    return self.command(
                        [
                            str(helper),
                            operation,
                            "--input",
                            str(input_path),
                            "--output",
                            str(output_path),
                        ],
                        success=success,
                        timeout=30,
                    )

                first = directory / "first.enc"
                second = directory / "second.enc"
                restored = directory / "restored.bin"
                invoke("encrypt", plain, first)
                invoke("decrypt", first, restored)
                self.assertTrue(
                    restored.read_bytes() == payload, "Round trip changed fixture bytes"
                )
                invoke("encrypt", plain, second)
                first_bytes, second_bytes = first.read_bytes(), second.read_bytes()
                self.assertEqual(len(first_bytes), len(payload) + 33)
                self.assertEqual(len(second_bytes), len(payload) + 33)
                self.assertTrue(
                    first_bytes[0] == 1 and second_bytes[0] == 1,
                    "Ciphertexts must have Tink prefixes",
                )
                self.assertTrue(
                    first_bytes[:5] == second_bytes[:5],
                    "Separate encrypt processes did not reuse the fixture key ID",
                )
                self.assertTrue(
                    int.from_bytes(first_bytes[1:5], "big") > 0,
                    "Ciphertext key ID must be nonzero",
                )
                self.assertTrue(
                    first_bytes[5:17] != second_bytes[5:17],
                    "Separate encrypt processes reused a nonce",
                )
                first_again = directory / "restored-after-second-encrypt.bin"
                second_restored = directory / "second-restored.bin"
                invoke("decrypt", first, first_again)
                invoke("decrypt", second, second_restored)
                self.assertTrue(
                    first_again.read_bytes() == payload,
                    "A later encrypt changed the stored fixture key",
                )
                self.assertTrue(
                    second_restored.read_bytes() == payload,
                    "The second ciphertext did not round trip",
                )
                for path in (first, second, restored, first_again, second_restored):
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                    self.assertEqual(path.stat().st_uid, os.getuid())

                tampered = directory / "tampered.enc"
                modified = bytearray(first_bytes)
                modified[-1] ^= 1
                tampered.write_bytes(modified)
                rejected = directory / "rejected.bin"
                invoke("decrypt", tampered, rejected, success=False)
                self.assertFalse(
                    rejected.exists(), "Tamper rejection published plaintext"
                )

                existing = directory / "existing.bin"
                existing.write_bytes(b"existing destination must survive")
                invoke("decrypt", first, existing, success=False)
                self.assertTrue(
                    existing.read_bytes() == b"existing destination must survive",
                    "Existing destination was replaced",
                )
                self.assertFalse(
                    list(directory.glob(".foresight-model-crypto-*.tmp")),
                    "An owned temporary file was left behind",
                )
            finally:
                # No broad search/delete, service override, or production-key
                # inspection. Even setup failures clean up only this fixture.
                self.assertTrue(service.startswith(PRODUCTION_SERVICE + ".test."))
                self.assertNotEqual(service, PRODUCTION_SERVICE)
                cleanup = subprocess.run(
                    [
                        "/usr/bin/security",
                        "delete-generic-password",
                        "-s",
                        service,
                        "-a",
                        ACCOUNT,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=30,
                    check=False,
                )
                self.assertIn(
                    cleanup.returncode, (0, 44), "Fixture-only Keychain cleanup failed"
                )


if __name__ == "__main__":
    unittest.main()
