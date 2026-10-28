"""Local gates and hosted workflows call the same checked-in entrypoints."""

import copy
import json
from pathlib import Path

import pytest

from tools import check_entrypoint_parity as parity

ROOT = Path(__file__).resolve().parents[1]


def tree(tmp_path, workflows, actions=None, scripts=("tools/build.sh", "tools/check_dart_bindings.py")):
    root = tmp_path / "tree"
    (root / ".github/workflows").mkdir(parents=True)
    for name, text in workflows.items():
        (root / ".github/workflows" / name).write_text(text)
    for name, text in (actions or {}).items():
        (root / ".github/actions" / name).mkdir(parents=True)
        (root / ".github/actions" / name / "action.yml").write_text(text)
    for script in scripts:
        (root / script).parent.mkdir(parents=True, exist_ok=True)
        (root / script).write_text("")
    return root


def workflow(*commands, job="build"):
    steps = "\n".join(f"      - run: {json.dumps(command)}" for command in commands)
    return f"on: push\njobs:\n  {job}:\n    runs-on: ubuntu-24.04\n    steps:\n{steps}\n"


INVENTORY = {
    "gates": {
        "bindings-check": {"kind": "command", "argv": ["{python}", "tools/check_dart_bindings.py"]},
        "native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"]},
        "manual-probes": {"kind": "manual"},
    }
}


def inventory(**local_only):
    result = copy.deepcopy(INVENTORY)
    for name, reason in local_only.items():
        result["gates"][name]["local_only"] = reason
    return result


def test_the_real_gates_and_workflows_agree():
    report = parity.check(ROOT)
    assert report["problems"] == []
    assert report["runs"] > 100 and set(report["gates"]) >= {"platform-contracts", "bindings-check", "document-sandbox", "dmg-contracts"}
    assert report["gates"]["shared-guards"]["local_only"] and not report["gates"]["shared-guards"]["called_by"]
    assert all(gate["called_by"] for gate in report["gates"].values() if not gate["local_only"])
    assert parity.main([]) == 0


def test_a_gate_no_workflow_calls_must_say_why(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native")})
    report = parity.check(root, inventory())
    assert report["problems"] == ["gate bindings-check: no workflow step calls `tools/check_dart_bindings.py`; wire it or declare local_only with a reason"]
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"] and report["gates"]["native-stage"]["ambiguous"] == []
    assert parity.check(root, inventory(**{"bindings-check": "runs only before a push"}))["problems"] == []


def test_a_local_only_declaration_a_workflow_now_contradicts_is_stale(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("python tools/check_dart_bindings.py", "bash tools/build.sh")})
    problems = parity.check(root, inventory(**{"native-stage": "never in CI"}))["problems"]
    assert problems == ["gate native-stage: declared local_only but .github/workflows/ci.yml:build calls it; remove the stale declaration"]


@pytest.mark.parametrize("reason", ["", "   ", 7])
def test_local_only_needs_a_reason(tmp_path, reason):
    root = tree(tmp_path, {"ci.yml": workflow("python tools/check_dart_bindings.py", "bash tools/build.sh")})
    assert "gate bindings-check: local_only needs a reason" in parity.check(root, inventory(**{"bindings-check": reason}))["problems"]


def test_a_workflow_calling_a_script_that_does_not_exist_is_reported(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh", "python tools/check_dart_bindings.py", "python tools/gone.py", "python -m tools.also_gone")})
    problems = parity.check(root, inventory())["problems"]
    assert any("tools/gone.py, which does not exist" in problem for problem in problems)
    assert any("tools/also_gone.py, which does not exist" in problem for problem in problems)


def test_python_module_invocations_and_composite_actions_count_as_calls(tmp_path):
    action = "runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: python -m tools.check_dart_bindings\n"
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh")}, {"bindings": action})
    report = parity.check(root, inventory())
    assert report["problems"] == []
    assert report["gates"]["bindings-check"]["called_by"] == [".github/actions/bindings/action.yml:(action)"]


@pytest.mark.parametrize(
    ("workflows", "fragment"),
    [
        ({"a.yml": "jobs: ["}, "not valid YAML"),
        ({"a.yml": "- just\n- a list\n"}, "top level is not a mapping"),
        ({"a.yml": "on: push\njobs: [1]\n"}, "jobs is not a mapping"),
        ({"a.yml": "on: push\njobs:\n  x:\n    runs-on: y\n"}, "job x has no steps"),
        ({"a.yml": "on: push\njobs:\n  x:\n    steps: oops\n"}, "steps must be a list"),
        ({"a.yml": "on: push\njobs:\n  x:\n    steps: [1]\n"}, "step 0 is not a mapping"),
        ({"a.yml": "on: push\njobs:\n  x:\n    steps:\n      - run: [1]\n"}, "run that is not text"),
        ({"a.yml": "name: neither\n"}, "neither a workflow with jobs nor a composite action"),
    ],
)
def test_anything_that_does_not_parse_into_the_expected_shape_fails_closed(tmp_path, workflows, fragment):
    root = tree(tmp_path, workflows)
    assert any(fragment in problem for problem in parity.check(root, inventory(**{"bindings-check": "x", "native-stage": "x"}))["problems"])


def test_a_reusable_workflow_call_has_no_steps_and_is_not_a_problem(tmp_path):
    reusable = "on: push\njobs:\n  call:\n    uses: ./.github/workflows/other.yml\n"
    root = tree(tmp_path, {"a.yml": reusable, "b.yml": workflow("bash tools/build.sh", "python tools/check_dart_bindings.py")})
    assert parity.check(root, inventory())["problems"] == []


def test_a_tree_with_no_workflows_cannot_pass_vacuously(tmp_path):
    root = tmp_path / "empty"
    root.mkdir()
    assert parity.check(root, inventory())["problems"][0].startswith("no workflow files were found")


def test_inline_test_runners_are_reported_but_never_fail(tmp_path, capsys):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh", "python tools/check_dart_bindings.py", "dart test test/a_test.dart", "flutter test && ctest --test-dir build")})
    report = parity.check(root, inventory())
    assert report["problems"] == []
    assert {item["runner"] for item in report["inline_runners"]} == {"dart test", "flutter test", "ctest"}


def test_cli_json_and_text_output_and_exit_status(capsys, monkeypatch):
    assert parity.main(["--json"]) == 0
    assert json.loads(capsys.readouterr().out)["problems"] == []
    assert parity.main([]) == 0 and "command gates" in capsys.readouterr().out
    monkeypatch.setattr(parity, "check", lambda root: {"problems": ["gate x: drifted"], "gates": {}, "runs": 1, "inline_runners": []})
    assert parity.main([]) == 1
    assert "- gate x: drifted" in capsys.readouterr().err


# ------------------------------------------------------- what counts as a call


def calling(tmp_path, *commands, extra=None, scripts=("tools/build.sh", "tools/check_dart_bindings.py", "tools/b.sh", "tools/c.sh")):
    root = tree(tmp_path, {"ci.yml": workflow(*commands)}, scripts=scripts)
    return parity.check(root, inventory(**(extra or {})))


NATIVE = {"bindings-check": "local"}


@pytest.mark.parametrize(
    "command",
    [
        "# TODO: re-enable bash tools/build.sh --stage native",
        "echo skipping tools/build.sh --stage native",
        'echo "tools/build.sh --stage native"',
        "cp tools/build.sh /tmp/build.sh",
        "chmod +x tools/build.sh",
        "test -x tools/build.sh && true",
        "sha256sum tools/build.sh",
        "bash tools/build.sh --stage package",
        "cat tools/build.sh | head",
        "git add tools/build.sh",
        "if true; then echo tools/build.sh --stage native; fi",
        "for s in 1; do cp tools/build.sh /tmp/x; done",
        "time chmod +x tools/build.sh",
        'python -c "import subprocess; subprocess.run([\'tools/build.sh\'])"',
    ],
)
def test_mentions_comments_quoted_strings_and_other_stages_are_not_calls(tmp_path, command):
    report = calling(tmp_path, command, extra=NATIVE)
    assert report["gates"]["native-stage"]["called_by"] == []
    assert any(problem.startswith("gate native-stage: no workflow step calls") for problem in report["problems"])


@pytest.mark.parametrize(
    "command",
    [
        "bash tools/build.sh --platform linux --stage native",
        "bash tools/build.sh --stage=native --build-only",
        "FOO=1 bash tools/build.sh --stage native",
        "xvfb-run -a dbus-run-session -- bash tools/build.sh --stage native",
        "if true; then bash tools/build.sh --stage native; fi",
        "echo start && bash tools/build.sh --stage native",
        "bash tools/build.sh --stage native # trailing comment is fine",
        "bash tools/build.sh \\\n  --platform linux \\\n  --stage native",
        "bash tools/build.sh",
        "bash tools/build.sh --stage all",
        "bash ./tools/build.sh --stage native",
    ],
)
def test_real_calls_are_found_through_launchers_operators_and_continuations(tmp_path, command):
    report = calling(tmp_path, command, extra=NATIVE)
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"]
    assert report["problems"] == []


def test_a_stage_chosen_by_a_shell_variable_is_ambiguous_not_exact(tmp_path):
    report = calling(tmp_path, 'bash tools/build.sh --stage "$STAGE"', extra=NATIVE)
    gate = report["gates"]["native-stage"]
    assert gate["called_by"] == gate["ambiguous"] == [".github/workflows/ci.yml:build"]
    assert report["problems"] == []
    exact = calling(tmp_path / "again", 'bash tools/build.sh --stage "$STAGE"', "bash tools/build.sh --stage native", extra=NATIVE)
    assert exact["gates"]["native-stage"]["ambiguous"] == []


def test_a_job_or_step_that_can_never_run_calls_nothing(tmp_path):
    never_step = "on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - if: false\n        run: bash tools/build.sh --stage native\n      - if: ${{ false }}\n        run: bash tools/build.sh --stage native\n"
    never_job = "on: push\njobs:\n  j:\n    if: 'false'\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
    for text in (never_step, never_job):
        root = tree(tmp_path / str(hash(text)), {"ci.yml": text})
        report = parity.check(root, inventory(**NATIVE))
        assert report["gates"]["native-stage"]["called_by"] == [], text
    conditional = "on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - if: github.event_name == 'push'\n        run: bash tools/build.sh --stage native\n"
    assert parity.check(tree(tmp_path / "ok", {"ci.yml": conditional}), inventory(**NATIVE))["gates"]["native-stage"]["called_by"]


def test_a_script_run_through_a_called_shell_script_counts_and_says_via(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/b.sh audio")})
    (root / "tools/b.sh").write_text("#!/bin/sh\n# tools/build.sh --stage native is not run here\nif [ \"$1\" = audio ]; then\n  docker run image python3 tools/build.sh \\\n    --stage native\nfi\n")
    report = parity.check(root, inventory(**NATIVE))
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build via tools/b.sh"]


def test_scripts_that_call_each_other_cannot_loop_forever(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/b.sh")})
    (root / "tools/b.sh").write_text("bash tools/c.sh\n")
    (root / "tools/c.sh").write_text("bash tools/b.sh\nbash tools/build.sh --stage native\n")
    report = parity.check(root, inventory(**NATIVE))
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build via tools/c.sh"]
    # Each script is expanded once per call chain: the cycle b -> c -> b is cut, not re-walked to the depth limit.
    calls = parity.collect_calls([parity.Run("ci.yml", "build", "step", "bash tools/b.sh")], root)
    assert [(call.script, call.via) for call in calls] == [
        ("tools/b.sh", None), ("tools/c.sh", "tools/b.sh"), ("tools/b.sh", "tools/c.sh"), ("tools/build.sh", "tools/c.sh"),
    ]


def test_a_suite_gate_needs_its_own_suite(tmp_path):
    gate = {"gates": {"integration-fast": {"kind": "command", "argv": ["{python}", "tools/integration_gates.py", "--suite", "fast"]}}}
    root = tree(tmp_path, {"ci.yml": workflow("python tools/integration_gates.py --suite models --bundle b")}, scripts=("tools/integration_gates.py",))
    assert parity.check(root, gate)["gates"]["integration-fast"]["called_by"] == []
    root = tree(tmp_path / "two", {"ci.yml": workflow("python tools/integration_gates.py --suite=fast")}, scripts=("tools/integration_gates.py",))
    assert parity.check(root, gate)["problems"] == []


def test_job_ids_that_yaml_one_point_one_reads_as_booleans_stay_text(tmp_path):
    text = "on: push\njobs:\n  on:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n  'yes':\n    runs-on: x\n    steps:\n      - run: echo hi\n"
    root = tree(tmp_path, {"ci.yml": text})
    report = parity.check(root, inventory(**NATIVE))
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:on"]
    assert report["problems"] == []


def test_command_segments_split_like_a_shell_and_drop_comments():
    assert parity.command_segments("a b; c && d | e\n# gone\nf 'x # kept' # dropped") == [["a", "b"], ["c"], ["d"], ["e"], ["f", "x # kept"]]
    assert parity.command_segments("echo 'open\nstill open'\nnext") == [["echo", "open\nstill open"], ["next"]]
    assert parity.command_segments("echo 'never closed") == [["echo", "'never", "closed"]]
    assert parity.calls_in("python -m tools.check_dart_bindings --flag") == [("tools/check_dart_bindings.py", ("--flag",))]
    assert parity.calls_in("echo -m tools.check_dart_bindings") == []
