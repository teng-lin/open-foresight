"""Guard LeakSanitizer gate settings, suppression policy and probe verdicts."""

import importlib
from pathlib import Path
import subprocess
import sys

import pytest
import yaml

from tools.sanitizer_settings import (
    CPYTHON_RETAINED_FRAMES,
    SUPPRESSIONS,
    main as settings_main,
    sanitizer_options,
    suppression_policy_errors,
)

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def verifier(monkeypatch):
    # The verifier runs as a script with tools/ on sys.path.
    monkeypatch.syspath_prepend(str(ROOT / "tools"))
    return importlib.import_module("verify_native_sanitizers")


def options(value):
    return dict(field.split("=", 1) for field in value.split(":"))


def test_shipped_suppressions_are_the_policy_checked_file():
    assert SUPPRESSIONS == ROOT / "tools" / "lsan-cpython.supp"
    assert suppression_policy_errors(SUPPRESSIONS.read_text()) == []


def test_policy_accepts_a_justified_exact_cpython_startup_frame():
    text = "# reason: captured startup stack\n# continued\nleak:^Py_InitializeFromConfig$\n"
    assert suppression_policy_errors(text) == []


@pytest.mark.parametrize("frame", sorted(CPYTHON_RETAINED_FRAMES))
def test_policy_requires_exact_justified_retained_allocation_frames(frame):
    rule = f"leak:^{frame}$\n"
    assert (
        suppression_policy_errors("# reason: observed clean-host stack\n" + rule) == []
    )
    assert suppression_policy_errors(rule)


@pytest.mark.parametrize(
    "rule",
    [
        "leak:Py_InitializeFromConfig",  # unanchored substring match
        "leak:^Py_Initialize*$",
        "leak:*",
        "leak:^_PyEval_EvalFrameDefault$",  # above every ctypes call
        "leak:^PyObject_Call$",
        "leak:^PyObject_Vectorcall$",
        "leak:^Py_RunMain$",
        "leak:^Py_BytesMain$",
        "leak:^Py_FinalizeEx$",  # atexit/__del__ can call native code
        "leak:^PyImport_ImportModule$",
        "leak:^PyObject_Malloc$",
        "leak:^PyMem_RawMalloc$",
        "leak:libpython3.13.so",
        "leak:/usr/lib/libpython3.13.so.1.0",
        "leak:_ctypes",
        "leak:libffi",
        "leak:^ffi_call$",
        "leak:libforesight_native.so",
        "leak:^foresight_lsan_host_leak$",
        "leak:^malloc$",
        "called_from_lib:libpython3.13.so",
        "interceptor_via_lib:libpython3.13.so",
    ],
)
def test_policy_rejects_rules_that_could_hide_application_leaks(rule):
    assert suppression_policy_errors(f"# reason: plausible-sounding\n{rule}\n")


def test_each_rule_needs_its_own_adjacent_reason():
    shared = (
        "# reason: one\nleak:^_PyRuntime_Initialize$\nleak:^Py_InitializeFromConfig$\n"
    )
    assert suppression_policy_errors(shared) == [
        "line 3: rule lacks its own preceding '# reason:' comment"
    ]
    detached = "# reason: one\n\nleak:^_PyRuntime_Initialize$\n"
    assert suppression_policy_errors(detached)


def test_gate_settings_enable_leaks_and_keep_fatal_reports(tmp_path):
    settings = sanitizer_options(tmp_path)
    asan = options(settings["ASAN_OPTIONS"])
    assert asan == {
        "detect_leaks": "1",
        "halt_on_error": "1",
        "abort_on_error": "1",
        "malloc_context_size": "128",
        "log_path": str(tmp_path / "asan"),
    }
    assert options(settings["UBSAN_OPTIONS"]) == {
        "halt_on_error": "1",
        "print_stacktrace": "1",
        "log_path": str(tmp_path / "ubsan"),
    }
    assert options(settings["LSAN_OPTIONS"]) == {
        "suppressions": str(SUPPRESSIONS),
        "print_suppressions": "0",
    }
    assert settings["PYTHONMALLOC"] == "malloc"
    assert not any("detect_leaks=0" in value for value in settings.values())


def test_probe_settings_write_reports_to_stderr():
    settings = sanitizer_options()
    assert "log_path" not in settings["ASAN_OPTIONS"]
    assert "log_path" not in settings["UBSAN_OPTIONS"]


def test_policy_violation_refuses_to_produce_settings(tmp_path):
    broad = tmp_path / "broad.supp"
    broad.write_text("# reason: hide everything\nleak:libpython3.13.so\n")
    with pytest.raises(ValueError, match="anchored"):
        sanitizer_options(suppressions=broad)


def test_option_separator_in_paths_is_rejected(tmp_path):
    with pytest.raises(ValueError, match="':'"):
        sanitizer_options(tmp_path / "a:b")


def test_settings_cli_emits_shell_readable_assignments(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(
        sys, "argv", ["sanitizer_settings.py", "--log-directory", str(tmp_path)]
    )
    settings_main()
    lines = capsys.readouterr().out.splitlines()
    # run_native_sanitizers.sh splits each line at the first '='.
    assert dict(line.partition("=")[::2] for line in lines) == sanitizer_options(
        tmp_path
    )


def test_gate_script_enables_leaks_through_shared_settings():
    script = (ROOT / "tools/run_native_sanitizers.sh").read_text()
    assert "detect_leaks=0" not in script
    assert 'sanitizer_settings.py" --log-directory "$task_output"' in script
    assert "IFS='=' read -r task_name task_value" in script
    assert 'export LD_PRELOAD="$task_runtime' in script
    assert '"$task_output/asan.*"' in script and '"$task_output/ubsan.*"' in script


def test_check_result_requires_the_exact_deliberate_leak(verifier):
    report = (
        verifier.LEAK_REPORT
        + f"\nDirect leak of {verifier.LEAK_BYTES} byte(s) in 1 object(s)"
    )
    diagnostics = verifier.CASES["leak"][1]
    verifier.check_result("leak", 1, report, diagnostics)
    with pytest.raises(RuntimeError):
        verifier.check_result("leak", 0, report, diagnostics)
    with pytest.raises(RuntimeError):
        # Some other (for example CPython) leak is not the planted one.
        verifier.check_result(
            "leak", 1, verifier.LEAK_REPORT + "\nDirect leak of 7 byte(s)", diagnostics
        )


def test_check_result_rejects_reports_from_clean_controls(verifier):
    verifier.check_result("retained", 0, "", None)
    for stderr in (
        verifier.LEAK_REPORT,
        "ERROR: AddressSanitizer: x",
        "runtime error: y",
    ):
        with pytest.raises(RuntimeError):
            verifier.check_result("retained", 0, stderr, None)
    with pytest.raises(RuntimeError):
        verifier.check_result("retained", 1, "", None)


def test_probe_cases_keep_existing_and_add_leak_controls(verifier):
    assert verifier.CASES["address"][1] == ("AddressSanitizer",)
    assert verifier.CASES["undefined"][1] == ("runtime error: signed integer overflow",)
    assert f"Direct leak of {verifier.LEAK_BYTES} byte(s)" in verifier.CASES["leak"][1]
    assert verifier.CASES["retained"][1] is None
    assert verifier.LEAK_BYTES != verifier.HOST_LEAK_BYTES
    assert str(verifier.HOST_LEAK_BYTES) in verifier.HOST_LIBRARY
    assert verifier.HOST_CASES["python-host-clean"][1] is None


def test_host_command_honors_python_environment(verifier):
    command = verifier.host_command("/venv/bin/python", "host.py", "lib.so", "clean")
    assert command == ["/venv/bin/python", "host.py", "lib.so", "clean"]
    assert not {"-I", "-E", "-S"} & set(command)


RESPONSES = {
    "address": (-6, "ERROR: AddressSanitizer: heap-use-after-free"),
    "undefined": (1, "fault.cpp:1: runtime error: signed integer overflow"),
    "leak": (
        1,
        "=ERROR: LeakSanitizer: detected memory leaks\nDirect leak of 4242 byte(s)",
    ),
    "retained": (0, ""),
    "clean": (0, ""),
    "application-leak": (
        1,
        "=ERROR: LeakSanitizer: detected memory leaks\nDirect leak of 4243 byte(s)",
    ),
}


def run_verifier(verifier, tmp_path, monkeypatch, responses):
    runtime = tmp_path / "runtime" / "libclang_rt.asan.so"
    runtime.parent.mkdir()
    runtime.touch()
    monkeypatch.setattr(verifier, "address_runtime", lambda compiler: runtime)
    monkeypatch.setattr(
        verifier.subprocess,
        "check_output",
        lambda *args, **kwargs: "clang version 23.1.3\n",
    )
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        assert kwargs["timeout"]
        if command[0] == "clang++":
            return subprocess.CompletedProcess(command, 0)
        key = command[-1] if command[0] == "/venv/bin/python" else Path(command[0]).name
        returncode, stderr = responses[key]
        return subprocess.CompletedProcess(command, returncode, "", stderr)

    monkeypatch.setattr(verifier.subprocess, "run", fake_run)
    monkeypatch.setenv("LD_PRELOAD", "/stale/preload.so")
    output = tmp_path / "probes"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "verify",
            "--compiler",
            "clang++",
            "--python",
            "/venv/bin/python",
            "--output",
            str(output),
        ],
    )
    verifier.main()
    return calls, runtime, output


def test_probes_and_cpython_host_use_the_gate_settings(verifier, tmp_path, monkeypatch):
    calls, runtime, output = run_verifier(verifier, tmp_path, monkeypatch, RESPONSES)
    executions = [
        (command, kwargs["env"]) for command, kwargs in calls if "env" in kwargs
    ]
    assert [Path(command[0]).name for command, _ in executions[:4]] == list(
        verifier.CASES
    )
    settings = sanitizer_options()
    for _, environment in executions:
        assert {key: environment[key] for key in settings} == settings
    host = [
        (command, env)
        for command, env in executions
        if command[0] == "/venv/bin/python"
    ]
    assert [command[-1] for command, _ in host] == ["clean", "application-leak"]
    for _, environment in host:
        assert environment["LD_PRELOAD"] == str(runtime)
    for _, environment in executions[:4]:
        assert "LD_PRELOAD" not in environment
    library_build = next(c for c, _ in calls if c[0] == "clang++" and "-shared" in c)
    assert {"-fPIC", "-shared-libasan", "-fsanitize=address,undefined"} <= set(
        library_build
    )
    for name in [*verifier.CASES, *verifier.HOST_CASES]:
        assert (output / (name + ".log")).is_file()
    assert "detect_leaks=1" in (output / "settings.txt").read_text()


@pytest.mark.parametrize(
    "key,response",
    [
        ("leak", (0, "")),  # LSan inactive or unable to run
        ("application-leak", (0, "")),  # host suppression hid an application leak
        (
            "clean",
            (
                1,
                "=ERROR: LeakSanitizer: detected memory leaks\nDirect leak of 64 byte(s)",
            ),
        ),
        ("retained", (1, "=ERROR: LeakSanitizer: detected memory leaks")),
    ],
)
def test_any_failed_leak_control_fails_the_probe(
    verifier, tmp_path, monkeypatch, key, response
):
    with pytest.raises(RuntimeError):
        run_verifier(
            verifier, tmp_path, monkeypatch, dict(RESPONSES, **{key: response})
        )


def workflow():
    return yaml.safe_load(
        (ROOT / ".github/workflows/native-sanitizers.yml").read_text()
    )


def test_workflow_runs_leak_probes_and_tracks_new_inputs():
    document = workflow()
    triggers = document.get("on", document.get(True))
    for event in ("pull_request", "push"):
        paths = triggers[event]["paths"]
        for path in (
            "tools/sanitizer_settings.py",
            "tools/lsan-cpython.supp",
            "tests/test_native_leak_sanitizer.py",
        ):
            assert path in paths
    steps = document["jobs"]["native-sanitizers"]["steps"]
    runs = [step.get("run", "") for step in steps]
    probe = next(run for run in runs if "verify_native_sanitizers.py" in run)
    assert "--compiler clang++" in probe and '--python "$PWD/.venv/bin/python"' in probe
    assert any("tools/run_native_sanitizers.sh build/sanitizers" in run for run in runs)
    assert any("tests/test_native_leak_sanitizer.py" in run for run in runs)


def test_leak_settings_leave_sdk_identity_and_thread_job_unchanged():
    document = workflow()
    jobs = document["jobs"]
    for job, step_id in (
        ("native-sanitizers", "sdk-cache"),
        ("native-thread-sanitizer", "thread-cache"),
    ):
        key = next(s for s in jobs[job]["steps"] if s.get("id") == step_id)["with"][
            "key"
        ]
        assert "sanitizer_settings" not in key and "lsan" not in key
    thread = str(jobs["native-thread-sanitizer"])
    assert "sanitizer_settings" not in thread and "lsan" not in thread
