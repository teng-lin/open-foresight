"""Release Google registration validation, override precedence and privacy."""

from typing import Any

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from google_client_release import (  # noqa: E402
    SECRET_NAME,
    release_google_client,
    write_google_client,
)


CLIENT = {
    "installed": {
        "client_id": "123-fixture.apps.googleusercontent.com",
        "client_secret": "fixture-application-secret",
    }
}


class GoogleClientReleaseTest(unittest.TestCase):
    def test_release_requires_application_registration(self):
        self.assertIsNone(release_google_client(environment={}))
        with self.assertRaisesRegex(ValueError, "Google sign-in releases require"):
            release_google_client(environment={}, required=True)
        self.assertEqual(
            release_google_client(
                environment={SECRET_NAME: json.dumps(CLIENT)}, required=True
            ),
            CLIENT,
        )

    def test_explicit_file_wins_and_packaging_strips_console_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "client.json"
            source.write_text(
                json.dumps(
                    {
                        "installed": {
                            **CLIENT["installed"],
                            "project_id": "fixture-project",
                            "redirect_uris": ["http://localhost"],
                        }
                    }
                )
            )
            configuration = release_google_client(
                source, {SECRET_NAME: "invalid environment override"}
            )
            destination = Path(directory) / "bundled.json"
            write_google_client(destination, configuration)
            self.assertEqual(json.loads(destination.read_text()), CLIENT)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_account_tokens_and_invalid_clients_are_rejected_without_echo(self):
        invalid: Any = [
            None,
            [],
            {},
            {"web": CLIENT["installed"]},
            {"installed": []},
            {"installed": {"client_id": 5}},
            {"installed": {**CLIENT["installed"], "client_secret": 5}},
            {**CLIENT, "access_token": "private-account-token"},
            {
                "installed": {
                    **CLIENT["installed"],
                    "refresh_token": "private-account-token",
                }
            },
        ]
        for value in invalid:
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(ValueError) as error:
                    release_google_client(environment={SECRET_NAME: json.dumps(value)})
                self.assertNotIn("private-account-token", str(error.exception))
                self.assertNotIn("fixture-application-secret", str(error.exception))
        with self.assertRaises(ValueError) as error:
            release_google_client(environment={SECRET_NAME: "{private-account-token"})
        self.assertNotIn("private-account-token", str(error.exception))

    def test_packagers_reject_unconfigured_release_before_building(self):
        root = Path(__file__).resolve().parents[1] / "tools"
        for script in ("package.py", "package_macos.py"):
            result = subprocess.run(
                [sys.executable, str(root / script), "--require-google-client"]
                + (
                    ["--litert-extensions-manifest", "/nonexistent/fixture.json"]
                    if script == "package_macos.py"
                    else []
                ),
                env={SECRET_NAME: ""},
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Google sign-in releases require", result.stderr)


if __name__ == "__main__":
    unittest.main()
