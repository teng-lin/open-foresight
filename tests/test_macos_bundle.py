"""Exercise actual Mach-O relocation with transitive libraries and spaced paths."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from macos_bundle import audit_dependencies, relocate_dependencies, sign_application


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'requires Mac toolchain')
class MacBundleTest(unittest.TestCase):
    def test_transitive_dependencies_survive_relocation_without_environment(self):
        with tempfile.TemporaryDirectory(prefix='foresight-mach-o-') as folder:
            root = Path(folder)
            source = root / 'development-only'
            source.mkdir()
            (source / 'base.c').write_text('int base(void) { return 40; }\n')
            (source / 'middle.c').write_text('extern int base(void); int middle(void) { return base()+2; }\n')
            (source / 'main.c').write_text('#include <stdio.h>\nextern int middle(void); int main(void) { printf("%d\\n", middle()); }\n')
            base, middle = source / 'libbase.dylib', source / 'libmiddle.dylib'
            common = ['clang', '-arch', 'arm64', '-mmacosx-version-min=15.0', '-Wl,-headerpad_max_install_names']
            subprocess.run([*common, '-dynamiclib', str(source / 'base.c'), '-Wl,-install_name,' + str(base), '-o', str(base)], check=True)
            subprocess.run([*common, '-dynamiclib', str(source / 'middle.c'), str(base), '-Wl,-install_name,' + str(middle), '-o', str(middle)], check=True)
            app = root / 'Open Foresight.app'
            executable = app / 'Contents/Library/Services/Service.app/Contents/MacOS/service'
            executable.parent.mkdir(parents=True)
            subprocess.run([*common, str(source / 'main.c'), str(middle), '-o', str(executable)], check=True)
            relocate_dependencies(app)
            self.assertEqual(len(audit_dependencies(app)), 3)
            # Ad-hoc re-signing is needed after changing arm64 Mach-O load commands.
            for binary in app.rglob('*'):
                if binary.is_file():
                    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)
            shutil.rmtree(source)
            moved = root / 'relocated path with spaces/Example.app'
            moved.parent.mkdir()
            app.rename(moved)
            actual = moved / executable.relative_to(app)
            output = subprocess.check_output([str(actual)], cwd='/', env={'PATH': '/usr/bin:/bin'}, text=True)
            self.assertEqual(output.strip(), '42')
            self.assertEqual(len(audit_dependencies(moved)), 3)

    def test_missing_dependency_is_rejected(self):
        from macos_bundle import resolve_dependency
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Example.app'
            with self.assertRaisesRegex(ValueError, 'Unresolved dependency'):
                resolve_dependency('/missing/foresight-test.dylib', app / 'Contents/MacOS/app', app)

    def test_newer_os_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Example.app'
            binary = app / 'Contents/Resources/lib/libnew.dylib'
            binary.parent.mkdir(parents=True)
            source = Path(folder) / 'new.c'
            source.write_text('int example(void) { return 1; }\n')
            subprocess.run(['clang', '-arch', 'arm64', '-mmacosx-version-min=26.0',
                            '-dynamiclib', str(source), '-o', str(binary)], check=True)
            with self.assertRaisesRegex(ValueError, 'above supported 15.0'):
                audit_dependencies(app)


if __name__ == '__main__':
    unittest.main()
