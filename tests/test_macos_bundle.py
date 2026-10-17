"""Exercise actual Mach-O relocation with transitive libraries and spaced paths."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from macos_bundle import audit_dependencies, relocate_dependencies, sign_application


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'requires Mac toolchain')
class MacBundleTest(unittest.TestCase):
    def test_missing_private_rpath_library_is_not_invented_in_system_swift_directory(self):
        from macos_bundle import resolve_dependency, shared_cache_library
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Example.app'
            owner = app / 'Contents/Resources/python/site-packages/litert_lm/libplugin.dylib'
            name = '@rpath/libwebgpu_dawn.dylib'
            with patch('macos_bundle.rpaths', return_value=['/usr/lib/swift']):
                with self.assertRaisesRegex(ValueError, 'Unresolved dependency'):
                    resolve_dependency(name, owner, app)
                sibling = owner.parent / 'libwebgpu_dawn.dylib'
                sibling.parent.mkdir(parents=True)
                sibling.write_bytes(b'pinned sibling fixture')
                with self.assertRaisesRegex(ValueError, 'Unresolved dependency'):
                    resolve_dependency(name, owner, app)
                self.assertEqual(resolve_dependency(name, owner, app, allow_colocated=True), sibling.resolve())
            self.assertTrue(shared_cache_library(Path('/usr/lib/swift/libswiftCore.dylib')))
            self.assertFalse(shared_cache_library(Path('/usr/lib/swift/libwebgpu_dawn.dylib')))
            self.assertEqual(resolve_dependency('/usr/lib/libSystem.B.dylib', owner, app),
                             Path('/usr/lib/libSystem.B.dylib'))

    def test_bare_gpu_plugin_and_transitive_dependency_load_after_relocation(self):
        with tempfile.TemporaryDirectory(prefix='foresight-plugin-') as folder:
            root = Path(folder)
            source = root / 'source'
            source.mkdir()
            (source / 'dawn.c').write_text('int dawn(void) { return 40; }\n')
            (source / 'plugin.c').write_text('extern int dawn(void); int plugin(void) { return dawn()+2; }\n')
            (source / 'parent.c').write_text('#include <dlfcn.h>\nint probe(void) { void* h=dlopen("libplugin.dylib", RTLD_NOW|RTLD_LOCAL); if(!h)return -1; int(*f)(void)=(int(*)(void))dlsym(h,"plugin"); return f ? f() : -2; }\n')
            app = root / 'Original.app'
            libs = app / 'Contents/Resources/python/lib/python3.13/site-packages/litert_lm'
            libs.mkdir(parents=True)
            common = ['clang', '-arch', 'arm64', '-mmacosx-version-min=15.0',
                      '-dynamiclib', '-Wl,-headerpad_max_install_names']
            dawn, plugin, parent = (libs / name for name in
                                    ('libdawn.dylib', 'libplugin.dylib', 'libparent.dylib'))
            subprocess.run([*common, str(source / 'dawn.c'), '-o', str(dawn),
                            '-Wl,-install_name,@rpath/libdawn.dylib'], check=True)
            subprocess.run([*common, str(source / 'plugin.c'), str(dawn), '-o', str(plugin),
                            '-Wl,-install_name,@rpath/libplugin.dylib', '-Wl,-rpath,/usr/lib/swift'], check=True)
            subprocess.run([*common, str(source / 'parent.c'), '-o', str(parent),
                            '-Wl,-install_name,@rpath/libparent.dylib', '-Wl,-rpath,@loader_path'], check=True)
            relocate_dependencies(app)
            self.assertEqual(len(audit_dependencies(app)), 3)
            for binary in (dawn, plugin, parent):
                subprocess.run(['codesign', '--force', '--sign', '-', str(binary)],
                               check=True, capture_output=True)
            moved = root / 'a path with spaces/Relocated.app'
            moved.parent.mkdir()
            app.rename(moved)
            shutil.rmtree(source)
            code = ('import ctypes,sys; lib=ctypes.CDLL(sys.argv[1]); '
                    'lib.probe.restype=ctypes.c_int; print(lib.probe())')
            output = subprocess.check_output([sys.executable, '-I', '-c', code,
                str(moved / parent.relative_to(app))], cwd='/', env={'PATH': '/usr/bin:/bin'},
                text=True, timeout=15)
            self.assertEqual(output.strip(), '42')

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
