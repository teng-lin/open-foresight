#!/usr/bin/env python3
"""Report-only native coverage (F25) and clang-tidy (F22) records.

Run from the repository root as ``python -m tools.native_quality_report``.

``coverage`` consumes the metadata written by ``cmake/ForesightNativeReports.cmake``
for a root build configured with ``-DFORESIGHT_NATIVE_COVERAGE=ON`` and already
built. It runs the complete root CTest suite with raw profiles written to a
fresh private directory, merges them with the llvm-profdata of the compiler's
LLVM release and emits llvm-cov JSON, HTML and text reports plus a record that
binds the source revision, build, tools, instrumented objects and profiles.

``clang-tidy`` analyzes an explicit repository file scope selected from
``compile_commands.json`` and optionally compares findings with an earlier
record. Tool failures are reported separately from findings.

Neither command enforces a coverage or finding threshold. Exit status 2 means an
infrastructure, metadata or tool failure; 1 means root CTest failed (the coverage
report is still written); 0 otherwise.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath
from typing import Any, NamedTuple, Sequence

METADATA_SCHEMA = "foresight-native-coverage-metadata/1"
COVERAGE_RECORD_SCHEMA = "foresight-native-coverage-record/1"
COVERAGE_SUMMARY_SCHEMA = "foresight-native-coverage-summary/1"
TIDY_RECORD_SCHEMA = "foresight-clang-tidy-record/1"
METADATA_RELATIVE_PATH = Path("foresight-native-reports") / "coverage-metadata.json"
EXIT_OK = 0
EXIT_TESTS_FAILED = 1
EXIT_INFRASTRUCTURE = 2
PROBE_TIMEOUT_SECONDS = 300
DEFAULT_CTEST_TIMEOUT_SECONDS = 3600
DEFAULT_LLVM_TIMEOUT_SECONDS = 1800
DEFAULT_TIDY_TIMEOUT_SECONDS = 600
# %p separates processes; %m separates instrumented modules (an executable and
# the instrumented shared library it loads) and enables online merging.
PROFILE_PATTERN = "%p-%m.profraw"
COVERAGE_METRICS = ("lines", "functions", "regions", "branches")
DEFAULT_TIDY_SCOPE = ("native", "services/helper", "services/inference")
TIDY_EXCLUDED_PREFIXES = ("third_party",)
TIDY_SUFFIXES = frozenset({".c", ".cc", ".cpp", ".cxx", ".mm"})
STALE_PROFILE = re.compile(
    r"mismatched data|no coverage data found|failed to load coverage", re.IGNORECASE
)
LLVM_VERSION = re.compile(
    r"(?P<apple>Apple )?(?:LLVM|clang) version (?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)"
)
DIAGNOSTIC = re.compile(
    r"^(?P<path>.+?):(?P<line>\d+):(?P<column>\d+): (?P<severity>warning|error): "
    r"(?P<message>.*?)(?: \[(?P<check>[^\[\]]+)\])?$"
)


class ReportError(Exception):
    """Infrastructure, metadata or tool failure; never a coverage or finding result."""


class ToolTimeout(ReportError):
    """A tool exceeded its finite deadline; ``stdout``/``stderr`` keep its partial output."""

    def __init__(self, message: str, stdout: str, stderr: str) -> None:
        super().__init__(message)
        self.stdout = stdout
        self.stderr = stderr


def partial_output(value: str | bytes | None) -> str:
    """Decode what a timed-out subprocess wrote (bytes on POSIX even in text mode)."""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value or ""


class LlvmRelease(NamedTuple):
    apple: bool
    version: tuple[int, int, int]

    def label(self) -> str:
        prefix = "Apple LLVM " if self.apple else "LLVM "
        return prefix + ".".join(str(part) for part in self.version)


def utc_now() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def file_identity(path: Path, label: str | None = None) -> dict[str, Any]:
    status = path.stat()
    return {
        "path": label or str(path),
        "sha256": sha256_file(path),
        "size": status.st_size,
        "mtime_ns": status.st_mtime_ns,
    }


def write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def parse_json(text: str, label: str) -> Any:
    try:
        return json.loads(text)
    except ValueError as error:
        raise ReportError(f"{label} did not produce JSON: {error}") from error


def first_line(text: str) -> str:
    return next((line.strip() for line in text.splitlines() if line.strip()), "")


def run_tool(
    command: Sequence[str], timeout: float
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(command),
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise ToolTimeout(
            f"{command[0]} timed out after {timeout} seconds",
            partial_output(error.stdout),
            partial_output(error.stderr),
        ) from error
    except OSError as error:
        raise ReportError(f"cannot run {command[0]}: {error}") from error


def parse_llvm_release(text: str) -> LlvmRelease:
    match = LLVM_VERSION.search(text)
    if match is None:
        raise ReportError(f"cannot identify an LLVM release in {first_line(text)!r}")
    version = (int(match["major"]), int(match["minor"]), int(match["patch"]))
    return LlvmRelease(match["apple"] is not None, version)


def compiler_release(compiler: dict[str, Any]) -> LlvmRelease:
    """Return the release CMake recorded for the instrumenting compiler."""
    match = re.match(r"(\d+)\.(\d+)\.(\d+)", str(compiler.get("version", "")))
    if compiler.get("id") not in ("Clang", "AppleClang") or match is None:
        raise ReportError(
            f"compiler {compiler.get('id')} {compiler.get('version')} is not a Clang release"
        )
    version = (int(match[1]), int(match[2]), int(match[3]))
    return LlvmRelease(compiler["id"] == "AppleClang", version)


def resolve_executable(name: str, value: str) -> Path:
    if not value:
        raise ReportError(f"{name} is not configured; pass --{name} explicitly")
    found = shutil.which(value)
    if found is None:
        raise ReportError(f"{name} {value!r} is not an executable")
    return Path(found).resolve()


def probe_llvm_tool(
    name: str, value: str, expected: LlvmRelease | None
) -> dict[str, Any]:
    path = resolve_executable(name, value)
    completed = run_tool([str(path), "--version"], PROBE_TIMEOUT_SECONDS)
    if completed.returncode != 0:
        raise ReportError(
            f"{path} --version failed with exit status {completed.returncode}: "
            f"{completed.stderr.strip()}"
        )
    output = completed.stdout + completed.stderr
    release = parse_llvm_release(output)
    if expected is not None and release != expected:
        raise ReportError(
            f"{name} at {path} is {release.label()} but the instrumented build used "
            f"{expected.label()}; raw profiles and coverage mappings require one release"
        )
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "release": release.label(),
        "version_output": first_line(output),
    }


def probe_ctest(value: str) -> dict[str, Any]:
    path = resolve_executable("ctest", value)
    completed = run_tool([str(path), "--version"], PROBE_TIMEOUT_SECONDS)
    if completed.returncode != 0 or "ctest version" not in completed.stdout:
        raise ReportError(f"{path} --version did not identify CTest")
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "version_output": first_line(completed.stdout),
    }


def validate_metadata(metadata: Any, build_dir: Path, path: Path) -> None:
    def refuse(reason: str) -> ReportError:
        return ReportError(f"{path}: {reason}")

    if not isinstance(metadata, dict) or metadata.get("schema") != METADATA_SCHEMA:
        raise refuse(f"expected schema {METADATA_SCHEMA}")
    if metadata.get("coverage_enabled") is not True:
        raise refuse("coverage instrumentation is not enabled")
    for key in ("source_dir", "binary_dir", "ctest_command"):
        if not isinstance(metadata.get(key), str) or not metadata[key]:
            raise refuse(f"missing {key}")
    for key in ("source_revision", "llvm_profdata", "llvm_cov"):
        if not isinstance(metadata.get(key, ""), str):
            raise refuse(f"{key} must be a string")
    if Path(os.path.realpath(metadata["binary_dir"])) != build_dir:
        raise refuse(
            f"describes build directory {metadata['binary_dir']}, not {build_dir}"
        )
    compiler = metadata.get("compiler")
    if not isinstance(compiler, dict) or not all(
        isinstance(compiler.get(key), str) and compiler[key]
        for key in ("id", "version", "path")
    ):
        raise refuse("missing compiler id, version or path")
    targets = metadata.get("instrumented_targets")
    if (
        not isinstance(targets, list)
        or not targets
        or not all(
            isinstance(target, dict)
            and isinstance(target.get("target"), str)
            and isinstance(target.get("file"), str)
            and Path(target["file"]).is_absolute()
            for target in targets
        )
    ):
        raise refuse("missing instrumented target inventory")
    for key in ("report_scope", "excluded_source_prefixes", "test_working_dirs"):
        value = metadata.get(key)
        if not isinstance(value, list) or not all(
            isinstance(item, str) and item for item in value
        ):
            raise refuse(f"{key} must be a list of non-empty strings")
    if not metadata["report_scope"]:
        raise refuse("report_scope is empty")
    for key in ("excluded_targets", "excluded_sources", "absent_targets"):
        if not isinstance(metadata.get(key), list):
            raise refuse(f"missing {key} inventory")


def load_metadata(build_dir: Path) -> tuple[Path, dict[str, Any]]:
    path = build_dir / METADATA_RELATIVE_PATH
    if not path.is_file():
        raise ReportError(
            f"{path} is missing: configure the root project with "
            "-DFORESIGHT_NATIVE_COVERAGE=ON and build it before reporting"
        )
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReportError(f"{path} is not readable JSON: {error}") from error
    validate_metadata(metadata, build_dir, path)
    return path, metadata


def resolve_source_revision(recorded: str, argument: str | None) -> str:
    if argument and recorded and argument != recorded:
        raise ReportError(
            f"--source-revision {argument} contradicts the configured revision {recorded}"
        )
    revision = argument or recorded
    if not revision:
        raise ReportError(
            "source revision is unknown: pass --source-revision or configure with "
            "-DFORESIGHT_BUILD_REVISION=<commit>"
        )
    return revision


def prepare_output_dir(path: Path) -> Path:
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ReportError(f"output path {path} must be a real directory")
    if path.exists() and any(path.iterdir()):
        raise ReportError(
            f"output directory {path} is not empty; reports never reuse earlier artifacts"
        )
    path.mkdir(parents=True, exist_ok=True)
    return Path(os.path.realpath(path))


def _under(relative: str, prefix: str) -> bool:
    prefix = prefix.strip("/")
    return relative == prefix or relative.startswith(prefix + "/")


def repository_path(
    path_text: str,
    source_dir: Path,
    binary_dir: Path,
    scope: Sequence[str],
    excluded_prefixes: Sequence[str],
    suffixes: frozenset[str] | None = None,
) -> str | None:
    """Return the repository-relative path of an in-scope, repository-owned source.

    Build-tree (generated or fetched) files, Swift sources, excluded vendor
    prefixes and anything outside ``scope`` return ``None``. ``source_dir`` and
    ``binary_dir`` must already be real paths.
    """
    path = Path(os.path.realpath(path_text))
    if path.is_relative_to(binary_dir) or path.suffix == ".swift":
        return None
    if suffixes is not None and path.suffix not in suffixes:
        return None
    if not path.is_relative_to(source_dir):
        return None
    relative = path.relative_to(source_dir).as_posix()
    if any(_under(relative, prefix) for prefix in excluded_prefixes):
        return None
    if not any(_under(relative, prefix) for prefix in scope):
        return None
    return relative


def export_files(export: Any) -> list[dict[str, Any]]:
    if (
        not isinstance(export, dict)
        or export.get("type") != "llvm.coverage.json.export"
        or not isinstance(export.get("data"), list)
        or not export["data"]
    ):
        raise ReportError(
            "llvm-cov export did not produce llvm.coverage.json.export data"
        )
    files: list[dict[str, Any]] = []
    for unit in export["data"]:
        if not isinstance(unit, dict) or not isinstance(unit.get("files"), list):
            raise ReportError("llvm-cov export data lacks a files list")
        for entry in unit["files"]:
            if (
                not isinstance(entry, dict)
                or not isinstance(entry.get("filename"), str)
                or not isinstance(entry.get("summary"), dict)
            ):
                raise ReportError(
                    "llvm-cov export file entry lacks filename or summary"
                )
            files.append(entry)
    return files


def _metric(count: int, covered: int) -> dict[str, Any]:
    percent = round(100.0 * covered / count, 2) if count else None
    return {"count": count, "covered": covered, "percent": percent}


def metric_summary(summary: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for metric in COVERAGE_METRICS:
        value = summary.get(metric)
        if value is None:
            continue  # Older llvm-cov releases omit branch summaries.
        count = value.get("count") if isinstance(value, dict) else None
        covered = value.get("covered") if isinstance(value, dict) else None
        if (
            not isinstance(count, int)
            or not isinstance(covered, int)
            or not 0 <= covered <= count
        ):
            raise ReportError(f"invalid {metric} summary in llvm-cov export")
        result[metric] = _metric(count, covered)
    return result


def total_metrics(
    summaries: Sequence[dict[str, dict[str, Any]]],
) -> dict[str, dict[str, Any]]:
    totals: dict[str, dict[str, Any]] = {}
    for metric in COVERAGE_METRICS:
        present = [summary[metric] for summary in summaries if metric in summary]
        if present:
            totals[metric] = _metric(
                sum(item["count"] for item in present),
                sum(item["covered"] for item in present),
            )
    return totals


def verify_llvm_totals(
    exported: dict[str, Any], totals: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    """Refuse totals that differ from llvm-cov's own totals for the same export.

    The filtered export holds exactly the in-scope files, so llvm-cov's totals
    must equal the sum of those files' summaries for every reported metric.
    """
    units = exported["data"]
    if len(units) != 1 or not isinstance(units[0].get("totals"), dict):
        raise ReportError(
            "llvm-cov export must contain exactly one data unit with totals"
        )
    llvm_totals: dict[str, Any] = units[0]["totals"]
    reported = metric_summary(llvm_totals)
    if reported != totals:
        differing = sorted(
            metric
            for metric in COVERAGE_METRICS
            if reported.get(metric) != totals.get(metric)
        )
        raise ReportError(
            "recomputed coverage totals differ from llvm-cov export totals for "
            + ", ".join(
                f"{metric} ({totals.get(metric)} != {reported.get(metric)})"
                for metric in differing
            )
        )
    return llvm_totals


def inventory_objects(targets: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    objects: list[dict[str, Any]] = []
    for target in targets:
        path = Path(target["file"])
        if not path.is_file():
            raise ReportError(
                f"instrumented target {target['target']} has no built artifact at {path}; "
                "build the coverage configuration before reporting"
            )
        objects.append(
            {
                "target": target["target"],
                "type": target.get("type"),
                **file_identity(path),
            }
        )
    return objects


def create_profile_dir(output_dir: Path) -> Path:
    if "%" in str(output_dir):
        raise ReportError(
            f"output directory {output_dir} contains '%', which LLVM_PROFILE_FILE expands"
        )
    path = Path(tempfile.mkdtemp(prefix="raw-profiles-", dir=output_dir))
    path.chmod(0o700)
    return path


def inventory_profiles(profile_dir: Path) -> list[dict[str, Any]]:
    profiles: list[dict[str, Any]] = []
    for entry in sorted(profile_dir.iterdir()):
        if entry.is_symlink() or not entry.is_file() or entry.suffix != ".profraw":
            raise ReportError(
                f"unexpected entry {entry.name} in the private raw-profile directory"
            )
        profiles.append(file_identity(entry))
    return profiles


def find_stray_profiles(
    directories: Sequence[str], since_ns: int
) -> list[dict[str, Any]]:
    """Report ``default.profraw`` files directly in the given directories.

    Only the CTest working directories recorded by CMake are searched. A process
    that drops LLVM_PROFILE_FILE writes ``default.profraw`` in its own working
    directory, so one running anywhere else is not found. Found files are never
    merged: their origin cannot be bound to this run.
    """
    stray: list[dict[str, Any]] = []
    for directory in directories:
        path = Path(directory) / "default.profraw"
        if path.is_file():
            mtime = path.stat().st_mtime_ns
            stray.append(
                {
                    "path": str(path),
                    "mtime_ns": mtime,
                    "written_during_run": mtime >= since_ns,
                }
            )
    return stray


def run_ctest(
    ctest: str,
    build_dir: Path,
    profile_dir: Path,
    jobs: int,
    timeout: float,
    log_path: Path,
) -> tuple[list[str], int]:
    command = [
        ctest,
        "--test-dir",
        str(build_dir),
        "--output-on-failure",
        "--no-tests=error",
        "--parallel",
        str(jobs),
    ]
    environment = dict(os.environ)
    environment["LLVM_PROFILE_FILE"] = str(profile_dir / PROFILE_PATTERN)
    try:
        completed = subprocess.run(
            command,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        output = partial_output(error.output)
        log_path.write_text(output, encoding="utf-8")
        sys.stdout.write(output)
        raise ReportError(
            f"root CTest exceeded {timeout} seconds; partial output is in {log_path}"
        ) from error
    except OSError as error:
        raise ReportError(f"cannot run {ctest}: {error}") from error
    log_path.write_bytes(completed.stdout)
    sys.stdout.write(completed.stdout.decode(errors="replace"))
    sys.stdout.flush()
    return command, completed.returncode


def run_llvm(
    command: list[str],
    label: str,
    log_path: Path,
    timeout: float,
    commands: list[dict[str, Any]],
) -> subprocess.CompletedProcess[str]:
    try:
        completed = run_tool(command, timeout)
    except ToolTimeout as error:
        with log_path.open("a", encoding="utf-8") as log:
            log.write(
                f"$ {shlex.join(command)}\ntimed out after {timeout} seconds\n"
                f"--- partial stderr\n{error.stderr}\n"
            )
        commands.append({"label": label, "argv": command, "exit_status": "timeout"})
        raise ReportError(
            f"{label} timed out after {timeout} seconds; partial output is in {log_path}"
        ) from error
    with log_path.open("a", encoding="utf-8") as log:
        log.write(
            f"$ {shlex.join(command)}\nexit status {completed.returncode}\n{completed.stderr}\n"
        )
    commands.append(
        {"label": label, "argv": command, "exit_status": completed.returncode}
    )
    if completed.returncode != 0 or STALE_PROFILE.search(completed.stderr):
        raise ReportError(
            f"{label} failed (exit status {completed.returncode}) or reported stale "
            f"profile data; see {log_path}"
        )
    return completed


def collect_coverage(
    args: argparse.Namespace,
    build_dir: Path,
    metadata: dict[str, Any],
    output_dir: Path,
    record: dict[str, Any],
) -> int:
    source_dir = Path(os.path.realpath(metadata["source_dir"]))
    if not source_dir.is_dir():
        raise ReportError(
            f"source directory {source_dir} from the metadata does not exist"
        )
    scope = metadata["report_scope"]
    excluded_prefixes = metadata["excluded_source_prefixes"]
    expected = compiler_release(metadata["compiler"])
    tools = record["tools"]
    tools["compiler"] = probe_llvm_tool(
        "compiler", metadata["compiler"]["path"], expected
    )
    tools["llvm-profdata"] = probe_llvm_tool(
        "llvm-profdata",
        args.llvm_profdata or metadata.get("llvm_profdata", ""),
        expected,
    )
    tools["llvm-cov"] = probe_llvm_tool(
        "llvm-cov", args.llvm_cov or metadata.get("llvm_cov", ""), expected
    )
    tools["ctest"] = probe_ctest(args.ctest or metadata["ctest_command"])

    objects = inventory_objects(metadata["instrumented_targets"])
    record["objects"] = {
        "built_by_this_tool": False,
        "unchanged_during_run": None,
        "instrumented": objects,
        "excluded_targets": metadata["excluded_targets"],
        "absent_targets": metadata["absent_targets"],
    }
    profile_dir = create_profile_dir(output_dir)
    record["profiles"] = {
        "directory": str(profile_dir),
        "pattern": PROFILE_PATTERN,
        "created_by_this_run": True,
        "files": [],
        "empty_files": [],
        "stray_default_profiles": [],
        "stray_search_directories": metadata["test_working_dirs"],
    }

    started_ns = time.time_ns()
    command, ctest_status = run_ctest(
        tools["ctest"]["path"],
        build_dir,
        profile_dir,
        args.jobs,
        args.ctest_timeout,
        output_dir / "ctest.log",
    )
    record["ctest"] = {
        "command": command,
        "exit_status": ctest_status,
        "log": "ctest.log",
        "profile_environment": f"LLVM_PROFILE_FILE={profile_dir / PROFILE_PATTERN}",
    }
    after = inventory_objects(metadata["instrumented_targets"])
    if [item["sha256"] for item in after] != [item["sha256"] for item in objects]:
        raise ReportError(
            "instrumented objects changed during the CTest run; profiles cannot be "
            "attributed to the inventoried bytes"
        )
    record["objects"]["unchanged_during_run"] = True
    profiles = inventory_profiles(profile_dir)
    stray = find_stray_profiles(metadata["test_working_dirs"], started_ns)
    record["profiles"]["files"] = profiles
    # With %m the profile runtime creates no file at startup: a process that
    # ends without flushing (_exit, a signal, abort) leaves no file and cannot
    # be detected here. A 0-byte file means a process stopped after the runtime
    # opened its file but before it wrote data. It holds nothing to merge.
    empty = [item for item in profiles if item["size"] == 0]
    record["profiles"]["empty_files"] = empty
    mergeable = [item for item in profiles if item["size"] > 0]
    record["profiles"]["stray_default_profiles"] = stray
    if not mergeable:
        raise ReportError(
            f"root CTest wrote no nonempty raw profiles to {profile_dir}; the build "
            "is not instrumented or no instrumented process flushed its profile"
        )
    if empty:
        print(
            f"native coverage: {len(empty)} empty raw profile files are listed in the "
            "inventory and not merged; the processes that left them contribute no coverage",
            file=sys.stderr,
        )
    if any(item["written_during_run"] for item in stray):
        print(
            "native coverage: some tests wrote default.profraw outside the private "
            "directory; that data is not merged",
            file=sys.stderr,
        )

    log_path = output_dir / "llvm-tools.log"
    commands = record["commands"]
    list_path = output_dir / "raw-profiles.txt"
    list_path.write_text(
        "".join(f"{item['path']}\n" for item in mergeable), encoding="utf-8"
    )
    merged = output_dir / "coverage.profdata"
    run_llvm(
        [
            tools["llvm-profdata"]["path"],
            "merge",
            "-sparse",
            f"--input-files={list_path}",
            "-o",
            str(merged),
        ],
        "llvm-profdata merge",
        log_path,
        args.llvm_timeout,
        commands,
    )

    binaries = [item["path"] for item in objects]

    def llvm_cov(
        subcommand: str, *options: str, sources: Sequence[str] = ()
    ) -> list[str]:
        command = [
            tools["llvm-cov"]["path"],
            subcommand,
            f"-instr-profile={merged}",
            *options,
            binaries[0],
        ]
        for binary in binaries[1:]:
            command += ["-object", binary]
        return command + list(sources)

    discovery = run_llvm(
        llvm_cov("export", "-summary-only"),
        "llvm-cov export -summary-only",
        log_path,
        args.llvm_timeout,
        commands,
    )
    # llvm-cov keys coverage by the recorded file name, so one repository file
    # reached through two names (for example via a "..") has two separate
    # records. Keeping only one would silently drop the other's data.
    names: dict[str, dict[str, dict[str, Any]]] = collections.defaultdict(dict)
    for entry in export_files(
        parse_json(discovery.stdout, "llvm-cov export -summary-only")
    ):
        relative = repository_path(
            entry["filename"], source_dir, build_dir, scope, excluded_prefixes
        )
        if relative is None:
            continue
        if entry["filename"] in names[relative]:
            raise ReportError(
                f"llvm-cov export -summary-only lists {entry['filename']} "
                "more than once"
            )
        names[relative][entry["filename"]] = metric_summary(entry["summary"])
    aliased = {
        relative: sorted(found) for relative, found in names.items() if len(found) > 1
    }
    if aliased:
        raise ReportError(
            "coverage mappings name a repository file through more than one path; "
            "llvm-cov counts each name separately and the names are not merged: "
            + "; ".join(
                f"{relative} as {', '.join(aliased[relative])}"
                for relative in sorted(aliased)
            )
        )
    if not names:
        raise ReportError(
            "coverage mappings contain no repository-owned source in the report scope"
        )
    in_scope = {
        relative: next(iter(found.items())) for relative, found in names.items()
    }
    sources = [in_scope[relative][0] for relative in sorted(in_scope)]

    export = run_llvm(
        llvm_cov("export", sources=sources),
        "llvm-cov export",
        log_path,
        args.llvm_timeout,
        commands,
    )
    (output_dir / "coverage.json").write_text(export.stdout, encoding="utf-8")
    exported = parse_json(export.stdout, "llvm-cov export")
    # llvm-cov normalizes filter paths and matches them exactly against the
    # recorded names; a filter that matches nothing yields a zero-count entry
    # and exit status 0. The filtered export must reproduce discovery exactly.
    per_file: list[dict[str, Any]] = []
    for entry in export_files(exported):
        relative = repository_path(
            entry["filename"], source_dir, build_dir, scope, excluded_prefixes
        )
        if (
            relative is None
            or relative not in in_scope
            or any(item["path"] == relative for item in per_file)
        ):
            raise ReportError(
                f"llvm-cov export returned unexpected file {entry['filename']}"
            )
        discovered_name, discovered_metrics = in_scope[relative]
        if entry["filename"] != discovered_name:
            raise ReportError(
                f"llvm-cov export returned {entry['filename']} for {relative}, but "
                f"discovery recorded {discovered_name}; the source filter did not "
                "select the recorded coverage"
            )
        metrics = metric_summary(entry["summary"])
        if metrics != discovered_metrics:
            raise ReportError(
                f"llvm-cov export summary for {relative} differs from discovery "
                f"({metrics} != {discovered_metrics})"
            )
        per_file.append({"path": relative, "metrics": metrics})
    omitted = sorted(in_scope.keys() - {item["path"] for item in per_file})
    if omitted:
        raise ReportError(
            "llvm-cov export omitted discovered sources: " + ", ".join(omitted)
        )
    per_file.sort(key=lambda item: item["path"])

    source_files: list[dict[str, Any]] = []
    for item in per_file:
        path = source_dir / item["path"]
        if not path.is_file():
            raise ReportError(
                f"covered source {item['path']} is missing from {source_dir}"
            )
        source_files.append(file_identity(path, item["path"]))
    newest_object_ns = max(item["mtime_ns"] for item in objects)
    record["source"]["files"] = source_files
    record["source"]["modified_after_newest_object"] = [
        item["path"] for item in source_files if item["mtime_ns"] > newest_object_ns
    ]

    report = run_llvm(
        llvm_cov("report", sources=sources),
        "llvm-cov report",
        log_path,
        args.llvm_timeout,
        commands,
    )
    (output_dir / "coverage-report.txt").write_text(report.stdout, encoding="utf-8")
    html_dir = output_dir / "html"
    run_llvm(
        llvm_cov("show", "-format=html", f"-output-dir={html_dir}", sources=sources),
        "llvm-cov show",
        log_path,
        args.llvm_timeout,
        commands,
    )
    if not (html_dir / "index.html").is_file():
        raise ReportError(f"llvm-cov show did not write {html_dir / 'index.html'}")

    totals = total_metrics([item["metrics"] for item in per_file])
    llvm_totals = verify_llvm_totals(exported, totals)
    record["coverage"] = {
        "totals": totals,
        "llvm_cov_totals": llvm_totals,
        "files": per_file,
    }
    write_json(
        output_dir / "summary.json",
        {
            "schema": COVERAGE_SUMMARY_SCHEMA,
            "gate": "report-only",
            "source_revision": record["source"]["revision"],
            "ctest_exit_status": ctest_status,
            "empty_profile_count": len(empty),
            "totals": totals,
            "files": per_file,
        },
    )
    record["artifacts"] = [
        file_identity(output_dir / name, name)
        for name in (
            "coverage.json",
            "coverage.profdata",
            "coverage-report.txt",
            "summary.json",
            "ctest.log",
            "llvm-tools.log",
            "raw-profiles.txt",
            "html/index.html",
        )
    ]
    record["html_file_count"] = sum(1 for path in html_dir.rglob("*") if path.is_file())
    record["status"] = "complete" if ctest_status == 0 else "tests_failed"
    return EXIT_OK if ctest_status == 0 else EXIT_TESTS_FAILED


def run_coverage(args: argparse.Namespace) -> int:
    build_dir = Path(os.path.realpath(args.build_dir))
    metadata_path, metadata = load_metadata(build_dir)
    revision = resolve_source_revision(
        metadata.get("source_revision", ""), args.source_revision
    )
    output_dir = prepare_output_dir(Path(args.output_dir))
    record: dict[str, Any] = {
        "schema": COVERAGE_RECORD_SCHEMA,
        "kind": "native-coverage",
        "gate": "report-only",
        "thresholds": None,
        "status": "running",
        "error": None,
        "started_at": utc_now(),
        "finished_at": None,
        "source": {
            "dir": metadata["source_dir"],
            "revision": revision,
            "scope": metadata["report_scope"],
            "excluded_source_prefixes": metadata["excluded_source_prefixes"],
            "excluded_sources": metadata["excluded_sources"],
            "files": [],
        },
        "build": {
            "dir": str(build_dir),
            "build_type": metadata.get("build_type"),
            "generator": metadata.get("generator"),
            "cmake_version": metadata.get("cmake_version"),
            "instrumentation": metadata.get("instrumentation"),
            "metadata": file_identity(metadata_path),
        },
        "tools": {},
        "objects": {},
        "profiles": {},
        "ctest": None,
        "coverage": None,
        "artifacts": [],
        "commands": [],
    }
    try:
        exit_code = collect_coverage(args, build_dir, metadata, output_dir, record)
    except (ReportError, OSError) as error:
        record["status"] = "infrastructure_failure"
        record["error"] = str(error)
        print(f"native coverage: {error}", file=sys.stderr)
        exit_code = EXIT_INFRASTRUCTURE
    record["finished_at"] = utc_now()
    write_json(output_dir / "coverage-record.json", record)
    print(
        f"native coverage record: {output_dir / 'coverage-record.json'} ({record['status']})"
    )
    return exit_code


def _repository_relative_argument(value: str, label: str) -> str:
    normalized = PurePosixPath(os.path.normpath(value).replace(os.sep, "/"))
    if normalized.is_absolute() or ".." in normalized.parts or str(normalized) == ".":
        raise ReportError(f"{label} {value!r} must be a repository-relative path")
    return normalized.as_posix()


def select_tidy_files(
    database: Sequence[Any],
    source_dir: Path,
    build_dir: Path,
    scope: Sequence[str],
    explicit: Sequence[str],
) -> tuple[list[str], dict[str, int]]:
    """Select repository-owned translation units in ``scope`` from a compile database."""
    counts: collections.Counter[str] = collections.Counter()
    for entry in database:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("file"), str)
            or not isinstance(entry.get("directory"), str)
        ):
            raise ReportError("compile_commands.json entry lacks file or directory")
        path = Path(entry["file"])
        if not path.is_absolute():
            path = Path(entry["directory"]) / path
        relative = repository_path(
            str(path),
            source_dir,
            build_dir,
            scope,
            TIDY_EXCLUDED_PREFIXES,
            TIDY_SUFFIXES,
        )
        if relative is not None:
            counts[relative] += 1
    if explicit:
        selected = sorted(
            {_repository_relative_argument(item, "--file") for item in explicit}
        )
        missing = [item for item in selected if item not in counts]
        if missing:
            raise ReportError(
                "explicit files are not in-scope repository entries of compile_commands.json: "
                + ", ".join(missing)
            )
    else:
        selected = sorted(counts)
    if not selected:
        raise ReportError(
            "compile_commands.json has no repository-owned files in the scope"
        )
    return selected, {item: counts[item] for item in selected}


def parse_diagnostics(text: str) -> list[dict[str, Any]]:
    diagnostics: list[dict[str, Any]] = []
    for line in text.splitlines():
        match = DIAGNOSTIC.match(line)
        if match is None:
            continue
        check = match["check"]
        if check is not None:
            check = ",".join(
                part for part in check.split(",") if part != "-warnings-as-errors"
            )
        diagnostics.append(
            {
                "path": match["path"],
                "line": int(match["line"]),
                "column": int(match["column"]),
                "severity": match["severity"],
                "message": match["message"],
                "check": check,
            }
        )
    return diagnostics


def _relativize(path_text: str, source_dir: Path) -> str:
    path = Path(os.path.realpath(path_text))
    return (
        path.relative_to(source_dir).as_posix()
        if path.is_relative_to(source_dir)
        else str(path)
    )


def classify_tidy_result(
    relative: str, returncode: int, stdout: str, stderr: str, source_dir: Path
) -> dict[str, Any]:
    """Separate clang-tidy findings from failures to analyze the translation unit."""
    diagnostics = []
    for diagnostic in parse_diagnostics(stdout):
        diagnostic["path"] = _relativize(diagnostic["path"], source_dir)
        if diagnostic not in diagnostics:
            diagnostics.append(diagnostic)
    compiler_errors = [
        item
        for item in diagnostics
        if item["severity"] == "error"
        and (item["check"] is None or item["check"].startswith("clang-diagnostic-"))
    ]
    findings = [item for item in diagnostics if item not in compiler_errors]
    if returncode < 0:
        status, reason = "tool_failure", f"terminated by signal {-returncode}"
    elif compiler_errors or "Error while processing" in stderr:
        status, reason = (
            "analysis_error",
            "the translation unit did not compile; findings incomplete",
        )
    elif returncode != 0:
        status, reason = (
            "tool_failure",
            f"exit status {returncode} without compiler diagnostics",
        )
    else:
        status, reason = "analyzed", None
    return {
        "file": relative,
        "status": status,
        "reason": reason,
        "exit_status": returncode,
        "findings": findings,
        "compiler_errors": compiler_errors,
    }


def analyze_file(
    clang_tidy: str,
    build_dir: Path,
    source_dir: Path,
    relative: str,
    config_args: Sequence[str],
    timeout: float,
) -> dict[str, Any]:
    # Findings never change the exit status; a nonzero status is a tool failure.
    command = [
        clang_tidy,
        "-p",
        str(build_dir),
        "--quiet",
        "--warnings-as-errors=-*",
        *config_args,
        str(source_dir / relative),
    ]
    failure: dict[str, Any] = {
        "file": relative,
        "status": "tool_failure",
        "exit_status": None,
        "findings": [],
        "compiler_errors": [],
        "command": command,
        "stdout": "",
        "stderr": "",
    }
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        return {
            **failure,
            "reason": f"timed out after {timeout} seconds",
            "stdout": partial_output(error.stdout),
            "stderr": partial_output(error.stderr),
        }
    except OSError as error:
        return {**failure, "reason": f"cannot run clang-tidy: {error}"}
    result = classify_tidy_result(
        relative, completed.returncode, completed.stdout, completed.stderr, source_dir
    )
    result.update(command=command, stdout=completed.stdout, stderr=completed.stderr)
    return result


def parse_enabled_checks(text: str) -> list[str]:
    """Return the check names listed by ``clang-tidy --list-checks``."""
    checks: list[str] = []
    listing = False
    for line in text.splitlines():
        if line.strip() == "Enabled checks:":
            listing = True
        elif listing and line.strip():
            checks.append(line.strip())
    return checks


def dump_tidy_configs(
    clang_tidy: str,
    files: Sequence[str],
    source_dir: Path,
    config_args: Sequence[str],
    output_dir: Path,
) -> list[dict[str, Any]]:
    config_dir = output_dir / "clang-tidy-config"
    config_dir.mkdir()
    samples: dict[str, str] = {}
    for relative in files:
        samples.setdefault(PurePosixPath(relative).parent.as_posix(), relative)
    configs: list[dict[str, Any]] = []
    for index, (directory, sample) in enumerate(sorted(samples.items())):
        completed = run_tool(
            [clang_tidy, "--dump-config", *config_args, str(source_dir / sample)],
            PROBE_TIMEOUT_SECONDS,
        )
        if completed.returncode != 0:
            raise ReportError(
                f"clang-tidy --dump-config failed for {sample}: {completed.stderr.strip()}"
            )
        path = config_dir / f"{index:03d}.yaml"
        path.write_text(completed.stdout, encoding="utf-8")
        # Compiler diagnostics alone are not checks: clang-tidy then refuses
        # every file ("no checks enabled"), which must not read as no findings.
        listed = run_tool(
            [clang_tidy, "--list-checks", *config_args, str(source_dir / sample)],
            PROBE_TIMEOUT_SECONDS,
        )
        checks = parse_enabled_checks(listed.stdout)
        output = listed.stdout + listed.stderr
        said = (
            "No checks enabled."
            if "No checks enabled." in output
            else first_line(output)
        )
        # clang-tidy prints "No checks enabled." to stderr and exits 1; any other
        # nonzero status, and any signal, is a tool failure, not a configuration.
        if listed.returncode < 0 or (
            listed.returncode != 0 and (checks or said != "No checks enabled.")
        ):
            raise ReportError(
                f"clang-tidy --list-checks failed for {sample} with "
                + (
                    f"signal {-listed.returncode}"
                    if listed.returncode < 0
                    else f"exit status {listed.returncode}"
                )
                + f": {listed.stderr.strip() or said}"
            )
        if not checks:
            raise ReportError(
                f"the effective clang-tidy configuration for {directory} enables no "
                f"checks; pass --checks or --config-file (clang-tidy said: {said!r})"
            )
        configs.append(
            {
                "directory": directory,
                "sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(),
                "path": path.relative_to(output_dir).as_posix(),
                "checks": checks,
            }
        )
    return configs


def load_tidy_baseline(path: Path) -> dict[str, Any]:
    try:
        baseline = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReportError(f"cannot read clang-tidy baseline {path}: {error}") from error
    if (
        not isinstance(baseline, dict)
        or baseline.get("schema") != TIDY_RECORD_SCHEMA
        or not isinstance(baseline.get("findings"), list)
        or not isinstance(baseline.get("files"), list)
    ):
        raise ReportError(f"{path} is not a {TIDY_RECORD_SCHEMA} record")
    for finding in baseline["findings"]:
        if (
            not isinstance(finding, dict)
            or not isinstance(finding.get("path"), str)
            or not isinstance(finding.get("message"), str)
            or not isinstance(finding.get("translation_unit"), str)
            or not isinstance(finding.get("check"), (str, type(None)))
            or not isinstance(finding.get("translation_units", []), list)
            or not all(
                isinstance(unit, str) for unit in finding.get("translation_units", [])
            )
        ):
            raise ReportError(f"{path} contains a malformed finding")
    baseline["_sha256"] = sha256_file(path)
    baseline["_path"] = str(path)
    return baseline


def finding_key(finding: dict[str, Any]) -> tuple[str, str, str]:
    # Line numbers are excluded so unrelated edits do not turn findings into "new".
    return (finding["path"], finding["check"] or "", finding["message"])


def finding_units(finding: dict[str, Any]) -> list[str]:
    return finding.get("translation_units") or [finding["translation_unit"]]


def deduplicate_findings(findings: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    """Merge findings reported identically by several translation units.

    A header finding is reported once per including translation unit; it is one
    finding at (path, line, column, check, message). ``translation_units`` keeps
    every reporting unit and ``translation_unit`` the first, for older readers.
    """
    merged: dict[tuple[Any, ...], dict[str, Any]] = {}
    for finding in findings:
        key = (
            finding["path"],
            finding.get("line"),
            finding.get("column"),
            finding["check"] or "",
            finding["message"],
        )
        entry = merged.get(key)
        if entry is None:
            entry = merged[key] = {
                name: value
                for name, value in finding.items()
                if name not in ("translation_unit", "translation_units", "scope")
            }
            entry["translation_units"] = []
        for unit in finding_units(finding):
            if unit not in entry["translation_units"]:
                entry["translation_units"].append(unit)
    result = []
    def order(key: tuple[Any, ...]) -> tuple[Any, ...]:
        path, line, column, check, message = key
        line = line if isinstance(line, int) else -1
        column = column if isinstance(column, int) else -1
        return (path, line, column, check, message)

    for key in sorted(merged, key=order):
        entry = merged[key]
        entry["translation_units"].sort()
        entry["translation_unit"] = entry["translation_units"][0]
        result.append(entry)
    return result


def _owned_finding_path(
    path: str, scope: Sequence[str], excluded_prefixes: Sequence[str]
) -> bool:
    """Classify a recorded finding path; in-scope paths are recorded relative."""
    if PurePosixPath(path).is_absolute():
        return False
    return not any(_under(path, prefix) for prefix in excluded_prefixes) and any(
        _under(path, prefix) for prefix in scope
    )


def compare_with_baseline(
    current: dict[str, Any], baseline: dict[str, Any]
) -> dict[str, Any]:
    current_failed = {
        item["file"] for item in current["files"] if item["status"] != "analyzed"
    }
    baseline_failed = {
        item.get("file")
        for item in baseline["files"]
        if isinstance(item, dict) and item.get("status") != "analyzed"
    }
    not_compared = {
        item for item in current_failed | baseline_failed if isinstance(item, str)
    }
    baseline_source = baseline.get("source")
    if not isinstance(baseline_source, dict):
        baseline_source = {}
    baseline_scope = baseline_source.get("scope")
    if not isinstance(baseline_scope, list) or not all(
        isinstance(item, str) for item in baseline_scope
    ):
        baseline_scope = current["source"]["scope"]
    # Older records list every finding once per translation unit and include
    # out-of-scope paths; normalizing is idempotent for current records.
    recorded = baseline["findings"]
    owned = [
        item
        for item in recorded
        if _owned_finding_path(item["path"], baseline_scope, TIDY_EXCLUDED_PREFIXES)
    ]
    before_findings = deduplicate_findings(owned)
    # A header finding may be reported by several units; when any of them failed
    # in either run its key cannot be compared.
    skipped = {
        finding_key(item)
        for item in [*current["findings"], *before_findings]
        if any(unit in not_compared for unit in finding_units(item))
    }

    def counts(
        findings: Sequence[dict[str, Any]],
    ) -> collections.Counter[tuple[str, str, str]]:
        return collections.Counter(
            finding_key(item) for item in findings if finding_key(item) not in skipped
        )

    now, before = counts(current["findings"]), counts(before_findings)
    new: list[dict[str, Any]] = []
    resolved: list[dict[str, Any]] = []
    for key in sorted(now.keys() | before.keys()):
        entry = {
            "path": key[0],
            "check": key[1] or None,
            "message": key[2],
            "current": now[key],
            "baseline": before[key],
        }
        if now[key] > before[key]:
            new.append(entry)
        elif now[key] < before[key]:
            resolved.append(entry)
    differences = []
    baseline_tool = baseline.get("tool")
    if not isinstance(baseline_tool, dict):
        baseline_tool = {}
    if baseline_tool.get("release") != current["tool"]["release"]:
        differences.append("clang-tidy release differs")
    baseline_files = sorted(
        str(item.get("file")) for item in baseline["files"] if isinstance(item, dict)
    )
    if baseline_files != sorted(item["file"] for item in current["files"]):
        differences.append("analyzed file set differs")
    baseline_configs = baseline.get("configs")
    if not isinstance(baseline_configs, list):
        baseline_configs = []
    if [item.get("sha256") for item in baseline_configs if isinstance(item, dict)] != [
        item["sha256"] for item in current["configs"]
    ]:
        differences.append("effective clang-tidy configuration differs")
    return {
        "path": baseline["_path"],
        "sha256": baseline["_sha256"],
        "source_revision": baseline_source.get("revision"),
        "comparable": not differences,
        "differences": differences,
        "baseline_findings": {
            "recorded": len(recorded),
            "out_of_scope": len(recorded) - len(owned),
            "duplicates_merged": len(owned) - len(before_findings),
            "normalized": len(before_findings),
        },
        "not_compared_files": sorted(not_compared),
        "not_compared_keys": len(skipped),
        "new": new,
        "resolved": resolved,
        "unchanged": sum((now & before).values()),
    }


def tidy_summary_text(record: dict[str, Any]) -> str:
    summary = record["summary"]
    lines = [
        "clang-tidy report (report-only; findings never fail this command)",
        f"source revision: {record['source']['revision']}",
        f"clang-tidy: {record['tool']['release']} ({record['tool']['path']})",
        f"files: {summary['files']}  analyzed: {summary['analyzed']}  "
        f"analysis errors: {summary['analysis_errors']}  tool failures: {summary['tool_failures']}",
        f"findings: {summary['findings']} (repository scope, one per location)",
        f"excluded findings (outside scope): {summary['excluded_findings']}  "
        f"raw per-translation-unit findings: {summary['raw_findings']}",
    ]
    lines += [f"  {check}: {count}" for check, count in summary["by_check"].items()]
    baseline = record.get("baseline")
    if baseline:
        lines.append(
            f"baseline {baseline['source_revision']}: comparable={baseline['comparable']} "
            f"new={len(baseline['new'])} resolved={len(baseline['resolved'])} "
            f"unchanged={baseline['unchanged']}"
        )
        lines += [f"  difference: {item}" for item in baseline["differences"]]
    for item in record["files"]:
        if item["status"] != "analyzed":
            lines.append(f"{item['status']}: {item['file']}: {item['reason']}")
    return "\n".join(lines) + "\n"


def collect_tidy(
    args: argparse.Namespace,
    source_dir: Path,
    build_dir: Path,
    files: Sequence[str],
    entries: dict[str, int],
    config_args: Sequence[str],
    baseline: dict[str, Any] | None,
    output_dir: Path,
    record: dict[str, Any],
) -> int:
    clang_tidy = record["tool"]["path"]
    record["configs"] = dump_tidy_configs(
        clang_tidy, files, source_dir, config_args, output_dir
    )
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        results = list(
            executor.map(
                lambda relative: analyze_file(
                    clang_tidy,
                    build_dir,
                    source_dir,
                    relative,
                    config_args,
                    args.timeout,
                ),
                files,
            )
        )
    with (output_dir / "clang-tidy.log").open("w", encoding="utf-8") as log:
        for result in results:
            log.write(
                f"$ {shlex.join(result['command'])}\nexit status {result['exit_status']}\n"
                f"--- stdout\n{result['stdout']}--- stderr\n{result['stderr']}\n"
            )
    # Raw findings keep one entry per reporting translation unit, labelled with
    # whether the path is repository-owned and in the configured scope. Only
    # deduplicated in-scope findings form the summary and baseline counts.
    scope = record["source"]["scope"]
    raw_findings = []
    for result in results:
        if result["status"] != "analyzed":
            continue
        for finding in result["findings"]:
            path = Path(finding["path"])
            owned = repository_path(
                str(path if path.is_absolute() else source_dir / path),
                source_dir,
                build_dir,
                scope,
                TIDY_EXCLUDED_PREFIXES,
            )
            raw_findings.append(
                {
                    **finding,
                    "translation_unit": result["file"],
                    "scope": "repository" if owned is not None else "excluded",
                }
            )
    findings = deduplicate_findings(
        [item for item in raw_findings if item["scope"] == "repository"]
    )
    excluded = deduplicate_findings(
        [item for item in raw_findings if item["scope"] == "excluded"]
    )
    record["files"] = [
        {
            "file": result["file"],
            "status": result["status"],
            "reason": result["reason"],
            "exit_status": result["exit_status"],
            "compile_command_entries": entries[result["file"]],
            "finding_count": len(result["findings"])
            if result["status"] == "analyzed"
            else None,
            "compiler_errors": result["compiler_errors"],
        }
        for result in results
    ]
    record["findings"] = findings
    record["excluded_findings"] = excluded
    record["raw_findings"] = raw_findings
    statuses = collections.Counter(result["status"] for result in results)
    by_check = collections.Counter(item["check"] or "(none)" for item in findings)
    record["summary"] = {
        "files": len(results),
        "analyzed": statuses["analyzed"],
        "analysis_errors": statuses["analysis_error"],
        "tool_failures": statuses["tool_failure"],
        "findings": len(findings),
        "by_check": dict(sorted(by_check.items())),
        "excluded_findings": len(excluded),
        "raw_findings": len(raw_findings),
    }
    if baseline is not None:
        record["baseline"] = compare_with_baseline(record, baseline)
    (output_dir / "clang-tidy-summary.txt").write_text(
        tidy_summary_text(record), encoding="utf-8"
    )
    failed = [item for item in record["files"] if item["status"] != "analyzed"]
    if failed:
        record["status"] = "tool_failure"
        for item in failed:
            print(
                f"clang-tidy {item['status']}: {item['file']}: {item['reason']}",
                file=sys.stderr,
            )
        return EXIT_INFRASTRUCTURE
    record["status"] = "complete"
    return EXIT_OK


def run_clang_tidy(args: argparse.Namespace) -> int:
    source_dir = Path(os.path.realpath(args.source_dir))
    build_dir = Path(os.path.realpath(args.build_dir))
    if not source_dir.is_dir():
        raise ReportError(f"source directory {source_dir} does not exist")
    revision = resolve_source_revision("", args.source_revision)
    database_path = build_dir / "compile_commands.json"
    if not database_path.is_file():
        raise ReportError(
            f"{database_path} is missing: configure the build with "
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
        )
    database = parse_json(database_path.read_text(encoding="utf-8"), str(database_path))
    if not isinstance(database, list):
        raise ReportError(f"{database_path} is not a compile command list")
    scope = tuple(
        _repository_relative_argument(item, "--scope")
        for item in (args.scope or DEFAULT_TIDY_SCOPE)
    )
    files, entries = select_tidy_files(
        database, source_dir, build_dir, scope, args.file or ()
    )
    baseline = load_tidy_baseline(Path(args.baseline)) if args.baseline else None
    tool = probe_llvm_tool("clang-tidy", args.clang_tidy, None)
    config_args: list[str] = []
    config_identity = None
    if args.config_file:
        config_path = Path(args.config_file).resolve()
        if not config_path.is_file():
            raise ReportError(f"--config-file {config_path} does not exist")
        config_args = [f"--config-file={config_path}"]
        config_identity = file_identity(config_path)
    if args.checks is not None:
        if not args.checks.strip():
            raise ReportError("--checks must not be empty")
        config_args.append(f"--checks={args.checks}")
    output_dir = prepare_output_dir(Path(args.output_dir))
    record: dict[str, Any] = {
        "schema": TIDY_RECORD_SCHEMA,
        "kind": "clang-tidy",
        "gate": "report-only",
        "status": "running",
        "error": None,
        "started_at": utc_now(),
        "finished_at": None,
        "source": {
            "dir": str(source_dir),
            "revision": revision,
            "scope": list(scope),
            "excluded_prefixes": list(TIDY_EXCLUDED_PREFIXES),
            "files": [file_identity(source_dir / item, item) for item in files],
        },
        "build": {
            "dir": str(build_dir),
            "compile_commands": file_identity(database_path),
        },
        "tool": tool,
        "config_file": config_identity,
        "checks_argument": args.checks,
        "configs": [],
        "files": [],
        "findings": [],
        "excluded_findings": [],
        "raw_findings": [],
        "summary": None,
        "baseline": None,
    }
    try:
        exit_code = collect_tidy(
            args,
            source_dir,
            build_dir,
            files,
            entries,
            config_args,
            baseline,
            output_dir,
            record,
        )
    except (ReportError, OSError) as error:
        record["status"] = "infrastructure_failure"
        record["error"] = str(error)
        print(f"clang-tidy report: {error}", file=sys.stderr)
        exit_code = EXIT_INFRASTRUCTURE
    record["finished_at"] = utc_now()
    write_json(output_dir / "clang-tidy-record.json", record)
    print(
        f"clang-tidy record: {output_dir / 'clang-tidy-record.json'} ({record['status']})"
    )
    return exit_code


def _positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def _positive_float(value: str) -> float:
    number = float(value)
    if not number > 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0] if __doc__ else None
    )
    commands = parser.add_subparsers(dest="command", required=True)

    coverage = commands.add_parser(
        "coverage", help="run root CTest and report Clang coverage"
    )
    coverage.add_argument(
        "--build-dir", required=True, help="built coverage configuration"
    )
    coverage.add_argument(
        "--output-dir", required=True, help="absent or empty report directory"
    )
    coverage.add_argument(
        "--source-revision", help="source commit (else FORESIGHT_BUILD_REVISION)"
    )
    coverage.add_argument(
        "--llvm-profdata", default="", help="override the configured tool"
    )
    coverage.add_argument("--llvm-cov", default="", help="override the configured tool")
    coverage.add_argument("--ctest", default="", help="override the configured CTest")
    coverage.add_argument("--jobs", type=_positive_int, default=os.cpu_count() or 1)
    coverage.add_argument(
        "--ctest-timeout", type=_positive_float, default=DEFAULT_CTEST_TIMEOUT_SECONDS
    )
    coverage.add_argument(
        "--llvm-timeout", type=_positive_float, default=DEFAULT_LLVM_TIMEOUT_SECONDS
    )

    tidy = commands.add_parser(
        "clang-tidy", help="report clang-tidy findings for a file scope"
    )
    tidy.add_argument("--source-dir", required=True)
    tidy.add_argument(
        "--build-dir", required=True, help="directory with compile_commands.json"
    )
    tidy.add_argument(
        "--output-dir", required=True, help="absent or empty report directory"
    )
    tidy.add_argument(
        "--source-revision", help="source commit the build was configured from"
    )
    tidy.add_argument("--clang-tidy", default="clang-tidy")
    tidy.add_argument("--config-file", help="explicit clang-tidy configuration")
    tidy.add_argument(
        "--checks",
        help="clang-tidy --checks value, applied on top of the configuration",
    )
    tidy.add_argument(
        "--scope", action="append", help="repository directory (repeatable)"
    )
    tidy.add_argument(
        "--file", action="append", help="repository file to analyze (repeatable)"
    )
    tidy.add_argument(
        "--baseline", help="earlier clang-tidy-record.json to compare with"
    )
    tidy.add_argument("--jobs", type=_positive_int, default=os.cpu_count() or 1)
    tidy.add_argument(
        "--timeout", type=_positive_float, default=DEFAULT_TIDY_TIMEOUT_SECONDS
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "coverage":
            return run_coverage(args)
        return run_clang_tidy(args)
    except (ReportError, OSError) as error:
        print(f"native_quality_report {args.command}: {error}", file=sys.stderr)
        return EXIT_INFRASTRUCTURE


if __name__ == "__main__":
    sys.exit(main())
