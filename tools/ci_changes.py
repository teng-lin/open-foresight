#!/usr/bin/env python3
"""Select expensive CI only for changes that can affect application outputs."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import subprocess


GATES = ("macos", "linux-native", "linux-document-imports", "linux-bundle", "packaging")

# Standalone quality/maintenance controls do not change installed application bytes.
MAINTENANCE = {
    "tools/ci_stats.py",
    "tests/test_ci_stats.py",
    ".coveragerc",
    "pytest.ini",
    "pytest-exclusions.json",
    "pyproject.toml",
    "tools/evaluate_pipeline.py",
    "tools/release_latest.py",
    "tests/test_release_latest.py",
    "tools/cleanup_linux_packages.py",
    "tests/test_cleanup_linux_packages.py",
    "tools/publish_linux_package_aliases.py",
    "tests/test_publish_linux_package_aliases.py",
    ".github/workflows/linux-registry.yml",
    ".github/workflows/quality.yml",
}
# These controls and tests cannot change compiled application/SDK bytes. They
# still require workflow lint, Python quality and real distro package contracts.
PACKAGING_FILES = {
    "tools/package_contract_candidate.py",
    "tests/test_package_contract_candidate.py",
    "tools/github_release.py",
    "tools/release_asset_acceptance.py",
    "tools/release_acceptance_report.py",
    "tests/test_release_acceptance_report.py",
    "tools/reuse_release_acceptance.py",
    "tests/test_reuse_release_acceptance.py",
    "tests/test_dmg_contract.py",
    ".github/workflows/release-acceptance.yml",
    "packaging/package_linux.py",
    "packaging/upgrade_lock.sh",
    "tools/create_dmg.py",
    "tests/test_create_dmg.py",
    "tools/prepare_release.py",
    "tests/test_prepare_release.py",
    "tools/preview_packages.py",
    "tests/test_preview_packages.py",
    "tests/test_ci_dependencies.py",
    "tests/test_ci_stage_cache.py",
    "tests/test_pull_request_workflows.py",
    "tests/test_linux_stage_workflows.py",
    "tests/test_linux_packages.py",
    "tests/test_ci_package_sandbox.py",
    "tests/test_rpm_scriptlets.py",
    "tools/release_inputs.py",
    "tools/release_upload.py",
    "tests/test_release_upload.py",
    "tools/candidate_identity.py",
    "tests/test_candidate_identity.py",
    "tests/test_ci_promotion.py",
    ".github/workflows/linux-packages.yml",
    ".github/workflows/macos-release.yml",
    ".github/workflows/preview-packages.yml",
    ".github/workflows/release.yml",
    ".github/workflows/package-contracts.yml",
}

MACOS_FILES = {
    "tests/test_macos_bundle.py",
    "tests/test_macos_tools.py",
    "tests/test_macos_deployment_target.py",
    "tools/ci_macos_dependencies.py",
    "tools/build_macos_sdk.py",
    "tools/build_macos_vendor.py",
    "tools/build_macos_runtimes.py",
    "tools/clean_macos_runtime_sources.py",
    "tools/install_macos.py",
    "tools/macos_bundle.py",
    "tools/package_macos.py",
    "tools/smoke_macos_bundle.py",
    "tools/verify_macos_release_runtime.py",
}
LINUX_FILES = {
    "packaging/build.Dockerfile",
    "packaging/sdk.Dockerfile",
    "packaging/sdk-core.Dockerfile",
    "packaging/sdk-litert.Dockerfile",
    "packaging/sdk-whisper.Dockerfile",
    "packaging/minimal-grpc.cmake",
    "tools/build_linux_sdk.sh",
    "tools/build_linux_sdk_local.sh",
    "tools/linux_sdk_artifacts.py",
}


def select_gates(paths, force=False):
    selected = dict.fromkeys(GATES, force)
    for path in paths:
        # These Markdown notices are installed payloads, so editorial suffix
        # rules must not hide changes to the package's legal contents.
        if path in PACKAGING_FILES or path.startswith("packaging/ci/"):
            selected["packaging"] = True
            continue
        if path.startswith("packaging/notices/"):
            for gate in GATES[1:]:
                selected[gate] = True
            continue
        # Root Python tests run in the unconditional quality job. Keep explicit
        # packaging and real Apple-runtime tests above/in MACOS_FILES; nested
        # native, inference and subprocess suites still select their platforms.
        if (
            PurePosixPath(path).parent == PurePosixPath("tests")
            and PurePosixPath(path).name.startswith("test_")
            and PurePosixPath(path).suffix == ".py"
            and path not in MACOS_FILES
        ):
            continue
        if (
            path.startswith("docs/")
            or PurePosixPath(path).suffix == ".md"
            or path.startswith(".github/ISSUE_TEMPLATE/")
            or path in MAINTENANCE
        ):
            continue
        if path in MACOS_FILES or path.startswith(
            ("apps/desktop/macos/", "packaging/macos/")
        ):
            selected["macos"] = True
        elif path in LINUX_FILES or path.startswith("apps/desktop/linux/"):
            for gate in GATES[1:]:
                selected[gate] = True
        else:
            selected = dict.fromkeys(GATES, True)
    return selected


def requires_build(paths):
    return any(select_gates(paths).values())


def check_gates(jobs, selected, main):
    """Reject failed classification, malformed selection and skipped selected jobs."""
    if set(selected) != set(GATES) or any(
        type(value) is not bool for value in selected.values()
    ):
        raise ValueError("Invalid platform selection")
    expected = {"changes": "success"}
    expected.update(
        {
            name: "success"
            if required and (name != "linux-bundle" or main)
            else "skipped"
            for name, required in selected.items()
        }
    )
    expected["macos-stages"] = expected["macos"]
    for name, result in expected.items():
        if jobs.get(name, {}).get("result") != result:
            raise ValueError(
                f"{name}: expected {result}, got {jobs.get(name, {}).get('result')}"
            )


def selection_report(paths, *, force=False, platforms="all", revision_range=""):
    selected = select_gates(paths, force=force)
    if platforms == "linux":
        selected["macos"] = False
    elif platforms == "macos":
        for gate in ("linux-native", "linux-document-imports", "linux-bundle"):
            selected[gate] = False
    return {
        "range": revision_range,
        "force": force,
        "platforms": platforms,
        "selection": selected,
        "paths": [
            {
                "path": path,
                "gates": [
                    gate for gate, value in select_gates([path]).items() if value
                ],
            }
            for path in paths
        ],
    }


def write_report(report, destination):
    Path(destination).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    selected = report["selection"]
    lines = [
        "## CI selection",
        "",
        f"Range: `{report['range']}`",
        "",
        f"Forced: `{report['force']}`; platform scope: `{report['platforms']}`",
        "",
        "| Gate | Selected |",
        "| --- | --- |",
    ]
    lines.extend(
        f"| {gate} | {str(value).lower()} |" for gate, value in selected.items()
    )
    lines.extend(["", "### Changed paths", ""])
    for item in report["paths"]:
        # Keep path newlines and Markdown delimiters literal in logs and summaries.
        display_path = json.dumps(item["path"]).replace("`", "\\u0060")
        lines.append(
            "`" + display_path + "`: " + (", ".join(item["gates"]) or "quality only")
        )
    summary = "\n".join(lines) + "\n"
    print(summary)
    if summary_file := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary_file, "a") as stream:
            stream.write(summary)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(
                "selection=" + json.dumps(selected, separators=(",", ":")) + "\n"
            )
            for name, required in selected.items():
                stream.write(f"{name.replace('-', '_')}={str(required).lower()}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument(
        "--explain", metavar="RANGE", help="Explain selection for a Git revision range"
    )
    parser.add_argument("--json-output", default="ci-selection.json")
    parser.add_argument("--check-gates", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--platforms", choices=("all", "linux", "macos"), default="all")
    args = parser.parse_args()
    if args.check_gates:
        check_gates(
            json.loads(os.environ["NEEDS"]),
            json.loads(os.environ["SELECTION"]),
            os.environ["MAIN"] == "true",
        )
        print("All selected platform gates passed.")
        return
    if not args.base and not args.explain:
        parser.error("--base or --explain is required for change classification")
    if args.base and args.explain:
        parser.error("--base and --explain are mutually exclusive")
    revisions = [args.explain] if args.explain else [args.base, "HEAD"]
    if args.base and not args.base.strip("0"):
        revisions[0] = subprocess.check_output(
            ["git", "hash-object", "-t", "tree", "/dev/null"], text=True, timeout=300
        ).strip()
    paths = (
        subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", *revisions, "--"],
            timeout=300,
        )
        .decode()
        .split("\0")
    )
    subprocess.run(
        ["git", "diff", "--check", *revisions, "--"], check=True, timeout=300
    )
    report = selection_report(
        [path for path in paths if path],
        force=args.force,
        platforms=args.platforms,
        revision_range=args.explain or f"{revisions[0]}..HEAD",
    )
    write_report(report, args.json_output)


if __name__ == "__main__":
    main()
