"""Release credential validation and literal shell transport (dummy values only)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from package_macos import write_runtime
from web_search_release import KEYS, release_web_search_keys, shell_web_search_keys


class WebSearchReleaseTest(unittest.TestCase):
    def test_disabled_and_partial_release(self):
        self.assertEqual(release_web_search_keys({}), {})
        for key in KEYS:
            with self.assertRaises(ValueError):
                release_web_search_keys({key: 'dummy-value'})

    def test_credentials_are_literal_in_shell_and_macos_runtime(self):
        values = dict(zip(KEYS, ["dummy ' \" $HOME $(exit 9) `exit 8`\nline", 'dummy-summary']))
        script = shell_web_search_keys(release_web_search_keys(values))
        script += '\nexec "$1" -c "$2"'
        probe = 'import json, os; print(json.dumps([os.environ[k] for k in ' + repr(KEYS) + ']))'
        output = subprocess.check_output(['bash', '-c', script, 'fixture', sys.executable, probe], text=True)
        self.assertEqual(json.loads(output), list(values.values()))
        with tempfile.TemporaryDirectory() as directory:
            resources = Path(directory) / 'App Resources'
            write_runtime(resources, {**values, 'FORESIGHT_HELPER': resources / 'bin/helper'})
            config = json.loads((resources / 'runtime.json').read_text())
            self.assertEqual({key: config[key] for key in KEYS}, values)
            self.assertEqual(config['FORESIGHT_HELPER'], 'bin/helper')


if __name__ == '__main__':
    unittest.main()
