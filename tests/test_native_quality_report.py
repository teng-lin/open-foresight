"""Record and CLI validation for tools/native_quality_report.py.

The end-to-end cases drive the real CLI against small executable stand-ins for
clang, llvm-profdata, llvm-cov, ctest and clang-tidy. They validate record
composition, freshness and failure classification only; they are not evidence
that real LLVM tools or the instrumented root build behave as expected.
"""

from __future__ import annotations

import hashlib
import json
import os
import signal
import stat
import sys
import textwrap
from pathlib import Path
from types import SimpleNamespace

import pytest

from tools import native_quality_report as nqr


def fake_tool(path: Path, body: str) -> str:
    path.write_text(
        f"#!{sys.executable}\nimport json, os, sys\n"
        "HERE = os.path.dirname(os.path.abspath(__file__))\n" + textwrap.dedent(body),
        encoding="utf-8",
    )
    path.chmod(0o755)
    return str(path)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


FAKE_PROFDATA = """
args = sys.argv[1:]
if args == ["--version"]:
    print(os.environ.get("FAKE_PROFDATA_VERSION", "Ubuntu LLVM version 18.1.3\\n  Optimized build."))
    sys.exit(0)
assert args[0] == "merge" and "-sparse" in args
listing = next(a for a in args if a.startswith("--input-files=")).split("=", 1)[1]
names = open(listing).read().split()
assert names and all(os.path.getsize(name) > 0 for name in names)
open(args[args.index("-o") + 1], "w").write("merged %d" % len(names))
"""

FAKE_COV = """
args = sys.argv[1:]
if args == ["--version"]:
    print("LLVM (http://llvm.org/):\\n  Ubuntu LLVM version 18.1.3")
    sys.exit(0)
sys.stderr.write(os.environ.get("FAKE_COV_STDERR", ""))
profile = next(a for a in args if a.startswith("-instr-profile=")).split("=", 1)[1]
assert open(profile).read().startswith("merged")
assert args.count("-object") == 1
def metric(count, covered):
    return {"count": count, "covered": covered, "percent": 100.0 * covered / count if count else 0}
files = []
for item in json.load(open(os.path.join(HERE, "files.json"))):
    summary = {name: metric(*item[name]) for name in ("lines", "functions", "regions", "branches")}
    files.append({"filename": item["filename"], "summary": summary})
sources = [a for a in args if a.endswith((".cpp", ".h", ".cc"))]
if sources:
    # Like llvm-cov: filters are normalized, then matched exactly against the
    # recorded names; an unmatched filter yields a zero-count entry.
    wanted = [os.path.normpath(a) for a in sources]
    known = {f["filename"] for f in files}
    files = [f for f in files if f["filename"] in wanted]
    files += [
        {"filename": name, "summary": {k: metric(0, 0) for k in ("lines", "functions", "regions", "branches")}}
        for name in wanted if name not in known
    ]
    drop = os.environ.get("FAKE_COV_DROP")
    if drop:
        files = [f for f in files if not f["filename"].endswith(drop)]
    if os.environ.get("FAKE_COV_SKEW"):
        for f in files:
            f["summary"]["lines"]["covered"] = 0
command = args[0]
if os.environ.get("FAKE_COV_SLEEP") == command:
    sys.stderr.write("partial llvm-cov stderr\\n")
    sys.stderr.flush()
    import time
    time.sleep(60)
totals = {}
for name in ("lines", "functions", "regions", "branches"):
    count = sum(f["summary"][name]["count"] for f in files)
    covered = sum(f["summary"][name]["covered"] for f in files)
    totals[name] = metric(count, covered)
totals["instantiations"] = metric(0, 0)
if os.environ.get("FAKE_COV_TOTALS_SKEW") and sources:
    totals["regions"] = metric(totals["regions"]["count"], totals["regions"]["covered"] + 1)
if os.environ.get("FAKE_COV_NO_TOTALS") and sources:
    del totals["lines"]
if command == "export":
    print(json.dumps({"type": "llvm.coverage.json.export", "version": "2.0.1",
                      "data": [{"files": files, "totals": totals}]}))
elif command == "report":
    print("Filename Lines Cover")
    for f in files:
        print(f["filename"])
elif command == "show":
    out = next(a for a in args if a.startswith("-output-dir=")).split("=", 1)[1]
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "index.html"), "w").write("<html></html>")
"""

FAKE_CTEST = """
args = sys.argv[1:]
if args == ["--version"]:
    print("ctest version 3.28.3\\n\\nCMake suite maintained and supported by Kitware.")
    sys.exit(0)
open(os.path.join(HERE, "ctest-ran"), "w").write(" ".join(args))
assert "--test-dir" in args and "--no-tests=error" in args
pattern = os.environ["LLVM_PROFILE_FILE"]
open(pattern.replace("%p", str(os.getpid())).replace("%m", "1234"), "wb").write(
    b"" if os.environ.get("FAKE_EMPTY_ONLY") else b"raw")
if os.environ.get("FAKE_EXTRA_EMPTY"):
    # A 0-byte file as left by a process stopped after the runtime opened its
    # file. Processes that never flush leave no file at all with %m.
    open(pattern.replace("%p", str(os.getpid())).replace("%m", "empty"), "wb").close()
print("1/1 Test #1: native_audio_pcm ...   Passed")
if os.environ.get("FAKE_CTEST_SLEEP"):
    sys.stdout.flush()
    import time
    time.sleep(60)
code = int(os.environ.get("FAKE_CTEST_EXIT", "0"))
if code:
    print("The following tests FAILED:\\n\\t1 - native_audio_pcm (Failed)")
sys.exit(code)
"""


@pytest.fixture
def coverage_tree(tmp_path: Path) -> SimpleNamespace:
    source = tmp_path / "src"
    build = tmp_path / "build"
    tools = tmp_path / "tools"
    for directory in (
        source / "native",
        source / "services/inference",
        source / "third_party",
        source / "tests/native",
        build / "native",
        tools,
    ):
        directory.mkdir(parents=True)
    native_cpp = source / "native/foresight_native.cpp"
    native_cpp.write_text("int f() { return 1; }\n")
    grounded = source / "services/inference/grounded.h"
    grounded.write_text("inline int g() { return 2; }\n")
    library = build / "native/libforesight_native.so"
    library.write_bytes(b"instrumented library")
    test_binary = build / "native/native_audio_pcm_test"
    test_binary.write_bytes(b"instrumented test")
    stale = build / "native/default.profraw"
    stale.write_bytes(b"old")
    os.utime(stale, ns=(1_000_000_000, 1_000_000_000))
    (tools / "files.json").write_text(
        json.dumps(
            [
                {
                    "filename": str(native_cpp),
                    "lines": [10, 7],
                    "functions": [2, 2],
                    "regions": [8, 5],
                    "branches": [4, 1],
                },
                {
                    "filename": str(source / "third_party/vendor.h"),
                    "lines": [100, 0],
                    "functions": [5, 0],
                    "regions": [9, 0],
                    "branches": [2, 0],
                },
                {
                    "filename": str(source / "tests/native/audio_pcm.cpp"),
                    "lines": [50, 50],
                    "functions": [3, 3],
                    "regions": [7, 7],
                    "branches": [0, 0],
                },
                {
                    "filename": str(build / "services/helper/generated/x.pb.cc"),
                    "lines": [200, 10],
                    "functions": [9, 1],
                    "regions": [20, 2],
                    "branches": [6, 1],
                },
                {
                    "filename": str(grounded),
                    "lines": [20, 10],
                    "functions": [4, 3],
                    "regions": [10, 4],
                    "branches": [0, 0],
                },
            ]
        )
    )
    metadata = {
        "schema": nqr.METADATA_SCHEMA,
        "coverage_enabled": True,
        "source_dir": str(source),
        "binary_dir": str(build),
        "source_revision": "",
        "build_type": "Debug",
        "generator": "Ninja",
        "cmake_version": "3.28.3",
        "ctest_command": fake_tool(tools / "ctest", FAKE_CTEST),
        "compiler": {
            "id": "Clang",
            "version": "18.1.3",
            "path": fake_tool(
                tools / "clang++", 'print("Ubuntu clang version 18.1.3")\n'
            ),
        },
        "llvm_profdata": fake_tool(tools / "llvm-profdata", FAKE_PROFDATA),
        "llvm_cov": fake_tool(tools / "llvm-cov", FAKE_COV),
        "instrumentation": {
            "compile_options": ["-fprofile-instr-generate", "-fcoverage-mapping"],
            "link_options": ["-fprofile-instr-generate"],
        },
        "report_scope": ["native", "services/helper", "services/inference"],
        "excluded_source_prefixes": ["third_party"],
        "excluded_sources": [{"path": "third_party", "reason": "vendored"}],
        "instrumented_targets": [
            {
                "target": "foresight_native",
                "type": "SHARED_LIBRARY",
                "file": str(library),
            },
            {
                "target": "native_audio_pcm_test",
                "type": "EXECUTABLE",
                "file": str(test_binary),
            },
        ],
        "excluded_targets": [{"target": "foresight_protocol", "reason": "generated"}],
        "absent_targets": ["foresight-audio"],
        "test_working_dirs": [str(build), str(build / "native")],
    }
    metadata_path = build / nqr.METADATA_RELATIVE_PATH
    metadata_path.parent.mkdir(parents=True)
    metadata_path.write_text(json.dumps(metadata))
    return SimpleNamespace(
        source=source,
        build=build,
        tools=tools,
        out=tmp_path / "reports",
        metadata=metadata,
        metadata_path=metadata_path,
        library=library,
        native_cpp=native_cpp,
        grounded=grounded,
        stale=stale,
    )


def coverage_args(tree: SimpleNamespace, *extra: str) -> list[str]:
    return [
        "coverage",
        "--build-dir",
        str(tree.build),
        "--output-dir",
        str(tree.out),
        "--source-revision",
        "abc123",
        "--jobs",
        "2",
        *extra,
    ]


def read_record(tree: SimpleNamespace) -> dict:
    return json.loads((tree.out / "coverage-record.json").read_text())


def test_coverage_record_binds_fresh_profiles_scope_and_tools(coverage_tree, capsys):
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_OK
    record = read_record(coverage_tree)
    out = coverage_tree.out.resolve()

    assert record["status"] == "complete"
    assert record["gate"] == "report-only" and record["thresholds"] is None
    assert record["source"]["revision"] == "abc123"
    assert [item["path"] for item in record["source"]["files"]] == [
        "native/foresight_native.cpp",
        "services/inference/grounded.h",
    ]
    assert record["source"]["files"][0]["sha256"] == sha256(coverage_tree.native_cpp)
    totals = record["coverage"]["totals"]
    assert totals["lines"] == {"count": 30, "covered": 17, "percent": 56.67}
    assert totals["functions"] == {"count": 6, "covered": 5, "percent": 83.33}
    assert totals["regions"] == {"count": 18, "covered": 9, "percent": 50.0}
    assert totals["branches"] == {"count": 4, "covered": 1, "percent": 25.0}
    llvm_totals = record["coverage"]["llvm_cov_totals"]
    assert {
        name: (llvm_totals[name]["count"], llvm_totals[name]["covered"])
        for name in totals
    } == {name: (value["count"], value["covered"]) for name, value in totals.items()}

    profiles = record["profiles"]
    profile_dir = Path(profiles["directory"])
    assert profile_dir.parent == out and profiles["created_by_this_run"] is True
    assert stat.S_IMODE(profile_dir.stat().st_mode) == 0o700
    assert [Path(item["path"]).parent for item in profiles["files"]] == [profile_dir]
    assert profiles["empty_files"] == []
    assert profiles["stray_search_directories"] == [
        str(coverage_tree.build),
        str(coverage_tree.build / "native"),
    ]
    assert profiles["stray_default_profiles"] == [
        {
            "path": str(coverage_tree.stale),
            "mtime_ns": 1_000_000_000,
            "written_during_run": False,
        }
    ]

    objects = record["objects"]
    assert (
        objects["built_by_this_tool"] is False
        and objects["unchanged_during_run"] is True
    )
    assert objects["instrumented"][0]["sha256"] == sha256(coverage_tree.library)
    assert objects["absent_targets"] == ["foresight-audio"]
    assert record["tools"]["llvm-profdata"]["release"] == "LLVM 18.1.3"
    assert record["tools"]["compiler"]["release"] == "LLVM 18.1.3"
    assert record["tools"]["ctest"]["version_output"] == "ctest version 3.28.3"
    assert record["build"]["metadata"]["sha256"] == sha256(coverage_tree.metadata_path)

    exported = json.loads((out / "coverage.json").read_text())
    assert sorted(item["filename"] for item in exported["data"][0]["files"]) == sorted(
        [str(coverage_tree.native_cpp), str(coverage_tree.grounded)]
    )
    assert (out / "html/index.html").is_file()
    artifacts = {item["path"]: item for item in record["artifacts"]}
    assert artifacts["coverage.json"]["sha256"] == sha256(out / "coverage.json")
    summary = json.loads((out / "summary.json").read_text())
    assert summary["totals"] == totals and summary["gate"] == "report-only"
    assert "Passed" in (out / "ctest.log").read_text()
    assert "Passed" in capsys.readouterr().out


def test_ctest_failure_keeps_output_and_still_reports(
    coverage_tree, monkeypatch, capsys
):
    monkeypatch.setenv("FAKE_CTEST_EXIT", "8")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_TESTS_FAILED
    record = read_record(coverage_tree)
    assert record["status"] == "tests_failed"
    assert record["ctest"]["exit_status"] == 8
    assert record["coverage"]["totals"]["lines"]["covered"] == 17
    assert "FAILED" in (coverage_tree.out / "ctest.log").read_text()
    assert "FAILED" in capsys.readouterr().out


def test_tool_release_mismatch_refuses_before_running_tests(coverage_tree, monkeypatch):
    monkeypatch.setenv("FAKE_PROFDATA_VERSION", "Ubuntu LLVM version 17.0.6")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert record["status"] == "infrastructure_failure"
    assert "LLVM 17.0.6" in record["error"] and "LLVM 18.1.3" in record["error"]
    assert not (coverage_tree.tools / "ctest-ran").exists()


def test_apple_tools_do_not_match_upstream_clang(coverage_tree, monkeypatch):
    monkeypatch.setenv("FAKE_PROFDATA_VERSION", "Apple LLVM version 18.1.3")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    assert "Apple LLVM 18.1.3" in read_record(coverage_tree)["error"]


def test_stale_profile_data_is_an_infrastructure_failure(coverage_tree, monkeypatch):
    monkeypatch.setenv("FAKE_COV_STDERR", "warning: 2 functions have mismatched data\n")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert record["status"] == "infrastructure_failure"
    assert "mismatched data" in (coverage_tree.out / "llvm-tools.log").read_text()
    assert record["coverage"] is None


def test_missing_built_object_refuses(coverage_tree):
    coverage_tree.library.unlink()
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    assert (
        "foresight_native has no built artifact" in read_record(coverage_tree)["error"]
    )


def test_missing_metadata_refuses_without_creating_output(tmp_path, capsys):
    out = tmp_path / "reports"
    code = nqr.main(
        [
            "coverage",
            "--build-dir",
            str(tmp_path),
            "--output-dir",
            str(out),
            "--source-revision",
            "abc123",
        ]
    )
    assert code == nqr.EXIT_INFRASTRUCTURE
    assert "-DFORESIGHT_NATIVE_COVERAGE=ON" in capsys.readouterr().err
    assert not out.exists()


def test_metadata_for_another_build_directory_refuses(coverage_tree, tmp_path, capsys):
    coverage_tree.metadata["binary_dir"] = str(tmp_path / "elsewhere")
    coverage_tree.metadata_path.write_text(json.dumps(coverage_tree.metadata))
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    assert "describes build directory" in capsys.readouterr().err


@pytest.mark.parametrize(
    "change",
    [
        {"schema": "other/1"},
        {"coverage_enabled": False},
        {"instrumented_targets": []},
        {"instrumented_targets": [{"target": "x", "file": "relative/path"}]},
        {"compiler": {"id": "Clang", "version": "18.1.3"}},
        {"report_scope": []},
        {"absent_targets": None},
    ],
)
def test_incomplete_metadata_refuses(coverage_tree, change, capsys):
    coverage_tree.metadata.update(change)
    coverage_tree.metadata_path.write_text(json.dumps(coverage_tree.metadata))
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    assert "coverage-metadata.json: " in capsys.readouterr().err
    assert not coverage_tree.out.exists()


def test_source_revision_is_required_and_consistent():
    with pytest.raises(nqr.ReportError, match="source revision is unknown"):
        nqr.resolve_source_revision("", None)
    with pytest.raises(nqr.ReportError, match="contradicts"):
        nqr.resolve_source_revision("aaa", "bbb")
    assert nqr.resolve_source_revision("aaa", None) == "aaa"
    assert nqr.resolve_source_revision("", "bbb") == "bbb"


def test_non_empty_output_directory_is_never_reused(coverage_tree):
    coverage_tree.out.mkdir()
    previous = coverage_tree.out / "coverage.json"
    previous.write_text("cached")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    assert previous.read_text() == "cached"
    assert not (coverage_tree.tools / "ctest-ran").exists()


def test_profile_inventory_retains_empty_and_rejects_foreign_entries(tmp_path):
    (tmp_path / "1-a.profraw").write_bytes(b"data")
    assert [Path(item["path"]).name for item in nqr.inventory_profiles(tmp_path)] == [
        "1-a.profraw"
    ]
    (tmp_path / "2-b.profraw").write_bytes(b"")
    profiles = nqr.inventory_profiles(tmp_path)
    assert [item["size"] for item in profiles] == [4, 0]
    assert profiles[1]["sha256"] == hashlib.sha256(b"").hexdigest()
    (tmp_path / "2-b.profraw").unlink()
    (tmp_path / "notes.txt").write_text("x")
    with pytest.raises(nqr.ReportError, match="unexpected entry notes.txt"):
        nqr.inventory_profiles(tmp_path)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Ubuntu clang version 18.1.3 (1ubuntu1)", (False, (18, 1, 3))),
        ("Apple clang version 16.0.0 (clang-1600.0.26.6)", (True, (16, 0, 0))),
        ("LLVM (http://llvm.org/):\n  LLVM version 18.1.8\n", (False, (18, 1, 8))),
        ("Apple LLVM version 16.0.0\n  Optimized build.", (True, (16, 0, 0))),
        ("Homebrew LLVM version 19.1.7", (False, (19, 1, 7))),
    ],
)
def test_llvm_release_parsing(text, expected):
    assert tuple(nqr.parse_llvm_release(text)) == expected


def test_compiler_release_uses_cmake_identity():
    assert nqr.compiler_release({"id": "AppleClang", "version": "16.0.0.16000026"}) == (
        nqr.LlvmRelease(True, (16, 0, 0))
    )
    with pytest.raises(nqr.ReportError):
        nqr.compiler_release({"id": "GNU", "version": "14.2.0"})
    with pytest.raises(nqr.ReportError):
        nqr.parse_llvm_release("gcc (GCC) 14.2.0")


def test_repository_path_scope(tmp_path):
    source = tmp_path / "repo"
    build = source / "build"
    build.mkdir(parents=True)
    scope = ["native", "services/helper"]

    def classify(relative: str, **options) -> str | None:
        return nqr.repository_path(
            str(source / relative),
            source.resolve(),
            build.resolve(),
            scope,
            ["third_party"],
            **options,
        )

    assert classify("native/foresight_native.cpp") == "native/foresight_native.cpp"
    assert classify("services/helper/main.cpp") == "services/helper/main.cpp"
    assert classify("services/helperish/main.cpp") is None
    assert classify("third_party/litert_lm/x.h") is None
    assert classify("build/services/helper/generated/a.pb.cc") is None
    assert classify("tests/native/audio_pcm.cpp") is None
    assert classify("native/notifications.swift") is None
    assert classify("native/README.md", suffixes=nqr.TIDY_SUFFIXES) is None
    assert (
        nqr.repository_path(
            str(tmp_path / "elsewhere/native/a.cpp"),
            source.resolve(),
            build.resolve(),
            scope,
            [],
        )
        is None
    )


def test_metric_totals_and_invalid_summaries():
    files = [
        nqr.metric_summary({"lines": {"count": 4, "covered": 1}}),
        nqr.metric_summary(
            {
                "lines": {"count": 0, "covered": 0},
                "branches": {"count": 0, "covered": 0},
            }
        ),
    ]
    assert nqr.total_metrics(files) == {
        "lines": {"count": 4, "covered": 1, "percent": 25.0},
        "branches": {"count": 0, "covered": 0, "percent": None},
    }
    with pytest.raises(nqr.ReportError, match="invalid lines"):
        nqr.metric_summary({"lines": {"count": 1, "covered": 2}})
    with pytest.raises(nqr.ReportError):
        nqr.export_files({"type": "something-else", "data": []})


def rewrite_mappings(tree: SimpleNamespace, change) -> None:
    path = tree.tools / "files.json"
    files = json.loads(path.read_text())
    change(files)
    path.write_text(json.dumps(files))


def test_one_file_under_two_names_is_refused(coverage_tree):
    alias = str(coverage_tree.source / "native/../native/foresight_native.cpp")

    def add_alias(files):
        files.append({**files[0], "filename": alias, "lines": [10, 3]})

    rewrite_mappings(coverage_tree, add_alias)
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert "more than one path" in record["error"]
    assert alias in record["error"] and str(coverage_tree.native_cpp) in record["error"]
    assert record["coverage"] is None
    assert not (coverage_tree.out / "coverage.json").exists()


def test_header_recorded_through_dotdot_is_not_reported_as_uncovered(coverage_tree):
    # The only recorded name contains "..": llvm-cov's normalized filter misses it
    # and returns a zero-count entry under another name with exit status 0.
    dotted = str(coverage_tree.source / "native/../services/inference/grounded.h")

    def rename(files):
        files[4]["filename"] = dotted

    rewrite_mappings(coverage_tree, rename)
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert "services/inference/grounded.h" in record["error"]
    assert "did not select the recorded coverage" in record["error"]
    assert record["coverage"] is None
    assert not (coverage_tree.out / "summary.json").exists()


@pytest.mark.parametrize(
    ("variable", "value", "message"),
    [
        ("FAKE_COV_DROP", "grounded.h", "omitted discovered sources"),
        ("FAKE_COV_SKEW", "1", "differs from discovery"),
    ],
)
def test_filtered_export_must_match_discovery(
    coverage_tree, monkeypatch, variable, value, message
):
    monkeypatch.setenv(variable, value)
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert message in record["error"]
    assert record["coverage"] is None


# clang-tidy


FAKE_TIDY = """
args = sys.argv[1:]
if args == ["--version"]:
    print("LLVM (http://llvm.org/):\\n  LLVM version 18.1.8\\n  Optimized build.")
    sys.exit(0)
with open(os.path.join(HERE, "tidy-calls.log"), "a") as log:
    log.write(json.dumps(args) + "\\n")
if "--dump-config" in args:
    print("Checks: 'bugprone-*'")
    sys.exit(0)
if "--list-checks" in args:
    if os.environ.get("FAKE_TIDY_LIST_CRASH"):
        import signal
        os.kill(os.getpid(), signal.SIGSEGV)
    enabled = os.environ.get("FAKE_TIDY_CHECKS", "bugprone-x")
    if not enabled and not any(a.startswith("--checks=") for a in args):
        # clang-tidy 23: database errors may precede the message, on stderr.
        sys.stderr.write("Error while trying to load a compilation database:\\n")
        sys.stderr.write("No checks enabled.\\n")
        sys.exit(1)
    print("Enabled checks:\\n    " + "\\n    ".join((enabled or "bugprone-y").split(",")) + "\\n")
    sys.exit(0)
behaviour = json.load(open(os.path.join(HERE, "tidy-behaviour.json")))
stdout, stderr, code = behaviour.get(os.path.basename(args[-1]), ["", "", 0])
if os.environ.get("FAKE_TIDY_SLEEP_FILE") == os.path.basename(args[-1]):
    sys.stdout.write("partial tidy stdout\\n")
    sys.stdout.flush()
    import time
    time.sleep(60)
sys.stdout.write(stdout)
sys.stderr.write(stderr)
sys.exit(code)
"""


@pytest.fixture
def tidy_tree(tmp_path: Path) -> SimpleNamespace:
    source = tmp_path / "src"
    build = tmp_path / "build"
    tools = tmp_path / "tools"
    for directory in (
        source / "native",
        source / "services/helper",
        source / "third_party",
        source / "tests/native",
        build,
        tools,
    ):
        directory.mkdir(parents=True)
    paths = {}
    for relative in (
        "native/a.cpp",
        "native/b.cpp",
        "services/helper/main.cpp",
        "third_party/v.cc",
        "tests/native/t.cpp",
    ):
        paths[relative] = source / relative
        paths[relative].write_text(f"// {relative}\n")
    database = [
        {
            "directory": str(build),
            "file": str(paths["native/a.cpp"]),
            "command": "c++ -c a.cpp",
        },
        {
            "directory": str(source),
            "file": "native/b.cpp",
            "arguments": ["c++", "-c", "b.cpp"],
        },
        {
            "directory": str(build),
            "file": str(paths["services/helper/main.cpp"]),
            "command": "c++",
        },
        {
            "directory": str(build),
            "file": str(paths["services/helper/main.cpp"]),
            "command": "c++",
        },
        {
            "directory": str(build),
            "file": str(paths["third_party/v.cc"]),
            "command": "c++",
        },
        {
            "directory": str(build),
            "file": str(paths["tests/native/t.cpp"]),
            "command": "c++",
        },
        {
            "directory": str(build),
            "file": str(build / "generated/x.pb.cc"),
            "command": "c++",
        },
    ]
    (build / "compile_commands.json").write_text(json.dumps(database))
    return SimpleNamespace(
        source=source,
        build=build,
        tools=tools,
        paths=paths,
        database=database,
        clang_tidy=fake_tool(tools / "clang-tidy", FAKE_TIDY),
    )


def set_behaviour(tree: SimpleNamespace, behaviour: dict) -> None:
    (tree.tools / "tidy-behaviour.json").write_text(json.dumps(behaviour))


def tidy_args(tree: SimpleNamespace, out: Path, *extra: str) -> list[str]:
    return [
        "clang-tidy",
        "--source-dir",
        str(tree.source),
        "--build-dir",
        str(tree.build),
        "--output-dir",
        str(out),
        "--source-revision",
        "abc123",
        "--clang-tidy",
        tree.clang_tidy,
        "--jobs",
        "1",
        *extra,
    ]


def test_select_tidy_files_uses_explicit_repository_scope(tidy_tree):
    source, build = tidy_tree.source.resolve(), tidy_tree.build.resolve()
    files, entries = nqr.select_tidy_files(
        tidy_tree.database, source, build, nqr.DEFAULT_TIDY_SCOPE, ()
    )
    assert files == ["native/a.cpp", "native/b.cpp", "services/helper/main.cpp"]
    assert entries["services/helper/main.cpp"] == 2
    files, _ = nqr.select_tidy_files(
        tidy_tree.database, source, build, ["native"], ["./native/b.cpp"]
    )
    assert files == ["native/b.cpp"]
    with pytest.raises(nqr.ReportError, match="third_party/v.cc"):
        nqr.select_tidy_files(
            tidy_tree.database, source, build, ["native"], ["third_party/v.cc"]
        )
    with pytest.raises(nqr.ReportError, match="repository-relative"):
        nqr.select_tidy_files(
            tidy_tree.database, source, build, ["native"], ["../x.cpp"]
        )
    with pytest.raises(nqr.ReportError, match="lacks file"):
        nqr.select_tidy_files([{"file": "a.cpp"}], source, build, ["native"], ())


def test_diagnostic_parsing_keeps_brackets_in_messages():
    text = (
        "/r/a.cpp:9:1: warning: function 'f' should be marked [[nodiscard]] [modernize-use-nodiscard]\n"
        "/r/a.cpp:9:1: note: insert here\n"
        "/r/a.cpp:2:3: warning: x [bugprone-y,-warnings-as-errors]\n"
        "/r/a.cpp:4:1: error: use [[nodiscard]]\n"
    )
    assert [
        (item["message"], item["check"]) for item in nqr.parse_diagnostics(text)
    ] == [
        ("function 'f' should be marked [[nodiscard]]", "modernize-use-nodiscard"),
        ("x", "bugprone-y"),
        ("use [[nodiscard]]", None),
    ]


@pytest.mark.parametrize(
    ("returncode", "stdout", "stderr", "status"),
    [
        (
            0,
            "/s/native/a.cpp:1:1: warning: w [bugprone-x]\n",
            "1 warning generated.\n",
            "analyzed",
        ),
        (
            1,
            "/s/native/a.cpp:1:10: error: 'x.h' file not found [clang-diagnostic-error]\n",
            "Error while processing /s/native/a.cpp.\n",
            "analysis_error",
        ),
        (1, "", "Error while processing /s/native/a.cpp.\n", "analysis_error"),
        (-11, "", "", "tool_failure"),
        (1, "", "", "tool_failure"),
    ],
)
def test_tidy_failures_are_distinct_from_findings(returncode, stdout, stderr, status):
    result = nqr.classify_tidy_result(
        "native/a.cpp", returncode, stdout, stderr, Path("/s")
    )
    assert result["status"] == status
    if status == "analyzed":
        assert [item["check"] for item in result["findings"]] == ["bugprone-x"]
        assert result["findings"][0]["path"] == "native/a.cpp"
    else:
        assert result["reason"]


def test_tidy_run_reports_findings_and_analysis_errors_separately(
    tidy_tree, tmp_path, capsys
):
    a, b = tidy_tree.paths["native/a.cpp"], tidy_tree.paths["native/b.cpp"]
    cast = f"{a}:3:5: warning: use of old-style cast [cppcoreguidelines-pro-type-cstyle-cast]\n"
    set_behaviour(
        tidy_tree,
        {
            "a.cpp": [
                cast
                + cast
                + f"{a}:9:1: warning: mark [[nodiscard]] [modernize-use-nodiscard]\n"
                f"{a}:9:1: note: here\n",
                "3 warnings generated.\n",
                0,
            ],
            "b.cpp": [
                f"{b}:1:10: error: 'missing.h' file not found [clang-diagnostic-error]\n",
                f"Error while processing {b}.\n",
                1,
            ],
        },
    )
    out = tmp_path / "tidy"
    assert nqr.main(tidy_args(tidy_tree, out)) == nqr.EXIT_INFRASTRUCTURE
    record = json.loads((out / "clang-tidy-record.json").read_text())
    assert record["status"] == "tool_failure" and record["gate"] == "report-only"
    statuses = {item["file"]: item["status"] for item in record["files"]}
    assert statuses == {
        "native/a.cpp": "analyzed",
        "native/b.cpp": "analysis_error",
        "services/helper/main.cpp": "analyzed",
    }
    assert record["summary"]["findings"] == 2
    assert record["summary"]["by_check"] == {
        "cppcoreguidelines-pro-type-cstyle-cast": 1,
        "modernize-use-nodiscard": 1,
    }
    assert all(
        item["translation_unit"] == "native/a.cpp" for item in record["findings"]
    )
    assert record["files"][1]["compiler_errors"][0]["check"] == "clang-diagnostic-error"
    assert record["source"]["files"][0]["sha256"] == sha256(a)
    assert record["tool"]["release"] == "LLVM 18.1.8"
    assert record["configs"][0]["directory"] == "native"
    assert "analysis_error: native/b.cpp" in capsys.readouterr().err
    calls = [
        json.loads(line)
        for line in (tidy_tree.tools / "tidy-calls.log").read_text().splitlines()
    ]
    analysis_calls = [
        call
        for call in calls
        if "--dump-config" not in call and "--list-checks" not in call
    ]
    assert len(analysis_calls) == 3
    assert all("--warnings-as-errors=-*" in call for call in analysis_calls)
    assert record["configs"][0]["checks"] == ["bugprone-x"]
    assert record["checks_argument"] is None


def test_tidy_refuses_configuration_without_checks(
    tidy_tree, tmp_path, monkeypatch, capsys
):
    # clang-tidy releases whose default enables only compiler diagnostics refuse
    # every file; that is a configuration failure, never zero findings.
    monkeypatch.setenv("FAKE_TIDY_CHECKS", "")
    set_behaviour(tidy_tree, {})
    out = tmp_path / "tidy"
    assert nqr.main(tidy_args(tidy_tree, out)) == nqr.EXIT_INFRASTRUCTURE
    record = json.loads((out / "clang-tidy-record.json").read_text())
    assert record["status"] == "infrastructure_failure"
    assert "enables no checks" in record["error"]
    assert record["summary"] is None and record["files"] == []
    assert "pass --checks or --config-file" in capsys.readouterr().err
    calls = (tidy_tree.tools / "tidy-calls.log").read_text().splitlines()
    assert not [
        call for call in calls if "--dump-config" not in call and "--list-checks" not in call
    ]


def test_tidy_checks_argument_reaches_every_invocation(
    tidy_tree, tmp_path, monkeypatch
):
    monkeypatch.setenv("FAKE_TIDY_CHECKS", "")
    set_behaviour(tidy_tree, {})
    out = tmp_path / "tidy"
    assert (
        nqr.main(tidy_args(tidy_tree, out, "--checks", "clang-analyzer-*"))
        == nqr.EXIT_OK
    )
    record = json.loads((out / "clang-tidy-record.json").read_text())
    assert record["checks_argument"] == "clang-analyzer-*"
    assert record["configs"][0]["checks"] == ["bugprone-y"]
    calls = [
        json.loads(line)
        for line in (tidy_tree.tools / "tidy-calls.log").read_text().splitlines()
    ]
    assert calls and all("--checks=clang-analyzer-*" in call for call in calls)
    assert nqr.main(tidy_args(tidy_tree, tmp_path / "empty", "--checks", " ")) == 2


def test_tidy_baseline_difference(tidy_tree, tmp_path):
    a, b = tidy_tree.paths["native/a.cpp"], tidy_tree.paths["native/b.cpp"]
    cast = "warning: use of old-style cast [cppcoreguidelines-pro-type-cstyle-cast]\n"
    set_behaviour(
        tidy_tree,
        {
            "a.cpp": [f"{a}:3:5: {cast}", "", 0],
            "b.cpp": [f"{b}:7:1: warning: unused [misc-unused]\n", "", 0],
        },
    )
    first = tmp_path / "first"
    assert nqr.main(tidy_args(tidy_tree, first)) == nqr.EXIT_OK
    set_behaviour(
        tidy_tree,
        {
            "a.cpp": [
                f"{a}:4:5: {cast}{a}:8:5: {cast}{a}:9:1: warning: mark [modernize-use-nodiscard]\n",
                "",
                0,
            ],
        },
    )
    second = tmp_path / "second"
    baseline_path = first / "clang-tidy-record.json"
    assert (
        nqr.main(tidy_args(tidy_tree, second, "--baseline", str(baseline_path)))
        == nqr.EXIT_OK
    )
    baseline = json.loads((second / "clang-tidy-record.json").read_text())["baseline"]
    assert baseline["comparable"] is True and baseline["differences"] == []
    assert baseline["sha256"] == sha256(baseline_path)
    assert [
        (item["check"], item["current"], item["baseline"]) for item in baseline["new"]
    ] == [
        ("cppcoreguidelines-pro-type-cstyle-cast", 2, 1),
        ("modernize-use-nodiscard", 1, 0),
    ]
    assert [(item["path"], item["check"]) for item in baseline["resolved"]] == [
        ("native/b.cpp", "misc-unused")
    ]
    assert baseline["unchanged"] == 1
    assert (
        "new=2 resolved=1 unchanged=1"
        in (second / "clang-tidy-summary.txt").read_text()
    )


def test_tidy_baseline_skips_files_that_failed_to_analyze(tidy_tree, tmp_path):
    b = tidy_tree.paths["native/b.cpp"]
    set_behaviour(
        tidy_tree, {"b.cpp": [f"{b}:7:1: warning: unused [misc-unused]\n", "", 0]}
    )
    first = tmp_path / "first"
    assert nqr.main(tidy_args(tidy_tree, first)) == nqr.EXIT_OK
    set_behaviour(tidy_tree, {"b.cpp": ["", "", -9]})
    second = tmp_path / "second"
    code = nqr.main(
        tidy_args(
            tidy_tree, second, "--baseline", str(first / "clang-tidy-record.json")
        )
    )
    assert code == nqr.EXIT_INFRASTRUCTURE
    baseline = json.loads((second / "clang-tidy-record.json").read_text())["baseline"]
    assert baseline["resolved"] == [] and baseline["not_compared_files"] == [
        "native/b.cpp"
    ]


def test_tidy_refuses_missing_inputs(tidy_tree, tmp_path, capsys):
    (tidy_tree.build / "compile_commands.json").unlink()
    out = tmp_path / "tidy"
    assert nqr.main(tidy_args(tidy_tree, out)) == nqr.EXIT_INFRASTRUCTURE
    assert "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" in capsys.readouterr().err
    assert not out.exists()


def test_tidy_refuses_malformed_baseline(tidy_tree, tmp_path, capsys):
    set_behaviour(tidy_tree, {})
    bad = tmp_path / "bad.json"
    bad.write_text(
        json.dumps(
            {"schema": nqr.TIDY_RECORD_SCHEMA, "files": [], "findings": [{"path": "x"}]}
        )
    )
    assert (
        nqr.main(tidy_args(tidy_tree, tmp_path / "tidy", "--baseline", str(bad))) == 2
    )
    assert "malformed finding" in capsys.readouterr().err


def test_tidy_requires_source_revision(tidy_tree, tmp_path, capsys):
    args = tidy_args(tidy_tree, tmp_path / "tidy")
    index = args.index("--source-revision")
    del args[index : index + 2]
    assert nqr.main(args) == nqr.EXIT_INFRASTRUCTURE
    assert "source revision is unknown" in capsys.readouterr().err


def header_behaviour(tree: SimpleNamespace, tmp_path: Path) -> dict:
    """a.cpp and b.cpp both include native/common.h and out-of-scope headers."""
    header = tree.source / "native/common.h"
    generated = tree.build / "generated/x.pb.h"
    system = tmp_path / "sysroot/include/stdio.h"

    def warn(path, line, column, check, message="m"):
        return f"{path}:{line}:{column}: warning: {message} [{check}]\n"

    return {
        "a.cpp": [
            warn(header, 5, 3, "bugprone-x")
            + warn(header, 6, 3, "bugprone-x")
            + warn(tree.source / "third_party/v.h", 1, 1, "bugprone-x")
            + warn(generated, 2, 1, "bugprone-x")
            + warn(tree.source / "tests/native/t.h", 3, 1, "bugprone-x")
            + warn(system, 4, 1, "bugprone-x"),
            "",
            0,
        ],
        "b.cpp": [
            warn(header, 5, 3, "bugprone-x")
            + warn(header, 5, 3, "bugprone-other")
            + warn(generated, 2, 1, "bugprone-x"),
            "",
            0,
        ],
    }


def test_tidy_counts_each_owned_location_once_and_labels_excluded(
    tidy_tree, tmp_path
):
    set_behaviour(tidy_tree, header_behaviour(tidy_tree, tmp_path))
    out = tmp_path / "tidy"
    assert nqr.main(tidy_args(tidy_tree, out)) == nqr.EXIT_OK
    record = json.loads((out / "clang-tidy-record.json").read_text())
    summary = record["summary"]
    # The shared header finding counts once; a different line or check does not merge.
    assert summary["findings"] == 3
    assert summary["by_check"] == {"bugprone-other": 1, "bugprone-x": 2}
    assert [
        (item["path"], item["line"], item["check"], item["translation_units"])
        for item in record["findings"]
    ] == [
        ("native/common.h", 5, "bugprone-other", ["native/b.cpp"]),
        ("native/common.h", 5, "bugprone-x", ["native/a.cpp", "native/b.cpp"]),
        ("native/common.h", 6, "bugprone-x", ["native/a.cpp"]),
    ]
    assert record["findings"][1]["translation_unit"] == "native/a.cpp"
    # Out-of-scope findings stay in the record, labelled, outside the main total.
    assert summary["excluded_findings"] == 4
    excluded_paths = sorted(item["path"] for item in record["excluded_findings"])
    assert excluded_paths == sorted(
        [
            "third_party/v.h",
            "tests/native/t.h",
            os.path.realpath(tidy_tree.build / "generated/x.pb.h"),
            os.path.realpath(tmp_path / "sysroot/include/stdio.h"),
        ]
    )
    assert summary["raw_findings"] == len(record["raw_findings"]) == 9
    assert sum(item["scope"] == "excluded" for item in record["raw_findings"]) == 5
    assert {item["file"]: item["finding_count"] for item in record["files"]} == {
        "native/a.cpp": 6,
        "native/b.cpp": 3,
        "services/helper/main.cpp": 0,
    }
    text = (out / "clang-tidy-summary.txt").read_text()
    assert "excluded findings (outside scope): 4" in text


def test_tidy_baseline_normalizes_older_per_unit_records(tidy_tree, tmp_path):
    set_behaviour(tidy_tree, header_behaviour(tidy_tree, tmp_path))
    first = tmp_path / "first"
    assert nqr.main(tidy_args(tidy_tree, first)) == nqr.EXIT_OK
    old = json.loads((first / "clang-tidy-record.json").read_text())
    # The earlier record format: one finding per unit, scope unfiltered.
    old["findings"] = [
        {key: value for key, value in item.items() if key != "scope"}
        for item in old.pop("raw_findings")
    ]
    del old["excluded_findings"]
    old_path = tmp_path / "old.json"
    old_path.write_text(json.dumps(old))
    second = tmp_path / "second"
    assert (
        nqr.main(tidy_args(tidy_tree, second, "--baseline", str(old_path)))
        == nqr.EXIT_OK
    )
    baseline = json.loads((second / "clang-tidy-record.json").read_text())["baseline"]
    assert baseline["comparable"] is True
    assert baseline["new"] == [] and baseline["resolved"] == []
    assert baseline["unchanged"] == 3
    assert baseline["baseline_findings"] == {
        "recorded": 9,
        "out_of_scope": 5,
        "duplicates_merged": 1,
        "normalized": 3,
    }


def test_tidy_baseline_skips_header_keys_from_failed_units(tidy_tree, tmp_path):
    set_behaviour(tidy_tree, header_behaviour(tidy_tree, tmp_path))
    first = tmp_path / "first"
    assert nqr.main(tidy_args(tidy_tree, first)) == nqr.EXIT_OK
    behaviour = header_behaviour(tidy_tree, tmp_path)
    behaviour["b.cpp"] = ["", "", -9]
    set_behaviour(tidy_tree, behaviour)
    second = tmp_path / "second"
    code = nqr.main(
        tidy_args(
            tidy_tree, second, "--baseline", str(first / "clang-tidy-record.json")
        )
    )
    assert code == nqr.EXIT_INFRASTRUCTURE
    record = json.loads((second / "clang-tidy-record.json").read_text())
    assert record["summary"]["findings"] == 2
    baseline = record["baseline"]
    # native/b.cpp failed, so header keys it reported are neither new nor resolved.
    assert baseline["not_compared_files"] == ["native/b.cpp"]
    assert baseline["not_compared_keys"] == 2
    assert baseline["new"] == [] and baseline["resolved"] == []


def test_empty_profile_files_are_recorded_but_never_merged(
    coverage_tree, monkeypatch, capsys
):
    monkeypatch.setenv("FAKE_EXTRA_EMPTY", "1")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_OK
    record = read_record(coverage_tree)
    assert len(record["profiles"]["files"]) == 2
    assert len(record["profiles"]["empty_files"]) == 1
    assert record["profiles"]["empty_files"][0]["size"] == 0
    assert "unflushed" not in record["profiles"]
    assert "1 empty raw profile files" in capsys.readouterr().err
    merged = (coverage_tree.out / "raw-profiles.txt").read_text().splitlines()
    assert len(merged) == 1
    assert Path(merged[0]).stat().st_size > 0
    assert (
        json.loads((coverage_tree.out / "summary.json").read_text())[
            "empty_profile_count"
        ]
        == 1
    )


def test_only_empty_profiles_cannot_produce_a_coverage_report(
    coverage_tree, monkeypatch
):
    monkeypatch.setenv("FAKE_EMPTY_ONLY", "1")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert len(record["profiles"]["empty_files"]) == 1
    assert not (coverage_tree.out / "coverage.profdata").exists()


# D3: recomputed totals must equal llvm-cov's own totals.


def test_totals_that_differ_from_llvm_export_refuse(coverage_tree, monkeypatch):
    monkeypatch.setenv("FAKE_COV_TOTALS_SKEW", "1")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert record["status"] == "infrastructure_failure"
    assert "differ from llvm-cov export totals for regions" in record["error"]
    assert "lines" not in record["error"].split("for ", 1)[1]
    assert record["coverage"] is None
    assert not (coverage_tree.out / "summary.json").exists()


def test_export_without_a_reported_metric_refuses(coverage_tree, monkeypatch):
    monkeypatch.setenv("FAKE_COV_NO_TOTALS", "1")
    assert nqr.main(coverage_args(coverage_tree)) == nqr.EXIT_INFRASTRUCTURE
    assert "lines (" in read_record(coverage_tree)["error"]


def test_export_must_hold_one_unit_with_totals():
    totals = {"lines": {"count": 1, "covered": 1, "percent": 100.0}}
    with pytest.raises(nqr.ReportError, match="exactly one data unit"):
        nqr.verify_llvm_totals({"data": [{"files": []}]}, totals)
    with pytest.raises(nqr.ReportError, match="exactly one data unit"):
        unit = {"files": [], "totals": {"lines": {"count": 1, "covered": 1}}}
        nqr.verify_llvm_totals({"data": [unit, unit]}, totals)


# D5: every finite deadline fails closed and keeps the partial output.


def test_run_tool_timeout_keeps_partial_output():
    script = "import sys,time;print('so far');sys.stdout.flush();time.sleep(60)"
    with pytest.raises(nqr.ToolTimeout, match="timed out after 0.5 seconds") as caught:
        nqr.run_tool([sys.executable, "-c", script], 0.5)
    assert caught.value.stdout == "so far\n"


def test_ctest_timeout_keeps_partial_log(coverage_tree, monkeypatch, capsys):
    monkeypatch.setenv("FAKE_CTEST_SLEEP", "1")
    code = nqr.main(coverage_args(coverage_tree, "--ctest-timeout", "2"))
    assert code == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert record["status"] == "infrastructure_failure"
    assert "root CTest exceeded 2.0 seconds" in record["error"]
    assert "Passed" in (coverage_tree.out / "ctest.log").read_text()
    assert "Passed" in capsys.readouterr().out
    assert record["coverage"] is None


def test_llvm_timeout_is_logged_with_partial_stderr(coverage_tree, monkeypatch):
    monkeypatch.setenv("FAKE_COV_SLEEP", "report")
    code = nqr.main(coverage_args(coverage_tree, "--llvm-timeout", "2"))
    assert code == nqr.EXIT_INFRASTRUCTURE
    record = read_record(coverage_tree)
    assert "llvm-cov report timed out after 2.0 seconds" in record["error"]
    assert record["commands"][-1]["exit_status"] == "timeout"
    log = (coverage_tree.out / "llvm-tools.log").read_text()
    assert "timed out after 2.0 seconds" in log
    assert "partial llvm-cov stderr" in log
    assert record["coverage"] is None


def test_tidy_file_timeout_is_a_tool_failure_with_partial_output(
    tidy_tree, tmp_path, monkeypatch
):
    monkeypatch.setenv("FAKE_TIDY_SLEEP_FILE", "b.cpp")
    set_behaviour(tidy_tree, {})
    out = tmp_path / "tidy"
    code = nqr.main(tidy_args(tidy_tree, out, "--timeout", "2"))
    assert code == nqr.EXIT_INFRASTRUCTURE
    record = json.loads((out / "clang-tidy-record.json").read_text())
    assert record["status"] == "tool_failure"
    statuses = {item["file"]: (item["status"], item["reason"]) for item in record["files"]}
    assert statuses["native/b.cpp"] == ("tool_failure", "timed out after 2.0 seconds")
    assert statuses["native/a.cpp"] == ("analyzed", None)
    assert record["summary"]["tool_failures"] == 1
    assert "partial tidy stdout" in (out / "clang-tidy.log").read_text()


# D6: a crashing --list-checks is a tool failure, not an empty configuration.


def test_tidy_list_checks_crash_is_a_tool_failure(tidy_tree, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_TIDY_LIST_CRASH", "1")
    set_behaviour(tidy_tree, {})
    out = tmp_path / "tidy"
    assert nqr.main(tidy_args(tidy_tree, out)) == nqr.EXIT_INFRASTRUCTURE
    record = json.loads((out / "clang-tidy-record.json").read_text())
    assert record["status"] == "infrastructure_failure"
    assert "--list-checks failed" in record["error"]
    assert f"signal {signal.SIGSEGV.value}" in record["error"]
    assert "enables no checks" not in record["error"]
