#!/usr/bin/env python3
"""Run host contracts while the quality job owns full Python coverage."""

import argparse
import ast
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

# Keep real compiler, filesystem and shell behavior on both hosted platforms.
SHARED = (
    "tests/test_app_dependency_cmake.py",
    "tests/test_build_stages.py",
    "tests/test_capture_runtime_configuration.py",
    "tests/test_ci_stage_artifacts.py",
    "tests/test_ci_stage_environment.py",
    "tests/test_ci_stage_setup.py",
    "tests/test_ci_timing.py",
    "tests/test_core_coverage_benchmark.py",
    "tests/test_helper_build_identity.py",
    "tests/test_installed_documents.py",
    "tests/test_linux_packages.py",
    "tests/test_linux_ci_handoff.py",
    "tests/test_litert_build_snapshot.py",
    "tests/test_macos_cmake_cache.py",
    "tests/test_macos_one_job.py",
    "tests/test_native_incremental_work.py",
    "tests/test_parallel_build_gates.py",
    "tests/test_profile_migration.py",
    "tests/test_release_hook_configurations.py",
    "tests/test_test_hygiene.py",
    "tests/contracts/test_descriptor.py",
    "tests/contracts/test_owned_descriptors.py",
    "tests/inference/test_legacy_query_executor.py",
)
PLATFORM = {
    "linux": (),
    # These execute Apple tools/metadata APIs rather than portable mocks.
    "macos": (
        "tests/test_dmg_contract.py",
        "tests/test_macos_bundle.py",
        "tests/test_macos_deployment_target.py",
        "tests/test_macos_tools.py",
    ),
}
# These platform probes are fully replaced by fixtures; quality executes every
# case independently of its operating system. Keep explicit reasons for audit.
QUALITY_ONLY = {
    "tests/test_build_recipes.py": "All platform/tool probes are monkeypatched.",
    "tests/test_litert_build_orchestration.py": "Host platform/machine are fixture inputs.",
}


EXTERNAL = {
    "tests/inference/test_litert_identity.py": "native_litert_identity runs real loader fixtures in CTest on both platforms.",
    "tests/test_rpm_scriptlets.py": "Fedora package contract executes real rpmspec.",
    "tests/test_acceptance_image_cache.py": "Ubuntu acceptance executes opt-in Docker fixture.",
}


def host_sensitive(path):
    """Recognize existing host/tool conditions; newly found files need ownership."""
    tree = ast.parse(path.read_text())
    os_names = {"os"} | {
        alias.asname or alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
        if alias.name == "os"
    }
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and (
            node.module in {"platform", "sys", "os", "shutil"}
            and any(
                alias.name
                in {"platform", "name", "which", "system", "machine", "uname"}
                for alias in node.names
            )
        ):
            return True
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id
            in {
                "skip",
                "skipif",
                "skipIf",
                "skipUnless",
                "skipTest",
                "SkipTest",
                "importorskip",
                "which",
            }
        ):
            return True
        if isinstance(node, ast.Attribute) and node.attr in {
            "platform",
            "system",
            "machine",
            "uname",
            "name",
            "which",
            "skip",
            "skipif",
            "skipIf",
            "skipUnless",
            "skipTest",
            "SkipTest",
            "importorskip",
        }:
            # Avoid treating unrelated object.name attributes as host checks.
            if node.attr != "name" or (
                isinstance(node.value, ast.Name) and node.value.id in os_names
            ):
                return True
    return False


def inventory(root=ROOT):
    assigned = set(SHARED).union(*PLATFORM.values(), QUALITY_ONLY, EXTERNAL)
    missing = sorted(name for name in assigned if not (root / name).is_file())
    if missing:
        raise ValueError("Missing platform Python contracts: " + ", ".join(missing))
    excluded = json.loads((root / "pytest-exclusions.json").read_text())
    unassigned = sorted(
        path.relative_to(root).as_posix()
        for path in (root / "tests").rglob("test_*.py")
        if path.relative_to(root).as_posix() not in excluded
        and path.relative_to(root).as_posix() not in assigned
        and host_sensitive(path)
    )
    if unassigned:
        raise ValueError(
            "Assign host-sensitive Python contracts: " + ", ".join(unassigned)
        )


def command(platform, root=ROOT):
    inventory(root)
    return [
        sys.executable,
        "-m",
        "pytest",
        "--durations=20",
        "-ra",
        f"--junitxml=coverage/python/{platform}-contracts.xml",
        *SHARED,
        *PLATFORM[platform],
        # The real makepkg notice probe belongs to the Arch installer job.
        "--deselect=tests/test_linux_packages.py::test_nlohmann_notice_is_listed_in_arch_package",
    ]


def verify_execution(platform, report):
    """Reject absent or wholly skipped files, using the real pytest report."""
    cases = ET.parse(report).getroot().iter("testcase")  # noqa: S314 - local pytest output
    executed = set()
    for case in cases:
        if case.find("skipped") is None:
            name = case.get("classname", "")
            for path in SHARED + PLATFORM[platform]:
                module = path.removesuffix(".py").replace("/", ".")
                if name == module or name.startswith(module + "."):
                    executed.add(path)
    missing = sorted(set(SHARED + PLATFORM[platform]) - executed)
    if missing:
        raise ValueError(
            "Platform contracts absent or wholly skipped: " + ", ".join(missing)
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=tuple(PLATFORM))
    args = parser.parse_args()
    report = ROOT / f"coverage/python/{args.platform}-contracts.xml"
    report.unlink(missing_ok=True)
    status = subprocess.run(command(args.platform), cwd=ROOT, timeout=1800).returncode
    if status == 0:
        verify_execution(args.platform, report)
    raise SystemExit(status)


if __name__ == "__main__":
    main()
