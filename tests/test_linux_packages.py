import hashlib
import importlib.util
import json
import re
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "linux_packages", ROOT / "packaging/package_linux.py"
)
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)
spec = importlib.util.spec_from_file_location("abi", ROOT / "packaging/check_abi.py")
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)


class LinuxPackagesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "bundle"
        # Header-only fixtures test staging contracts; real ELF linkage and GUI
        # startup are tested against the compiled artifacts in CI.
        header = bytearray(20)
        header[:4] = b"\x7fELF"
        header[18:20] = (62).to_bytes(2, "little")
        for name in (
            "app/open-foresight",
            "bin/ForesightHelper",
            "lib/libforesight_native.so",
        ):
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(header)
            path.chmod(0o755)
        (self.bundle / "open-foresight").write_text("#!/bin/sh\nexit 0\n")
        (self.bundle / "open-foresight").chmod(0o755)
        icon = self.bundle / "app/data/flutter_assets/assets/images/foresight-logo.png"
        icon.parent.mkdir(parents=True)
        icon.write_bytes(b"fixture icon")
        config = self.bundle / "share/open-foresight/google-client.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"installed":{"client_id":"fixture"}}')
        config.chmod(0o600)
        (self.bundle / "lib/libsqlite3.so").symlink_to("libforesight_native.so")
        self.manifest()

    def manifest(self):
        (self.bundle / "manifest.json").write_text(
            json.dumps(
                {
                    "revision": "a" * 40,
                    "files": [
                        {
                            "path": str(p.relative_to(self.bundle)),
                            "sha256": packages.digest(p),
                        }
                        for p in sorted(self.bundle.rglob("*"))
                        if p.is_file() and p.name != "manifest.json"
                    ],
                }
            )
        )

    def test_system_layout_permissions_and_symlinks(self):
        packages.validate(self.bundle)
        stage = self.root / "stage"
        packages.stage(self.bundle, stage)
        self.assertEqual(
            (stage / "opt/open-foresight/share/open-foresight/google-client.json")
            .stat()
            .st_mode
            & 0o777,
            0o644,
        )
        self.assertEqual(
            (stage / "usr/bin/open-foresight").stat().st_mode & 0o777, 0o755
        )
        self.assertTrue((stage / "opt/open-foresight/lib/libsqlite3.so").is_symlink())
        self.assertEqual(
            (stage / "usr/bin/open-foresight").read_text(),
            '#!/bin/sh\nexec /opt/open-foresight/open-foresight "$@"\n',
        )
        self.assertTrue(
            (stage / "usr/share/applications/io.openforesight.App.desktop").exists()
        )
        self.assertFalse((stage / "home").exists())

    def test_corrupt_extra_account_and_escaping_files_are_rejected(self):
        target = self.bundle / "app/open-foresight"
        target.write_bytes(b"corrupted")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            packages.validate(self.bundle)
        self.setUpFixtureHeader(target)
        extra = self.bundle / "extra"
        extra.write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "absent from its manifest"):
            packages.validate(self.bundle)
        extra.unlink()
        token = self.bundle / "tokens.json"
        token.write_text("fixture")
        self.manifest()
        with self.assertRaisesRegex(ValueError, "Account/profile"):
            packages.validate(self.bundle)
        token.unlink()
        (self.bundle / "escape").symlink_to("/etc/passwd")
        self.manifest()
        with self.assertRaisesRegex(ValueError, "escapes its root"):
            packages.validate(self.bundle)

    @staticmethod
    def setUpFixtureHeader(target):
        header = bytearray(20)
        header[:4] = b"\x7fELF"
        header[18:20] = (62).to_bytes(2, "little")
        target.write_bytes(header)

    def test_archive_is_reproducible_and_preserves_executable_mode(self):
        first, second = self.root / "first.tar.gz", self.root / "second.tar.gz"
        packages.archive(self.bundle, first, "open-foresight", 1234)
        os.utime(self.bundle / "open-foresight", (9999, 9999))
        packages.archive(self.bundle, second, "open-foresight", 1234)
        self.assertEqual(packages.digest(first), packages.digest(second))
        with tarfile.open(first) as tar:
            entry = tar.getmember("open-foresight/open-foresight")
            self.assertEqual((entry.mode, entry.uid, entry.mtime), (0o755, 0, 1234))

    @unittest.skipUnless(
        shutil.which("cmake") and shutil.which("cc"), "CMake and C compiler required"
    )
    def test_minimal_sdk_installs_consumable_export_without_duplicate_library(self):
        source = self.root / "sdk"
        source.mkdir()
        (source / "probe.c").write_text("int probe(void) { return 1; }\n")
        (source / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.19)\nproject(grpc C)\nadd_library(grpc SHARED probe.c)\nadd_library(grpc_unsecure SHARED probe.c)\ninstall(TARGETS grpc EXPORT gRPC LIBRARY DESTINATION lib)\ninstall(TARGETS grpc_unsecure EXPORT gRPC LIBRARY DESTINATION lib)\ninstall(EXPORT gRPC DESTINATION lib/cmake)\n"
        )
        build, prefix = self.root / "build", self.root / "prefix"
        for command in (
            [
                "cmake",
                "-S",
                str(source),
                "-B",
                str(build),
                "-DCMAKE_PROJECT_grpc_INCLUDE="
                + str(ROOT / "packaging/minimal-grpc.cmake"),
                "-DCMAKE_INSTALL_PREFIX=" + str(prefix),
            ],
            ["cmake", "--build", str(build)],
            ["cmake", "--install", str(build)],
        ):
            subprocess.run(
                command, check=True, capture_output=True, text=True, timeout=300
            )
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        self.assertTrue((prefix / f"lib/libgrpc{suffix}").exists())
        self.assertFalse((build / f"libgrpc_unsecure{suffix}").exists())
        self.assertNotIn("grpc_unsecure", (prefix / "lib/cmake/gRPC.cmake").read_text())
        consumer = self.root / "consumer"
        consumer.mkdir()
        (consumer / "main.c").write_text(
            "int probe(void); int main(void) { return probe() != 1; }\n"
        )
        (consumer / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.19)\nproject(consumer C)\n"
            f'include("{prefix}/lib/cmake/gRPC.cmake")\n'
            "add_executable(consumer main.c)\ntarget_link_libraries(consumer PRIVATE grpc)\n"
        )
        subprocess.run(
            ["cmake", "-S", str(consumer), "-B", str(consumer / "build")],
            check=True,
            capture_output=True,
            timeout=300,
        )
        subprocess.run(
            ["cmake", "--build", str(consumer / "build")],
            check=True,
            capture_output=True,
            timeout=300,
        )
        subprocess.run(
            [str(consumer / "build/consumer")],
            check=True,
            env={**os.environ, "LD_LIBRARY_PATH": str(prefix / "lib")},
            timeout=300,
        )

    @unittest.skipUnless(
        shutil.which("cc") and shutil.which("readelf"),
        "C compiler and readelf required",
    )
    def test_abi_gate_rejects_newer_system_binaries(self):
        source = self.root / "probe.c"
        source.write_text(
            '#include <stdio.h>\nint main(void) { puts("probe"); return 0; }\n'
        )
        binary = self.root / "elf"
        binary.mkdir()
        subprocess.run(
            ["cc", str(source), "-o", str(binary / "probe")], check=True, timeout=300
        )
        self.assertTrue(abi.inspect(binary, "99.0", "99.0")["passed"])
        self.assertFalse(abi.inspect(binary, "2.0", "3.0")["passed"])

    def test_packages_declare_poppler_and_unrtf_and_ship_notices(self):
        metadata = json.loads((ROOT / "packaging/metadata.json").read_text())
        self.assertIn("libsecret-tools", metadata["deb_dependencies"])
        self.assertIn("libsecret", metadata["rpm_dependencies"])
        self.assertIn("libsecret", metadata["arch_dependencies"])
        self.assertIn("poppler-utils", metadata["deb_dependencies"])
        self.assertIn("poppler-utils", metadata["rpm_dependencies"])
        self.assertIn("poppler", metadata["arch_dependencies"])
        self.assertNotIn("poppler-utils", metadata["arch_dependencies"])
        for family in ("deb_dependencies", "rpm_dependencies", "arch_dependencies"):
            self.assertIn("unrtf", metadata[family])
        self.assertIn("perl", metadata["rpm_dependencies"])
        self.assertIn("perl", metadata["arch_dependencies"])
        self.assertNotIn("perl", metadata["deb_dependencies"])
        packages.stage(self.bundle, self.root / "stage")
        doc = self.root / "stage/usr/share/doc/open-foresight"
        self.assertEqual((doc / "LICENSE").read_text(), (ROOT / "LICENSE").read_text())
        self.assertFalse((doc / "copyright").exists())
        phrases = {
            "grpc-LICENSE": "Apache License",
            "grpc-NOTICE.txt": "gRPC authors",
            "protobuf-LICENSE": "Google Inc.",
            "abseil-cpp-LICENSE": "Apache License",
            "re2-LICENSE": "RE2 Authors",
            "cares-cares-LICENSE.md": "Massachusetts Institute of Technology",
            "icu-LICENSE": "UNICODE LICENSE",
            "sqlite-LICENSE": "Public Domain",
        }
        for name, phrase in phrases.items():
            text = (doc / "notices" / name).read_text(errors="replace")
            self.assertIn(phrase, text)
        packages.write_debian_copyright(self.root / "stage")
        copyright_text = (doc / "copyright").read_text()
        self.assertIn(
            "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/",
            copyright_text,
        )
        for name in phrases:
            self.assertIn(f"notices/{name}", copyright_text)
        self.assertIn("License: MIT", copyright_text)
        self.assertIn("Teng Lin", copyright_text)
        spec = packages.rpm_spec("0.1.0", "1", metadata)
        install = packages.arch_install_script()
        prerm = packages.deb_prerm()
        preinst = packages.deb_preinst()
        for path in packages.PAYLOAD_PATHS:
            self.assertIn(path, spec)
        for script in (prerm, preinst, spec, install):
            self.assertIn("upgrade_lock_decision", script)
            self.assertIn("F_SETLK", script)
            self.assertNotIn("flock -n", script)
            self.assertIn("refuse_upgrade_if_recording /opt/open-foresight", script)
        self.assertIn("upgrade|remove", prerm)
        self.assertIn("upgrade|install", preinst)
        self.assertIn("%pre\n", spec)
        self.assertIn("%preun\n", spec)
        self.assertIn('if [ "$1" = 0 ]; then', spec)
        self.assertLess(spec.index("%pre\n"), spec.index("cp -a payload/"))
        self.assertIn("pre_upgrade()", install)
        self.assertIn("pre_remove()", install)
        print(
            "Package notices, Debian copyright, and upgrade scripts passed.", flush=True
        )
        self.assertTrue(
            (
                self.root
                / "stage/opt/open-foresight/share/open-foresight/upgrade_lock.sh"
            ).is_file()
        )
        self.assertFalse((doc / "copyright").read_text().isspace())


class PackagePreflightTest(unittest.TestCase):
    def test_missing_speech_worker_leaves_output_available_for_retry(self):
        from types import SimpleNamespace
        from unittest.mock import patch

        sys.path.insert(0, str(ROOT / "tools"))
        import package

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build, flutter, runtime = root / "build", root / "flutter", root / "runtime"
            flutter.mkdir()
            runtime.mkdir()
            for name in (
                "services/helper/ForesightHelper",
                "native/libforesight_native.so",
                "application/foresight-service",
                "application/foresight-mcp",
                "services/inference/foresight-model",
                "lib/liblitert-lm.so",
            ):
                target = build / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"fixture")
            library = build / "lib/liblitert-lm.so"
            (runtime / "whisper-cli").write_bytes(b"fixture")
            output = root / "bundle"
            arguments = [
                "package.py",
                "--build",
                str(build),
                "--flutter-bundle",
                str(flutter),
                "--output",
                str(output),
                "--litert-library",
                str(library),
                "--litert-extensions-manifest",
                str(root / "manifest.json"),
                "--whisper-gpu-runtime",
                str(runtime / "whisper-cli"),
                "--revision",
                "a" * 40,
            ]
            extensions = SimpleNamespace(
                manifest={
                    "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest()
                }
            )
            with (
                patch.object(sys, "argv", arguments),
                patch.object(
                    package, "verify_extensions_manifest", return_value=extensions
                ),
            ):
                with self.assertRaisesRegex(
                    ValueError, "include foresight-whisper-worker"
                ):
                    package.main()
                self.assertFalse(output.exists())
                (runtime / "foresight-whisper-worker").write_bytes(b"fixture")
                # The same output passes preflight on retry and reaches its first write.
                with patch.object(
                    package.shutil, "copytree", side_effect=RuntimeError("copy reached")
                ):
                    with self.assertRaisesRegex(RuntimeError, "copy reached"):
                        package.main()


@unittest.skipUnless(
    sys.platform == "linux" and shutil.which("cc") and shutil.which("ldd"),
    "Linux ELF loader and C compiler required",
)
class LinuxDependencyCollectionTest(unittest.TestCase):
    def test_extension_validation_preserves_sdk_lookup_and_bundle_relocates(self):
        from types import SimpleNamespace
        from unittest.mock import patch

        sys.path.insert(0, str(ROOT / "tools"))
        import package

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build, sdk, flutter = root / "build", root / "sdk", root / "flutter"
            sdk.mkdir()
            flutter.mkdir()
            (flutter / "open-foresight").write_text("fixture desktop")

            def compile(source, destination, *arguments):
                destination.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(
                    [
                        "cc",
                        "-x",
                        "c",
                        "-",
                        "-o",
                        str(destination),
                        *map(str, arguments),
                    ],
                    input=source,
                    text=True,
                    check=True,
                    capture_output=True,
                    timeout=300,
                )

            # RUNPATH finds a direct dependency but does not apply to its child.
            # The SDK LD_LIBRARY_PATH is required to discover that transitive lib.
            compile(
                "int upb(void) { return 42; }",
                sdk / "libupb_fixture.so",
                "-shared",
                "-fPIC",
                "-Wl,-soname,libupb_fixture.so",
            )
            compile(
                "int upb(void); int grpc(void) { return upb(); }",
                sdk / "libgrpc_fixture.so",
                "-shared",
                "-fPIC",
                "-Wl,-soname,libgrpc_fixture.so",
                "-L" + str(sdk),
                "-lupb_fixture",
            )
            helper = build / "services/helper/ForesightHelper"
            compile(
                "int grpc(void); int main(void) { return grpc() != 42; }",
                helper,
                "-L" + str(sdk),
                "-lgrpc_fixture",
                "-Wl,--enable-new-dtags,-rpath," + str(sdk),
                "-Wl,-rpath-link," + str(sdk),
            )
            worker = build / "services/inference/foresight-model"
            compile("int main(void) { return 0; }", worker)
            for name in ("application/foresight-service", "application/foresight-mcp"):
                target = build / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(worker, target)
            library = build / "lib/liblitert-lm.so"
            compile(
                '#include <stdio.h>\nvoid fixture(void) { puts("fixture"); }',
                library,
                "-shared",
                "-fPIC",
            )
            for name in ("native/libforesight_native.so",):
                target = build / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(library, target)
            for name in ("sentencepiece", "flatbuffers"):
                target = build / f"_deps/{name}-src/LICENSE"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture license")
            for name in ("protobuf-lite", "esaxx", "darts_clone", "absl"):
                target = build / f"_deps/sentencepiece-src/third_party/{name}/LICENSE"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture license")
            digest = hashlib.sha256(library.read_bytes()).hexdigest()
            extensions = SimpleNamespace(
                manifest={
                    "library_sha256": digest,
                    "upstream_commit": "b2f686e2ed4718fb84ec398a61dd59ca0f0aff27",
                }
            )
            output = root / "bundle"
            arguments = [
                "package.py",
                "--build",
                str(build),
                "--flutter-bundle",
                str(flutter),
                "--output",
                str(output),
                "--litert-library",
                str(library),
                "--litert-extensions-manifest",
                str(root / "fixture-manifest.json"),
                "--revision",
                "a" * 40,
            ]
            # Only artifact authentication/C-API probing is stubbed. Library
            # resolution, dependency copying and relocated execution are real.
            with (
                patch.object(sys, "argv", arguments),
                patch.dict(os.environ, {"LD_LIBRARY_PATH": str(sdk)}),
                patch.object(
                    package, "verify_extensions_manifest", return_value=extensions
                ),
                patch.object(
                    package,
                    "copy_linux_extension_dependencies",
                    return_value=[output / "lib/liblitert-lm.so"],
                ),
                patch.object(package, "probe_native_extensions"),
            ):
                package.main()
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertTrue(
                {"libgrpc_fixture.so", "libupb_fixture.so"}
                <= set(manifest["bundled_libraries"])
            )
            shutil.rmtree(sdk)
            subprocess.run(
                [str(output / "bin/ForesightHelper")],
                check=True,
                env={**os.environ, "LD_LIBRARY_PATH": str(output / "lib")},
                timeout=300,
            )


class InstalledServiceShutdownTest(unittest.TestCase):
    def test_idle_shutdown_releases_a_detached_service_before_upgrade(self):
        spec = importlib.util.spec_from_file_location(
            "smoke_installed", ROOT / "packaging/smoke_installed.py"
        )
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = root / "foresight-service"
            log = root / "calls"
            service.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$1" >> "$CALLS"\n'
                'if [ "$1" = "--stop-if-idle" ]; then exit "$STOP_CODE"; fi\n'
                'if [ "$1" = "--status" ]; then exit "$STATUS_CODE"; fi\n'
                "exit 2\n"
            )
            service.chmod(0o755)
            env = {"CALLS": str(log), "STOP_CODE": "0", "STATUS_CODE": "0"}
            smoke.stop_installed_service(service, env)
            self.assertEqual(log.read_text().splitlines(), ["--stop-if-idle"])
            log.write_text("")
            env["STOP_CODE"] = "1"
            env["STATUS_CODE"] = "1"
            smoke.stop_installed_service(service, env)
            self.assertEqual(
                log.read_text().splitlines(), ["--stop-if-idle", "--status"]
            )
            env["STATUS_CODE"] = "0"
            with self.assertRaisesRegex(RuntimeError, "kept the install lock"):
                smoke.stop_installed_service(service, env)


class NativePythonPayloadTest(unittest.TestCase):
    def test_declared_worker_sources_are_allowed_but_runtime_and_extra_code_are_rejected(
        self,
    ):
        spec = importlib.util.spec_from_file_location(
            "smoke_installed", ROOT / "packaging/smoke_installed.py"
        )
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sys.path.insert(0, str(ROOT / "tools"))
            from query_worker_packaging import copy_worker

            copy_worker(root / "share/open-foresight/adapters")
            smoke.validate_native_python_payload(root)
            for name in (
                "share/open-foresight/adapters/unexpected.py",
                "elsewhere/legacy_query_worker.py",
                "bin/python3",
                "lib/libpython3.13.so",
                "share/worker.pyc",
                "share/worker.pyo",
            ):
                with self.subTest(name=name):
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"unexpected payload")
                    with self.assertRaisesRegex(ValueError, name):
                        smoke.validate_native_python_payload(root)
                    path.unlink()


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
            if os.environ.get("FORESIGHT_REQUIRE_DOCUMENT_SANDBOX") == "1":
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


class SpeechCpuBlockTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("g++"), "g++ required to call speech_cpu_blocker")
    def test_shipped_blocker_refuses_each_missing_feature(self):
        directory = Path(tempfile.mkdtemp(prefix="speech-cpu-"))
        self.addCleanup(shutil.rmtree, directory)
        source = directory / "call.cc"
        source.write_text(
            '#include "speech_cpu.h"\n#include <iostream>\n#include <string>\n'
            "int main(int argc, char **argv) {\n"
            '  if (argc == 2 && std::string(argv[1]) == "--probe") {\n'
            "    auto error = linux_speech_cpu_block();\n"
            '    std::cout << (error ? *error : std::string("allow")) << "\\n";\n'
            "    return 0;\n"
            "  }\n"
            "  auto error = speech_cpu_blocker(argv[1][0] == '1', argv[2][0] == '1', argv[3][0] == '1');\n"
            '  if (!error) { std::cout << "allow\\n"; return 0; }\n'
            '  std::cout << *error << "\\n";\n'
            "  return 1;\n"
            "}\n"
        )
        binary = directory / "call"
        subprocess.run(
            [
                "g++",
                "-std=c++20",
                "-Wall",
                "-Wextra",
                "-Wpedantic",
                "-I",
                str(ROOT / "native"),
                str(source),
                "-o",
                str(binary),
            ],
            check=True,
            timeout=300,
        )
        probe = subprocess.run(
            [str(binary), "--probe"],
            check=True,
            capture_output=True,
            text=True,
            timeout=300,
        )
        print(
            "Host speech CPU probe (not required to lack AVX2): "
            + probe.stdout.strip(),
            flush=True,
        )
        allow = subprocess.run(
            [str(binary), "1", "1", "1"],
            check=False,
            capture_output=True,
            text=True,
            timeout=300,
        )
        self.assertEqual(allow.returncode, 0)
        self.assertEqual(allow.stdout.strip(), "allow")
        for flags, missing in (
            (("0", "1", "1"), "AVX2"),
            (("1", "0", "1"), "FMA"),
            (("1", "1", "0"), "F16C"),
            (("0", "0", "0"), "AVX2, FMA, F16C"),
        ):
            result = subprocess.run(
                [str(binary), *flags],
                check=False,
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("this CPU is missing " + missing + ".", result.stdout)
            self.assertIn("Speech runtime requires AVX2, FMA, and F16C", result.stdout)
            self.assertIn("Transcription was not started", result.stdout)
            print(
                f"speech_cpu_blocker {' '.join(flags)} refused: {result.stdout.strip()}",
                flush=True,
            )
        native = (ROOT / "native/foresight_native.cpp").read_text()
        body = native[
            native.index("int fs_speech_finish") : native.index("int fs_speech_cancel")
        ]
        execution = re.search(r"\b(?:run|run_persistent)\s*\(", body)
        self.assertIsNotNone(execution)
        self.assertLess(body.index("linux_speech_cpu_block"), execution.start())
        self.assertIn(
            "speech_runtime_failure",
            body[body.index("linux_speech_cpu_block") : execution.start()],
        )


class UpgradeLockDecisionTest(unittest.TestCase):
    @unittest.skipUnless(
        sys.platform == "linux",
        "upgrade_lock_decision packs the 32-byte Linux LP64 flock structure",
    )
    def test_held_lock_refuses_and_free_lock_allows(self):
        import fcntl

        script = ROOT / "packaging/upgrade_lock.sh"
        directory = Path(tempfile.mkdtemp(prefix="upgrade-lock-"))
        self.addCleanup(shutil.rmtree, directory)
        lock = directory / "lock"
        lock.write_text("")
        os.chmod(lock, 0o600)

        def decision(path):
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    '. "$1"; upgrade_lock_decision "$2"',
                    "bash",
                    str(script),
                    str(path),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=300,
            )
            return result.returncode, result.stdout.strip(), result.stderr

        missing = directory / "absent"
        self.assertEqual(decision(missing), (0, "allow", ""))
        self.assertFalse(missing.exists())
        self.assertEqual(decision(lock), (0, "allow", ""))
        print("upgrade_lock_decision free lock => allow", flush=True)
        link = directory / "linked"
        link.symlink_to(lock)
        self.assertEqual(decision(link)[:2], (1, "refuse"))
        held = os.open(lock, os.O_RDWR)
        self.addCleanup(os.close, held)
        fcntl.lockf(held, fcntl.LOCK_SH)
        code, output, error = decision(lock)
        self.assertEqual((code, output), (1, "refuse"), error)
        print("upgrade_lock_decision held shared record lock => refuse", flush=True)
        fcntl.lockf(held, fcntl.LOCK_UN)
        self.assertEqual(decision(lock), (0, "allow", ""))
        print("upgrade_lock_decision released lock => allow", flush=True)
        identity = subprocess.run(
            [
                "bash",
                "-c",
                '. "$1"; installation_identity "$2"',
                "bash",
                str(script),
                str(directory),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=300,
        ).stdout.strip()
        self.assertEqual(
            identity, hashlib.sha256(str(directory.resolve()).encode()).hexdigest()[:24]
        )


if __name__ == "__main__":
    unittest.main()


def test_every_shipped_license_has_a_stanza_and_unknown_notices_fail(tmp_path):
    bundle = tmp_path / "bundle"
    for name in packages.BUNDLE_LICENSES:
        if name == "NOTICES.Z":
            import gzip

            data = gzip.compress(b"Flutter aggregate notices")
        else:
            data = b"Fixture complete notice text"
        path = bundle / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    copyright_text = packages.debian_copyright_text(bundle)
    for path in packages.bundle_license_files(bundle):
        assert (
            f"Files: opt/open-foresight/{path.relative_to(bundle)}\n" in copyright_text
        )
    import pytest

    (bundle / "unknown-LICENSE").write_text("unknown")
    with pytest.raises(ValueError, match="Unmapped bundled license"):
        packages.stage(bundle, tmp_path / "stage")


def test_nlohmann_notice_is_in_shared_deb_rpm_arch_payload(tmp_path):
    packages.install_legal_notices(tmp_path)
    path = packages.DOC_DIR / "notices/nlohmann-json-LICENSE.MIT"
    assert "2013-2022 Niels Lohmann" in (tmp_path / path).read_text()
    assert "notices/nlohmann-json-LICENSE.MIT" in packages.debian_copyright_text()
    assert "/usr/share/doc/open-foresight" in packages.PAYLOAD_PATHS


@unittest.skipUnless(
    sys.platform == "linux",
    "Linux maintainer scripts require GNU stat and Linux LP64 record locks",
)
def test_install_lock_rejects_untrusted_directories_and_preserves_legitimate_lock(
    tmp_path,
):
    import fcntl

    root = tmp_path / "install"
    root.mkdir()
    identity = hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:24]
    # Rewrite only the candidate glob to keep the maintainer script test entirely
    # inside this user's temporary directory instead of the global /tmp.
    script = packages.UPGRADE_LOCK.read_text().replace(
        "/tmp/of-install-*", str(tmp_path / "of-install-*")
    )
    script += '\nrefuse_upgrade_if_recording "$1"\n'
    for uid, mode, refused in (
        (os.getuid() + 1, 0o700, False),
        (os.getuid(), 0o755, False),
        (os.getuid(), 0o700, True),
    ):
        directory = tmp_path / f"of-install-{uid}-{identity}"
        directory.mkdir(exist_ok=True)
        directory.chmod(mode)
        with (directory / "lock").open("w+") as lock:
            fcntl.lockf(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            result = subprocess.run(
                ["sh", "-c", script, "fixture", str(root)],
                capture_output=True,
                text=True,
                timeout=10,
            )
        assert (result.returncode != 0) == refused, result.stderr
        assert ("Ignoring untrusted" in result.stderr) != refused
        (directory / "lock").unlink()
        directory.rmdir()


def test_nlohmann_notice_is_listed_in_debian_package(tmp_path):
    _assert_native_package_notice(tmp_path, "deb", "dpkg-deb")


def test_nlohmann_notice_is_listed_in_rpm_package(tmp_path):
    _assert_native_package_notice(tmp_path, "rpm", "rpmbuild")


def test_nlohmann_notice_is_listed_in_arch_package(tmp_path):
    _assert_native_package_notice(tmp_path, "arch", "makepkg")


def _assert_native_package_notice(tmp_path, kind, tool):
    import pytest

    if not shutil.which(tool):
        pytest.skip(f"Native {kind} packager {tool} required")
    root = tmp_path / "root"
    packages.install_legal_notices(root)
    (root / "opt/open-foresight").mkdir(parents=True)
    for name in (
        "usr/bin/open-foresight",
        "usr/share/applications/io.openforesight.App.desktop",
        "usr/share/pixmaps/open-foresight.png",
    ):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture")
    if kind == "deb":
        output = tmp_path / "fixture.deb"
        packages.make_deb(root, output, "0.1.1", "1", packages.METADATA)
        command = ["dpkg-deb", "--contents", str(output)]
    elif kind == "rpm":
        if not shutil.which("rpm"):
            pytest.skip("RPM payload listing requires rpm")
        output = tmp_path / "fixture.rpm"
        packages.make_rpm(root, output, "0.1.1", "1", packages.METADATA, 1234)
        command = ["rpm", "-qlp", str(output)]
    else:
        output = tmp_path / "fixture.pkg.tar.zst"
        if os.geteuid() == 0:
            # The linux-native CI container runs pytest as root, while makepkg
            # requires an unprivileged owner. Isolate this build on disk in
            # /var/tmp so root's private pytest ancestors stay private.
            import pwd

            account = pwd.getpwnam("nobody")
            with tempfile.TemporaryDirectory(
                prefix="of-arch-payload-", dir="/var/tmp"
            ) as temporary:
                build = Path(temporary)
                build.chmod(0o755)
                os.chown(build, account.pw_uid, account.pw_gid)
                shutil.copytree(root, build / "root")
                subprocess.run(
                    [
                        "runuser",
                        "-u",
                        account.pw_name,
                        "--",
                        sys.executable,
                        "-c",
                        "import runpy,sys; from pathlib import Path; "
                        "module=runpy.run_path(sys.argv[1]); "
                        "module['make_arch'](Path(sys.argv[2]),Path(sys.argv[3]),'0.1.1','1',module['METADATA'],1234)",
                        str(ROOT / "packaging/package_linux.py"),
                        str(build / "root"),
                        str(build / "fixture.pkg.tar.zst"),
                    ],
                    cwd=build,
                    env={**os.environ, "TMPDIR": str(build)},
                    check=True,
                    timeout=120,
                )
                shutil.copy2(build / "fixture.pkg.tar.zst", output)
        else:
            packages.make_arch(root, output, "0.1.1", "1", packages.METADATA, 1234)
        command = ["bsdtar", "-tf", str(output)]
    listing = subprocess.check_output(command, text=True, timeout=60)
    assert "usr/share/doc/open-foresight/notices/nlohmann-json-LICENSE.MIT" in listing
