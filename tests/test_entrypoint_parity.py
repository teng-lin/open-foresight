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
    assert report["problems"] == ["gate bindings-check: no workflow calls tools/check_dart_bindings.py; wire it or declare local_only with a reason"]
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"]
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
