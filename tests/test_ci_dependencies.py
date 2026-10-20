"""Exercise dependency invalidation, artifact provenance and promotion failures."""

import io
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest

import pytest
from unittest.mock import patch
import zipfile

from tools import ci_artifacts as artifacts
from tools import ci_changes as changes
from tools import ci_registry as registry
from test_ci_release_candidates import (
    producer as producer,
    SOURCE as CANDIDATE_SOURCE,
    REPOSITORY as CANDIDATE_REPOSITORY,
)


def pack_fixture(*args):
    """Pack real fixture bytes without depending on the source export's HEAD."""

    def revision(command, **kwargs):
        assert command == ["git", "rev-parse", "HEAD"]
        assert kwargs == {"cwd": artifacts.ROOT, "text": True, "timeout": 30}
        return "9" * 40 + "\n"

    with patch.object(artifacts.subprocess, "check_output", side_effect=revision):
        return artifacts.pack(*args)


class FingerprintTests(unittest.TestCase):
    def test_all_linux_dockerfile_copy_sources_are_bound_to_component_identity(self):
        for component in ("linux-core", "linux-litert", "linux-whisper", "linux-sdk"):
            recipe = next(
                name
                for name in artifacts.FILES[component]
                if name.endswith(".Dockerfile")
            )
            for line in (artifacts.ROOT / recipe).read_text().splitlines():
                if not line.startswith("COPY "):
                    continue
                words = shlex.split(line)
                if not words or words[0] != "COPY" or words[1].startswith("--from="):
                    continue
                for source in words[1:-1]:
                    path = artifacts.ROOT / source
                    files = (
                        [p for p in path.rglob("*") if p.is_file()]
                        if path.is_dir()
                        else [path]
                    )
                    for copied in files:
                        with self.subTest(component=component, source=str(copied)):
                            self.assertIn(
                                copied.relative_to(artifacts.ROOT).as_posix(),
                                artifacts.FILES[component],
                            )

    def test_linux_sdk_copies_transitive_worker_headers(self):
        copied = set()
        recipe = artifacts.ROOT / "packaging/sdk.Dockerfile"
        for line in recipe.read_text().splitlines():
            if not line.startswith("COPY "):
                continue
            words = shlex.split(line)
            if not words or words[0] != "COPY" or words[1].startswith("--from="):
                continue
            for source in words[1:-1]:
                path = artifacts.ROOT / source
                if path.is_dir():
                    copied.update(p.resolve() for p in path.rglob("*") if p.is_file())
                else:
                    copied.add(path.resolve())
        for source in copied:
            if source.suffix not in {".cpp", ".h"}:
                continue
            for include in re.findall(
                r'^#include "([^"\n]+)"', source.read_text(), re.M
            ):
                dependency = (source.parent / include).resolve()
                with self.subTest(source=str(source), include=include):
                    self.assertIn(dependency, copied)

    def test_litert_change_does_not_invalidate_core_or_whisper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for files in artifacts.FILES.values():
                for name in files:
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes((artifacts.ROOT / name).read_bytes())
            before = {
                name: artifacts.fingerprint(name, root) for name in artifacts.FILES
            }
            (root / "tools/build_litert_extensions.py").write_text("new LiteRT recipe")
            after = {
                name: artifacts.fingerprint(name, root) for name in artifacts.FILES
            }
            self.assertEqual(before["linux-core"], after["linux-core"])
            self.assertEqual(before["linux-whisper"], after["linux-whisper"])
            self.assertNotEqual(before["linux-litert"], after["linux-litert"])
            self.assertNotEqual(before["linux-sdk"], after["linux-sdk"])
            self.assertNotEqual(before["macos-runtime"], after["macos-runtime"])
            self.assertEqual(before["macos-sdk"], after["macos-sdk"])
            (root / "requirements-dev.lock").write_text("new toolchain dependencies")
            for name in ("linux-core", "linux-litert", "linux-whisper"):
                self.assertEqual(after[name], artifacts.fingerprint(name, root))
            self.assertNotEqual(
                after["linux-sdk"], artifacts.fingerprint("linux-sdk", root)
            )

    def test_speech_worker_changes_invalidate_assembly_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for files in artifacts.FILES.values():
                for name in files:
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes((artifacts.ROOT / name).read_bytes())
            before = {
                name: artifacts.fingerprint(name, root) for name in artifacts.FILES
            }
            (root / "services/speech/worker.cpp").write_text(
                "new persistent speech worker"
            )
            for component in (
                "linux-core",
                "linux-litert",
                "linux-whisper",
                "linux-sdk",
            ):
                after = artifacts.fingerprint(component, root)
                if component == "linux-sdk":
                    self.assertNotEqual(before[component], after)
                else:
                    self.assertEqual(before[component], after)

    def test_lock_comments_preserve_keys_but_dependencies_hashes_and_flags_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "requirements-dev.lock"
            requirement = "example==1.0 --hash=sha256:abc\n"
            path.write_text("# generated by tool\n" + requirement)
            expected = artifacts.input_digest(path)
            path.write_text(
                "   # differently wrapped header\n# second line\n" + requirement
            )
            self.assertEqual(expected, artifacts.input_digest(path))
            for meaningful in (
                requirement.replace("1.0", "2.0"),
                requirement.replace("abc", "def"),
                "--only-binary=:all:\n" + requirement,
                requirement.rstrip() + " # inline\n",
            ):
                path.write_text(meaningful)
                self.assertNotEqual(expected, artifacts.input_digest(path))
            path.write_text("example==1.0 \\\n# continued content\n")
            expected = artifacts.input_digest(path)
            path.write_text("example==1.0 \\\n# changed continued content\n")
            self.assertNotEqual(expected, artifacts.input_digest(path))

    def test_vendor_worker_and_python_boundaries_match_real_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for paths in artifacts.FILES.values():
                for name in paths:
                    destination = root / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes((artifacts.ROOT / name).read_bytes())
            before = {
                name: artifacts.fingerprint(name, root) for name in artifacts.FILES
            }
            changes = {
                "services/speech/worker.cpp": {"linux-sdk", "macos-runtime"},
                "services/inference/output_budget.h": {"linux-sdk", "macos-runtime"},
                "services/inference/worker_frame.h": {"linux-sdk", "macos-runtime"},
                "requirements-dev.lock": {"linux-sdk"},
                "packaging/sdk-core.Dockerfile": {
                    "linux-core",
                    "linux-litert",
                    "linux-whisper",
                    "linux-sdk",
                },
                "packaging/sdk-whisper.Dockerfile": {"linux-whisper", "linux-sdk"},
                "third_party/litert_lm/linux-trivial-abi.patch": {
                    "linux-litert",
                    "linux-sdk",
                },
                "tools/build_macos_vendor.py": {"macos-vendor", "macos-runtime"},
            }
            for name, expected in changes.items():
                path = root / name
                original = path.read_bytes()
                path.write_bytes(original + b"semantic change\n")
                actual = {
                    component
                    for component in artifacts.FILES
                    if before[component] != artifacts.fingerprint(component, root)
                }
                self.assertEqual(expected, actual, name)
                path.write_bytes(original)


class ArchiveTests(unittest.TestCase):
    def test_relocated_prefix_preserves_executable_and_relative_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            executable = source / "tool"
            executable.write_text("#!/bin/sh\necho relocated\n")
            executable.chmod(0o755)
            (source / "alias").symlink_to("tool")
            pack_fixture("macos-sdk", "a" * 64, source, root / "upload")
            artifacts.unpack("macos-sdk", "a" * 64, root / "upload", root / "restored")
            self.assertTrue((root / "restored/alias").is_symlink())
            self.assertEqual(
                subprocess.check_output(
                    [root / "restored/alias"], text=True, timeout=300
                ),
                "relocated\n",
            )
            with self.assertRaisesRegex(ValueError, "already exists"):
                artifacts.unpack(
                    "macos-sdk", "a" * 64, root / "upload", root / "restored"
                )

    def test_tampering_wrong_identity_and_escape_fail_without_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            pack_fixture("macos-sdk", "a" * 64, source, root / "upload")
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                artifacts.unpack(
                    "macos-sdk", "b" * 64, root / "upload", root / "destination"
                )
            archive = root / "upload/payload.tar.gz"
            archive.write_bytes(b"corrupt")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                artifacts.unpack(
                    "macos-sdk", "a" * 64, root / "upload", root / "destination"
                )
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("payload/../../escape")
                member.size = 3
                stream.addfile(member, io.BytesIO(b"bad"))
            record = json.loads((root / "upload/identity.json").read_text())
            record["sha256"] = artifacts.digest(archive)
            (root / "upload/identity.json").write_text(json.dumps(record))
            with self.assertRaises(tarfile.FilterError):
                artifacts.unpack(
                    "macos-sdk", "a" * 64, root / "upload", root / "destination"
                )
            self.assertFalse((root / "destination").exists())
            self.assertFalse((root / "escape").exists())


class ProvenanceTests(unittest.TestCase):
    def run_record(self, **kwargs):
        return {
            "id": 123,
            "path": ".github/workflows/ci-dependencies.yml",
            "event": "push",
            "head_branch": "main",
            "head_sha": "a" * 40,
            "conclusion": None,
            "head_repository": {"full_name": "teng-lin/open-foresight"},
            **kwargs,
        }

    def test_only_qualified_repository_and_workflow_are_trusted(self):
        run = self.run_record()
        self.assertTrue(artifacts.trusted_run(run, "macos-sdk"))
        for change in (
            {"head_repository": {"full_name": "other/fork"}},
            {"path": ".github/workflows/unrelated.yml"},
            {"event": "pull_request_target"},
            {"head_branch": "unreviewed"},
        ):
            self.assertFalse(artifacts.trusted_run({**run, **change}, "macos-sdk"))
        pr = self.run_record(
            event="pull_request", head_branch="feature", pull_requests=[{"number": 23}]
        )
        self.assertTrue(artifacts.trusted_run(pr, "macos-sdk", own_pr=23))
        self.assertFalse(artifacts.trusted_run(pr, "macos-sdk", own_pr=24))
        manual = self.run_record(event="workflow_dispatch", head_branch="feature")
        self.assertTrue(artifacts.trusted_run(manual, "macos-sdk", own_head="a" * 40))
        self.assertFalse(artifacts.trusted_run(manual, "macos-sdk", own_head="b" * 40))

    def test_candidate_context_is_independent_of_sibling_workflow_failures(self):
        run = self.run_record(
            path=".github/workflows/release.yml",
            event="workflow_dispatch",
            conclusion="success",
        )
        self.assertTrue(artifacts.trusted_run(run, "macos-app"))
        for change in (
            {"head_branch": "feature"},
            {"event": "pull_request"},
        ):
            self.assertFalse(artifacts.trusted_run({**run, **change}, "macos-app"))

    def test_merged_source_must_be_reachable_from_main(self):
        for status, expected in [
            ("ahead", True),
            ("identical", True),
            ("behind", False),
            ("diverged", False),
        ]:
            with patch.object(artifacts, "api", return_value={"status": status}):
                self.assertEqual(
                    artifacts.merged_source(
                        "teng-lin/open-foresight", self.run_record()
                    ),
                    expected,
                )

    def test_partial_run_can_supply_completed_dependency_but_not_failed_job(self):
        for conclusion, expected in [
            ("success", True),
            ("failure", False),
            (None, False),
        ]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prefix = root / "original"
                prefix.mkdir()
                with patch.dict("os.environ", {"GITHUB_RUN_ATTEMPT": "1"}):
                    pack_fixture("macos-sdk", "a" * 64, prefix, root / "upload")
                fixture_zip = io.BytesIO()
                with zipfile.ZipFile(fixture_zip, "w") as archive:
                    for member in ("identity.json", "payload.tar.gz"):
                        archive.write(root / "upload" / member, member)
                import hashlib

                zip_digest = (
                    "sha256:" + hashlib.sha256(fixture_zip.getvalue()).hexdigest()
                )
                run = self.run_record(
                    head_sha=json.loads((root / "upload/identity.json").read_text())[
                        "source_commit"
                    ]
                )
                listed = {
                    "artifacts": [
                        {
                            "id": 5,
                            "digest": zip_digest,
                            "name": artifacts.name("macos-sdk", "a" * 64),
                            "expired": False,
                            "workflow_run": {"id": 123},
                            "created_at": "2026-10-18T01:00:10Z",
                        }
                    ]
                }

                def api(repo, route, conclusion=conclusion):
                    if route.startswith("actions/artifacts?"):
                        return listed  # noqa: B023 - Fixture callbacks are consumed within this iteration.
                    if "/jobs?" in route:
                        return {
                            "jobs": [
                                {
                                    "name": "Build macOS sdk",
                                    "conclusion": conclusion,
                                    "started_at": "2026-10-18T01:00:00Z",
                                    "completed_at": "2026-10-18T01:01:00Z",
                                }  # noqa: B023 - Fixture callbacks are consumed within this iteration.
                            ]
                        }
                    return run  # noqa: B023 - Fixture callbacks are consumed within this iteration.

                def download(args, stdout, check, timeout, stderr):
                    with zipfile.ZipFile(stdout, "w") as archive:
                        for name in ("identity.json", "payload.tar.gz"):
                            archive.write(root / "upload" / name, name)  # noqa: B023 - Fixture callbacks are consumed within this iteration.

                with (
                    patch.object(artifacts, "api", side_effect=api),
                    patch.object(
                        artifacts, "source_fingerprint_at", return_value="a" * 64
                    ),
                    patch.object(
                        artifacts, "qualified_producer_control", return_value=True
                    ),
                    patch.object(artifacts.subprocess, "run", side_effect=download),
                ):
                    self.assertEqual(
                        artifacts.pull(
                            "teng-lin/open-foresight",
                            "macos-sdk",
                            "a" * 64,
                            root / "restored",
                        ),
                        expected,
                    )
                    self.assertEqual((root / "restored").exists(), expected)

    def test_successful_component_survives_later_attempt_failure_without_blessing_failed_outputs(
        self,
    ):
        for attempt, expected in [(1, True), (2, False)]:
            with (
                self.subTest(attempt=attempt),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                prefix = root / "original"
                prefix.mkdir()
                (prefix / "retained.txt").write_text("first successful component")
                with patch.dict("os.environ", {"GITHUB_RUN_ATTEMPT": str(attempt)}):
                    pack_fixture("linux-core", "a" * 64, prefix, root / "upload")
                fixture_zip = io.BytesIO()
                with zipfile.ZipFile(fixture_zip, "w") as archive:
                    for member in ("identity.json", "payload.tar.gz"):
                        archive.write(root / "upload" / member, member)
                import hashlib

                zip_digest = (
                    "sha256:" + hashlib.sha256(fixture_zip.getvalue()).hexdigest()
                )
                run = self.run_record(
                    conclusion="failure",
                    run_attempt=2,
                    head_sha=json.loads((root / "upload/identity.json").read_text())[
                        "source_commit"
                    ],
                )
                jobs = [
                    {
                        "name": "Build Linux core",
                        "conclusion": "success",
                        "run_attempt": 1,
                        "started_at": "2026-10-18T01:00:00Z",
                        "completed_at": "2026-10-18T01:01:00Z",
                    },
                    {
                        "name": "Build Linux core",
                        "conclusion": "failure",
                        "run_attempt": 2,
                    },
                    {
                        "name": "Assemble Linux SDK",
                        "conclusion": "failure",
                        "run_attempt": 2,
                    },
                ]

                def api(
                    repository,
                    route,
                    job_records=jobs,
                    run_record=run,
                    zip_digest=zip_digest,
                ):
                    if route.startswith("actions/artifacts?"):
                        return {
                            "artifacts": [
                                {
                                    "id": 5,
                                    "digest": zip_digest,
                                    "name": artifacts.name("linux-core", "a" * 64),
                                    "expired": False,
                                    "workflow_run": {"id": 123},
                                    "created_at": "2026-10-18T01:00:10Z",
                                }
                            ]
                        }
                    if "/jobs?" in route:
                        self.assertIn("filter=all", route)
                        return {"jobs": job_records}
                    return run_record

                def download(args, stdout, check, timeout, stderr, fixture_root=root):
                    with zipfile.ZipFile(stdout, "w") as archive:
                        for name in ("identity.json", "payload.tar.gz"):
                            archive.write(fixture_root / "upload" / name, name)

                with (
                    patch.object(artifacts, "api", side_effect=api),
                    patch.object(
                        artifacts, "source_fingerprint_at", return_value="a" * 64
                    ),
                    patch.object(
                        artifacts, "qualified_producer_control", return_value=True
                    ),
                    patch.object(artifacts.subprocess, "run", side_effect=download),
                ):
                    self.assertEqual(
                        artifacts.pull(
                            "teng-lin/open-foresight",
                            "linux-core",
                            "a" * 64,
                            root / "restored",
                        ),
                        expected,
                    )
                self.assertEqual((root / "restored").exists(), expected)
                if expected:
                    self.assertEqual(
                        (root / "restored/retained.txt").read_text(),
                        "first successful component",
                    )


class SelectionTests(unittest.TestCase):
    def assert_selection(self, paths, expected):
        actual = changes.select_gates(paths)
        expected = set(expected)
        if "macos" in expected or "packaging" in expected:
            expected.add("dmg")
        self.assertEqual(
            {name for name, required in actual.items() if required}, expected
        )

    def test_docs_and_explicit_maintenance_skip_platforms(self):
        self.assert_selection([], [])
        self.assert_selection(["README.md", "docs/platforms/ci-performance.md"], [])
        self.assert_selection(list(changes.MAINTENANCE), [])

    def test_platform_specific_paths_select_only_affected_platform(self):
        for path in (
            "apps/desktop/macos/Runner/MainFlutterWindow.swift",
            "packaging/macos/entitlements.plist",
            *changes.MACOS_FILES,
        ):
            with self.subTest(path=path):
                self.assert_selection([path], ["macos"])
        for path in (
            "apps/desktop/linux/runner/my_application.cc",
            *changes.LINUX_FILES,
        ):
            with self.subTest(path=path):
                expected = (
                    ["linux-build", "linux-test"]
                    if path == "tests/test_acceptance_image_cache.py"
                    else changes.GATES[1:]
                )
                self.assert_selection([path], expected)

    def test_packaging_controls_require_contracts_and_their_exact_own_run_bundle(self):
        for path in (*changes.PACKAGING_FILES, "packaging/ci/test-debian.sh"):
            with self.subTest(path=path):
                from tools import platform_python_tests as contracts

                owners = contracts.owner_gates(path)
                expected = (
                    set(owners)
                    if owners
                    else {"packaging", "linux-build", "linux-test"}
                )
                if "packaging" in expected:
                    expected.update(("linux-build", "linux-test"))
                if "linux-build" in expected:
                    expected.add("linux-test")
                self.assert_selection([path], expected)

    def test_shared_unknown_and_selector_changes_keep_full_validation(self):
        for path in (
            "packages/foresight_core/lib/src/application.dart",
            "apps/desktop/lib/main.dart",
            "native/foresight_native.cpp",
            "services/helper/main.cpp",
            "tools/build.sh",
            "tools/ci_changes.py",
            "tools/ci_artifacts.py",
            "tools/ci_stage_cache.py",
            "packaging/acceptance.Dockerfile",
            ".github/workflows/integration-acceptance.yml",
            "tools/build_litert_extensions.py",
            ".github/workflows/macos.yml",
            ".github/workflows/ci-dependencies.yml",
            "requirements-dev.lock",
            "LICENSE",
            "new/unknown.py",
        ):
            with self.subTest(path=path):
                self.assert_selection(
                    ["tools/cleanup_linux_packages.py", path], changes.GATES
                )

    def test_mixed_paths_union_and_force_overrides_empty_or_docs(self):
        self.assert_selection(
            [
                "apps/desktop/macos/Runner/file.swift",
                "apps/desktop/linux/runner/file.cc",
            ],
            changes.GATES,
        )
        for paths in ([], ["README.md"], list(changes.MAINTENANCE)):
            self.assertTrue(all(changes.select_gates(paths, force=True).values()))

    def test_selected_skipped_failed_or_unexpected_jobs_cannot_pass(self):
        for paths in (
            [],
            ["apps/desktop/macos/a.swift"],
            ["apps/desktop/linux/a.cc"],
            ["native/a.cpp"],
        ):
            for _main in (False, True):
                selected = changes.select_gates(paths)
                jobs = {
                    "changes": {"result": "success"},
                    **{
                        name: {"result": "success" if required else "skipped"}
                        for name, required in selected.items()
                    },
                }
                jobs["linux-native"] = {
                    "result": "success" if selected["linux-build"] else "skipped"
                }
                changes.check_gates(jobs, selected)
                for name in jobs:
                    for result in ("success", "cancelled", "failure", "skipped"):
                        if result != jobs[name]["result"]:
                            with self.assertRaises(ValueError):
                                changes.check_gates(
                                    {**jobs, name: {"result": result}}, selected
                                )

    def test_cli_rename_considers_removed_shared_path_and_force_selects_all(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(
                    ["git", *args], cwd=root, text=True, timeout=30
                ).strip()

            git("init", "-q")
            (root / "native").mkdir()
            (root / "tools").mkdir()
            (root / "native/shared.py").write_text("shared runtime source\n")
            git("add", ".")
            git(
                "-c",
                "user.name=CI",
                "-c",
                "user.email=ci@example.test",
                "commit",
                "-qm",
                "base",
            )
            base = git("rev-parse", "HEAD")
            git("mv", "native/shared.py", "tools/cleanup_linux_packages.py")
            git(
                "-c",
                "user.name=CI",
                "-c",
                "user.email=ci@example.test",
                "commit",
                "-qm",
                "rename",
            )
            for args in (("--base", base), ("--base", "HEAD", "--force")):
                output = root / "outputs"
                output.write_text("")
                subprocess.run(
                    [
                        sys.executable,
                        str(artifacts.ROOT / "tools/ci_changes.py"),
                        *args,
                    ],
                    cwd=root,
                    env={**os.environ, "GITHUB_OUTPUT": str(output)},
                    check=True,
                    timeout=30,
                    capture_output=True,
                )
                values = dict(
                    line.split("=", 1) for line in output.read_text().splitlines()
                )
                self.assertEqual(
                    json.loads(values["selection"]), dict.fromkeys(changes.GATES, True)
                )
                self.assertTrue(
                    all(
                        values[name.replace("-", "_")] == "true"
                        for name in changes.GATES
                    )
                )

    def test_missing_selection_or_job_fails_closed(self):
        for selected in ({}, {"macos": True}, dict.fromkeys(changes.GATES, "false")):
            with self.assertRaises(ValueError):
                changes.check_gates({}, selected)
        with self.assertRaises(ValueError):
            changes.check_gates({}, changes.select_gates([]))


class RegistryTests(unittest.TestCase):
    def test_only_missing_tags_allow_build(self):
        image = "ghcr.io/teng-lin/open-foresight/linux-core:key"
        for error in ("manifest unknown", image + ": not found"):
            with patch.object(
                registry.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 1, "", error),
            ):
                self.assertIsNone(registry.inspect(image))
                with self.assertRaises(RuntimeError):
                    registry.inspect(image.split(":")[0] + "@sha256:" + "a" * 64)
        for error in (
            "unauthorized: manifest unknown",
            "403 forbidden",
            "connection reset",
            "timeout",
            "credential helper not found",
            "proxy returned HTTP 404",
        ):
            with patch.object(
                registry.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 1, "", error),
            ):
                with self.assertRaises(RuntimeError):
                    registry.inspect(image)
        for reference in (image, image.split(":")[0] + "@sha256:" + "b" * 64):
            with patch.object(
                registry.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    [], 0, json.dumps({"digest": "sha256:" + "a" * 64}), ""
                ),
            ):
                self.assertEqual(
                    registry.inspect(reference),
                    image.split(":")[0] + "@sha256:" + "a" * 64,
                )


if __name__ == "__main__":
    unittest.main()


def test_release_latest_tool_is_maintenance_only():
    assert not any(changes.select_gates(["tools/release_latest.py"]).values())
    assert not any(changes.select_gates(["tests/test_release_latest.py"]).values())


def test_zip_download_checks_github_digest_before_unpacking(tmp_path):
    import pytest

    destination = tmp_path / "artifact.zip"

    def download(command, *, stdout, **kwargs):
        stdout.write(b"tampered ZIP bytes")

    with patch.object(artifacts.subprocess, "run", side_effect=download):
        with pytest.raises(ValueError, match="ZIP digest mismatch"):
            artifacts.download_zip(
                "owner/repo", {"id": 1, "digest": "sha256:" + "a" * 64}, destination
            )


def test_shared_dmg_packaging_selects_contracts_with_this_runs_linux_bundle():
    selected = changes.select_gates(["tools/create_dmg.py"])
    assert selected["packaging"]
    assert not selected["macos"]
    assert selected["linux-build"] and selected["linux-test"]


@pytest.mark.parametrize("artifact", [True, False])
@pytest.mark.parametrize(
    "own_head,own_pr", [("a" * 40, 23), ("fork-head", 24), ("main-head", 0)]
)
def test_explicit_macos_fork_validation_reuses_artifacts_before_building(
    tmp_path, artifact, own_head, own_pr
):
    from tools import ci_macos_dependencies as macos

    with (
        patch.object(macos, "pull", return_value=artifact) as pull,
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "waiting_producers", return_value=[]),
        patch.object(macos, "verify") as verify,
        patch.object(macos.subprocess, "run") as build,
    ):
        assert macos.ensure(
            "macos-sdk",
            tmp_path,
            "owner/repo",
            own_head,
            own_pr,
            allow_local_build=True,
        ) == ("artifact" if artifact else "local")
        assert pull.call_args.kwargs == {"own_head": own_head, "own_pr": own_pr}
        assert build.call_count == (0 if artifact else 1)
        verify.assert_called_once_with("macos-sdk", tmp_path)


def test_macos_runtime_local_fallback_builds_vendor_before_worker(tmp_path):
    from tools import ci_macos_dependencies as macos

    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "waiting_producers", return_value=[]),
        patch.object(macos, "verify"),
        patch.object(macos.subprocess, "run") as build,
    ):
        macos.ensure(
            "macos-runtime", tmp_path / "runtime", "owner/repo", allow_local_build=True
        )
    assert "build_macos_vendor.py" in build.call_args_list[0].args[0][1]
    assert "build_macos_runtimes.py" in build.call_args_list[1].args[0][1]


@pytest.mark.parametrize("source,accepted", [("a" * 40, False), ("b" * 40, True)])
def test_promotion_rejects_intermediate_pr_heads_even_when_reachable(source, accepted):
    run = {
        "head_sha": source,
        "event": "pull_request",
        "head_branch": "feature",
        "pull_requests": [{"number": 23}],
    }

    def api(repository, route):
        if route == "pulls/23":
            return {
                "merged_at": "2026-10-18",
                "head": {"sha": "b" * 40},
                "base": {"repo": {"full_name": repository}},
            }
        assert route == f"compare/{source}...main"
        return {"status": "ahead"}

    with patch.object(artifacts, "api", side_effect=api):
        assert artifacts.merged_source("owner/repo", run) == accepted


def test_macos_consumer_waits_for_matching_inflight_producer_then_uses_artifact(
    tmp_path,
):
    from tools import ci_macos_dependencies as macos

    with (
        patch.object(macos, "pull", side_effect=[False, True]),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "waiting_producers", return_value=[123]),
        patch.object(macos.time, "sleep"),
        patch.object(macos, "verify"),
        patch.object(macos.subprocess, "run") as build,
    ):
        assert (
            macos.ensure("macos-sdk", tmp_path, "owner/repo", "a" * 40, 23)
            == "artifact"
        )
        build.assert_not_called()


def test_explicit_fork_validation_can_build_when_inflight_producer_stops(
    tmp_path,
):
    from tools import ci_macos_dependencies as macos

    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "waiting_producers", side_effect=[[123], []]),
        patch.object(macos.time, "sleep"),
        patch.object(macos, "verify"),
        patch.object(macos.subprocess, "run") as build,
    ):
        assert (
            macos.ensure(
                "macos-sdk",
                tmp_path,
                "owner/repo",
                "a" * 40,
                23,
                allow_local_build=True,
            )
            == "local"
        )
        build.assert_called_once()


@pytest.mark.parametrize("failed", [False, True])
def test_macos_inflight_selection_rejects_fork_and_failed_producers(failed):
    from tools import ci_macos_dependencies as macos

    base = {
        "id": 123,
        "head_sha": "a" * 40,
        "head_branch": "feature",
        "path": ".github/workflows/ci-dependencies.yml",
        "event": "pull_request",
        "status": "in_progress",
        "pull_requests": [{"number": 23}],
        "head_repository": {"full_name": "owner/repo"},
    }
    fork = {**base, "id": 124, "head_repository": {"full_name": "fork/repo"}}
    with (
        patch.object(
            macos,
            "api",
            side_effect=lambda repo, route: {"workflow_runs": [base, fork]},
        ),
        patch.object(
            macos, "source_fingerprint", return_value=macos.fingerprint("macos-sdk")
        ),
        patch.object(
            macos,
            "dependency_jobs",
            return_value=[
                {"name": "Build macOS sdk", "conclusion": "failure" if failed else None}
            ],
        ),
    ):
        assert macos.waiting_producers("owner/repo", "macos-sdk", "a" * 40, 23) == (
            [] if failed else [123]
        )


def test_shared_dmg_packaging_selects_own_bundle_without_macos_application_compile():
    selected = changes.select_gates(["tools/create_dmg.py"])
    assert selected["packaging"]
    assert not selected["macos"]
    assert selected["linux-build"] and selected["linux-test"]
    assert not selected["macos"]


def test_release_rejects_candidate_for_another_commit(producer, tmp_path):
    payload = producer.item(artifacts.name("macos-app", CANDIDATE_SOURCE))
    producer.change(
        artifacts.receipt_name("macos-app", CANDIDATE_SOURCE),
        lambda record: record["source_receipt"].update(source_commit="e" * 40),
    )
    producer.downloads.clear()
    with pytest.raises(ValueError, match="mismatched"):
        artifacts.pull(
            CANDIDATE_REPOSITORY,
            "macos-app",
            CANDIDATE_SOURCE,
            tmp_path / "restored",
            source_run=42,
            consumer="release-preparation",
        )
    assert payload["id"] not in producer.downloads
    assert not (tmp_path / "restored").exists()
