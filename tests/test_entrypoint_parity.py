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


def workflow(*commands, job="build", uses=()):
    steps = "\n".join([f"      - uses: {name}" for name in uses] + [f"      - run: {json.dumps(command)}" for command in commands])
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
    assert all(gate["called_by"] or gate["may_call"] for gate in report["gates"].values() if not gate["local_only"])
    # The one gate no step calls directly: the hosted acceptance-audio job runs it inside a container through
    # tools/linux_acceptance.sh, under a selection variable. That is reported, never counted as a pass.
    assert report["wiring_unverified"] == ["integration-virtual-audio"]
    assert all("tools/linux_acceptance.sh" in label for label in report["gates"]["integration-virtual-audio"]["may_call"])
    assert not any("acceptance-cpu" in label or "acceptance-deb" in label for label in report["gates"]["integration-virtual-audio"]["may_call"])
    assert any("acceptance-cpu" in label for label in report["gates"]["integration-models"]["may_call"])
    assert parity.main([]) == 0


def test_a_gate_no_workflow_calls_must_say_why(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native")})
    report = parity.check(root, inventory())
    assert report["problems"] == ["gate bindings-check: no workflow step calls `tools/check_dart_bindings.py`; wire it or declare local_only with a reason"]
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"] and report["gates"]["native-stage"]["may_call"] == []
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
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh", uses=["./.github/actions/bindings"])}, {"bindings": action})
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
    monkeypatch.setattr(parity, "check", lambda root: {"problems": ["gate x: drifted"], "gates": {}, "runs": 1, "inline_runners": [], "wiring_unverified": []})
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
    # A variable may choose any stage, so it is evidence of wiring, not a pass: the gate is unverified.
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build"] and gate["wiring_unverified"] is True
    assert report["problems"] == [] and report["wiring_unverified"] == ["native-stage"]
    exact = calling(tmp_path / "again", 'bash tools/build.sh --stage "$STAGE"', "bash tools/build.sh --stage native", extra=NATIVE)
    assert exact["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"] and exact["gates"]["native-stage"]["may_call"] == []
    assert exact["gates"]["native-stage"]["wiring_unverified"] is False
    assert exact["wiring_unverified"] == []


def test_a_job_or_step_that_can_never_run_calls_nothing(tmp_path):
    never_step = "on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - if: false\n        run: bash tools/build.sh --stage native\n      - if: ${{ false }}\n        run: bash tools/build.sh --stage native\n"
    never_job = "on: push\njobs:\n  j:\n    if: 'false'\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
    for text in (never_step, never_job):
        root = tree(tmp_path / str(hash(text)), {"ci.yml": text})
        report = parity.check(root, inventory(**NATIVE))
        assert report["gates"]["native-stage"]["called_by"] == [], text
    conditional = "on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n      - if: github.event_name == 'push'\n        run: bash tools/build.sh --stage native\n"
    assert parity.check(tree(tmp_path / "ok", {"ci.yml": conditional}), inventory(**NATIVE))["gates"]["native-stage"]["called_by"]


def test_a_script_run_through_a_called_shell_script_is_may_call_and_says_via(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/b.sh audio")})
    (root / "tools/b.sh").write_text("#!/bin/sh\n# tools/build.sh --stage native is not run here\nif [ \"$1\" = audio ]; then\n  docker run image python3 tools/build.sh \\\n    --stage native\nfi\n")
    report = parity.check(root, inventory(**NATIVE))
    gate = report["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build via tools/b.sh"] and gate["wiring_unverified"]


def test_scripts_that_call_each_other_cannot_loop_forever(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/b.sh")})
    (root / "tools/b.sh").write_text("bash tools/c.sh\n")
    (root / "tools/c.sh").write_text("bash tools/b.sh\nbash tools/build.sh --stage native\n")
    report = parity.check(root, inventory(**NATIVE))
    assert report["gates"]["native-stage"]["may_call"] == [".github/workflows/ci.yml:build via tools/c.sh"]
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


# ------------------------------------------------- review round 2: hostile workflow files

BOMB = (
    "on: push\nx: &a [1,1,1,1,1,1,1,1,1]\ny: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]\nz: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]\n"
    "jobs:\n  build:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
)


def problems_for(tmp_path, text, name="ci.yml"):
    return parity.check(tree(tmp_path, {name: text}), inventory(**NATIVE))["problems"]


def test_anchors_and_aliases_are_refused_instead_of_expanded(tmp_path):
    problems = problems_for(tmp_path, BOMB)
    assert any("anchors and aliases are not accepted" in problem for problem in problems)
    anchored = workflow("echo hi").replace("steps:", "steps: &s", 1)
    assert any("anchors and aliases" in problem for problem in problems_for(tmp_path / "two", anchored))


def test_duplicate_keys_are_refused_instead_of_letting_the_last_win(tmp_path):
    text = (
        "on: push\njobs:\n  build:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
        "    steps:\n      - run: echo nothing\n"
    )
    assert any("duplicate keys: steps" in problem for problem in problems_for(tmp_path, text))
    twice = "on: push\njobs:\n  a:\n    runs-on: x\n    steps: []\n  a:\n    runs-on: y\n    steps: []\n"
    assert any("duplicate keys: a" in problem for problem in problems_for(tmp_path / "jobs", twice))


def test_deeply_nested_yaml_is_a_problem_not_a_crash(tmp_path):
    problems = problems_for(tmp_path, "on: push\njobs: " + "[" * 100_000)
    assert problems and all("Traceback" not in problem for problem in problems)


def test_only_yml_and_yaml_workflows_and_actions_are_read(tmp_path):
    call = workflow("bash tools/build.sh --stage native")
    root = tree(tmp_path, {"ci.yml.bak": call, "ci.ymlx": call, "ci.yxml": call, "ci.yml~": call})
    report = parity.check(root, inventory(**NATIVE))
    assert report["gates"]["native-stage"]["called_by"] == []  # nothing real calls it
    assert any("no workflow files" in problem or "native-stage" in problem for problem in report["problems"])
    for extension in ("yml", "yaml"):
        root = tree(tmp_path / extension, {f"ci.{extension}": call})
        assert parity.check(root, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == [f".github/workflows/ci.{extension}:build"]
    action = "runs:\n  using: composite\n  steps:\n    - run: bash tools/build.sh --stage native\n      shell: bash\n"
    root = tree(tmp_path / "action", {"ci.yml": workflow("echo hi", uses=["./.github/actions/a"])}, actions={"a": action})
    (root / ".github/actions/a/action.yml").rename(root / ".github/actions/a/action.yaml")
    assert parity.check(root, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == [".github/actions/a/action.yaml:(action)"]


# ------------------------------------------------- review round 3: what never executes, and what only might

HEREDOC_NO_CALL = "cat > run.sh <<'EOF'\nbash tools/build.sh --stage native\nEOF\nchmod +x run.sh"


@pytest.mark.parametrize(
    "command",
    [
        HEREDOC_NO_CALL,
        "cat > run.sh <<EOF\nbash tools/build.sh --stage native\nEOF",
        'cat <<"EOF" > run.sh\nbash tools/build.sh --stage native\nEOF',
        "cat <<-EOF\n\tbash tools/build.sh --stage native\n\tEOF\ntrue",
        "bash tools/build.sh --stage native --build-only",
        "bash tools/build.sh --stage=native --build-only",
    ],
)
def test_heredoc_bodies_and_build_only_runs_are_not_calls(tmp_path, command):
    report = calling(tmp_path, command, extra=NATIVE)
    gate = report["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == []
    assert any(problem.startswith("gate native-stage: no workflow step calls") for problem in report["problems"])


@pytest.mark.parametrize(
    "command",
    [
        "bash <<'EOF'\nbash tools/build.sh --stage native\nEOF",
        "sh <<EOF\nbash tools/build.sh --stage native\nEOF",
        "cat <<EOF | bash\nbash tools/build.sh --stage native\nEOF\nbash tools/build.sh --stage native",
    ],
)
def test_a_heredoc_fed_to_a_shell_does_run_its_body(tmp_path, command):
    assert calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]["called_by"]


def test_text_after_a_heredoc_is_still_read(tmp_path):
    command = "cat <<'EOF' > note\nnothing here\nEOF\nbash tools/build.sh --stage native"
    assert calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"]
    assert parity.strip_heredocs("cat <<'EOF'\nx\nEOF\ny") == "cat \ny"
    tabbed = "cat <<-EOF\n\tnot a call\n\tEOF\nbash tools/build.sh --stage native"
    assert calling(tmp_path / "tabs", tabbed, extra=NATIVE)["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"]


DISPATCHER = """#!/usr/bin/env bash
set -euo pipefail
task_suite=${1:?cpu, audio, or deb}
if [[ "$task_suite" == deb ]]; then
  bash tools/build.sh --stage package
  exit 0
fi
[[ "$task_suite" == cpu || "$task_suite" == audio ]] || { echo bad >&2; exit 2; }
if [[ "$task_suite" == cpu && "${CPU_SELECTED:-true}" == false ]]; then
  exit 0
fi
if [[ "$task_suite" == cpu ]]; then
  docker run image python3 tools/build.sh --stage native
elif [[ "$task_suite" == audio ]]; then
  docker run image python3 tools/build.sh --stage core
else
  bash tools/build.sh --stage desktop
fi
"""


def dispatched(tmp_path, argument):
    root = tree(tmp_path, {"ci.yml": workflow(f"bash tools/d.sh {argument}")}, scripts=("tools/build.sh", "tools/check_dart_bindings.py"))
    (root / "tools/d.sh").write_text(DISPATCHER)
    gates = {name: {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", name]} for name in ("package", "native", "core", "desktop")}
    report = parity.check(root, {"gates": gates})
    return {name: gate["may_call"] for name, gate in report["gates"].items()}, report


@pytest.mark.parametrize(
    ("argument", "expected"),
    [
        ("deb", {"package"}),  # the taken branch exits before anything else
        ("cpu", {"native"}),  # an unknown environment test does not hide the branch, and the other branches are dropped
        ("audio", {"core"}),
        ("other", {"desktop"}),
        ('"$SUITE"', {"package", "native", "core", "desktop"}),  # a variable argument selects nothing
    ],
)
def test_a_dispatcher_script_is_read_with_the_callers_literal_argument(tmp_path, argument, expected):
    may, report = dispatched(tmp_path, argument)
    assert {name for name, labels in may.items() if labels} == expected
    assert all(gate["called_by"] == [] for gate in report["gates"].values())
    assert set(report["wiring_unverified"]) == expected


def test_reachable_text_follows_branches_exits_and_unknown_tests():
    text = parity.reachable_text(DISPATCHER, ["deb"])
    assert "package" in text and "native" not in text and "exit 0" in text
    assert "native" in parity.reachable_text(DISPATCHER, ["cpu"]) and "core" not in parity.reachable_text(DISPATCHER, ["cpu"])
    single = 'if [ "$1" = a ]; then\n  echo one\nelif [ "$1" != b ]; then\n  echo two\nelse\n  echo three\nfi\n'
    assert parity.reachable_text(single, ["a"]).split() == ["echo", "one"]
    assert parity.reachable_text(single, ["c"]).split() == ["echo", "two"]
    assert parity.reachable_text(single, ["b"]).split() == ["echo", "three"]
    assert parity.reachable_text(single, ["$X"]).split() == ["echo", "one", "echo", "two", "echo", "three"]
    unknown_first = 'if [[ "${E:-x}" == y ]]; then\n  echo env\nelif [[ "$1" == a ]]; then\n  echo arg\nelse\n  echo rest\nfi\n'
    assert "env" in parity.reachable_text(unknown_first, ["a"]) and "rest" in parity.reachable_text(unknown_first, ["a"])
    oneline = 'if [[ "$1" == a ]]; then echo here\nfi\nif [[ "$1" == b ]]; then echo hidden\nfi\nexit 0\necho after\n'
    assert parity.reachable_text(oneline, ["a"]).split() == ["echo", "here", "exit", "0"]
    assert parity.reachable_text("if cmd; then\n  echo x\nfi\n", []).split() == ["echo", "x"]


def test_evaluate_is_three_valued():
    bindings = {"s": "cpu"}
    assert parity.evaluate('[[ "$s" == cpu ]]', bindings) is True
    assert parity.evaluate('[[ "$s" != cpu ]]', bindings) is False
    assert parity.evaluate('[[ "$s" == cpu && "${E:-1}" == false ]]', bindings) is None
    assert parity.evaluate('[[ "$s" == audio && "${E:-1}" == false ]]', bindings) is False
    assert parity.evaluate('[[ "$s" == cpu || "${E:-1}" == false ]]', bindings) is True
    assert parity.evaluate('[[ "$s" == audio ]] || [[ "$s" == cpu ]]', bindings) is True
    assert parity.evaluate('[[ "$s" == audio ]] && [[ "$s" == cpu ]]', bindings) is False
    assert parity.evaluate('[[ "$s" == audio ]] || [[ "${E}" == x ]] && [[ "$s" == cpu ]]', bindings) is None
    assert parity.evaluate("command -v tool", bindings) is None and parity.evaluate("", bindings) is None
    assert parity.evaluate('[[ "$other" == cpu ]]', bindings) is None
    # A command in the condition can succeed or fail whatever the tests say.
    assert parity.evaluate('[[ "$s" == cpu ]] && command -v tool', bindings) is None
    assert parity.evaluate('[[ "$s" == audio ]] || command -v tool', bindings) is None


def test_a_build_only_call_does_not_satisfy_a_stage_but_a_gate_that_asks_for_it_is_satisfied(tmp_path):
    argv = ["bash", "tools/build.sh", "--stage", "native", "--build-only"]
    gate = {"gates": {"build-native": {"kind": "command", "argv": argv}}}
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native --build-only")})
    assert parity.check(root, gate)["gates"]["build-native"]["called_by"] == [".github/workflows/ci.yml:build"]


def test_the_wiring_unverified_gates_are_listed_in_the_text_output(capsys, tmp_path, monkeypatch):
    root = tree(tmp_path, {"ci.yml": workflow('bash tools/build.sh --stage "$S"')})
    monkeypatch.setattr(parity, "boundary_inventory", type("B", (), {"load": staticmethod(lambda r: inventory(**NATIVE)), "_argv_entrypoints": staticmethod(parity.boundary_inventory._argv_entrypoints)}))
    assert parity.main([], root=root) in (0, 1)
    assert "Wiring unverified: native-stage" in capsys.readouterr().out


# ------------------------------------------------- review round 4: only an executing position is a call

@pytest.mark.parametrize(
    "command",
    [
        "shellcheck tools/build.sh",
        "shellcheck -x tools/build.sh",
        "bash -n tools/build.sh",
        "sh -n tools/build.sh",
        "python -m py_compile tools/check_dart_bindings.py",
        "python3 -m py_compile tools/check_dart_bindings.py",
        "ruff check tools/check_dart_bindings.py",
        "ruff format tools/check_dart_bindings.py",
        "xargs -n1 tools/build.sh",
        "git diff tools/build.sh",
        "cat tools/build.sh | head",
        "wc -l tools/build.sh",
        r"find . -exec tools/build.sh {} \;",
        "mypy tools/check_dart_bindings.py",
        "python -m mypy tools/check_dart_bindings.py",
        "bash -c tools/build.sh",
        "stat tools/build.sh && ls tools/build.sh",
        "awk 1 tools/build.sh",
        "tar czf out.tgz tools/build.sh",
        "bash tools/other.sh tools/build.sh",
    ],
)
def test_lint_compile_and_probe_commands_are_not_calls(tmp_path, command):
    report = calling(tmp_path, command, extra=NATIVE)
    gate = report["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [], command


@pytest.mark.parametrize(
    "command",
    [
        "tools/build.sh --stage native",
        "./tools/build.sh --stage native",
        "bash tools/build.sh --stage native",
        "bash -e tools/build.sh --stage native",
        "bash -euo pipefail tools/build.sh --stage native",
        "sh tools/build.sh --stage native",
        "source tools/build.sh --stage native",
        ". tools/build.sh --stage native",
        "exec tools/build.sh --stage native",
        "env FOO=1 tools/build.sh --stage native",
        "FOO=1 bash tools/build.sh --stage native",
        "time bash tools/build.sh --stage native",
        "timeout 60 bash tools/build.sh --stage native",
        "timeout 60 tools/build.sh --stage native",
        "xvfb-run -a dbus-run-session -- bash tools/build.sh --stage native",
        "xvfb-run -a tools/build.sh --stage native",
        "python tools/build.sh --stage native",
        ".venv/bin/python tools/build.sh --stage native",
        "python3.13 -u tools/build.sh --stage native",
        "docker run --rm image python3 tools/build.sh --stage native",
        "if tools/build.sh --stage native; then echo ok; fi",
        "for i in 1; do bash tools/build.sh --stage native; done",
    ],
)
def test_the_executing_positions_are_the_calls(tmp_path, command):
    assert calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"], command


def test_modules_run_by_an_interpreter_count_and_other_dash_m_heads_do_not(tmp_path):
    gate = {"gates": {"bindings": {"kind": "command", "argv": ["{python}", "-m", "tools.check_dart_bindings"]}}}
    for command, called in (
        ("python -m tools.check_dart_bindings", True),
        (".venv/bin/python3.13 -m tools.check_dart_bindings", True),
        ("python -m py_compile tools.check_dart_bindings", False),
        ("python -m pytest tools.check_dart_bindings", False),
        ("echo -m tools.check_dart_bindings", False),
    ):
        root = tree(tmp_path / str(abs(hash(command))), {"ci.yml": workflow(command)})
        assert bool(parity.check(root, gate)["gates"]["bindings"]["called_by"]) is called, command


def test_a_path_that_climbs_out_of_the_tools_directory_is_not_a_script(tmp_path):
    assert parity.calls_in("bash tools/../tools/build.sh --stage native") == []
    assert parity.calls_in("bash tools/a/../build.sh") == []
    assert parity.calls_in("bash tools/build.sh") == [("tools/build.sh", ())]
    assert parity.calls_in("bash /tools/build.sh") == []


def _action(run):
    return f"runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: {json.dumps(run)}\n"


def test_an_action_nothing_uses_and_a_workflow_nothing_triggers_call_nothing(tmp_path):
    call = "bash tools/build.sh --stage native"
    lonely_action = tree(tmp_path / "a", {"ci.yml": workflow("echo hi")}, {"build": _action(call)})
    assert parity.check(lonely_action, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == []
    used = tree(tmp_path / "b", {"ci.yml": workflow("echo hi", uses=["./.github/actions/build"])}, {"build": _action(call)})
    assert parity.check(used, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == [".github/actions/build/action.yml:(action)"]
    nested = tree(tmp_path / "c", {"ci.yml": workflow("echo hi", uses=["./.github/actions/outer/"])}, {"outer": _action("echo hi").replace("- shell: bash", "- uses: ./.github/actions/build\n    - shell: bash"), "build": _action(call)})
    assert parity.check(nested, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == [".github/actions/build/action.yml:(action)"]
    remote = tree(tmp_path / "d", {"ci.yml": workflow("echo hi", uses=["actions/checkout@v4", "someone/.github/actions/build@v1", "x/.github/actions/build"])}, {"build": _action(call)})
    assert parity.check(remote, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == []


@pytest.mark.parametrize("trigger", ["workflow_call", "[workflow_call]", "{workflow_call: {}}"])
def test_a_workflow_only_others_can_call_counts_only_when_something_calls_it(tmp_path, trigger):
    callee = f"on: {trigger}\njobs:\n  build:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
    alone = tree(tmp_path / "alone", {"callee.yml": callee, "ci.yml": workflow("echo hi")})
    assert parity.check(alone, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == []
    caller = "on: push\njobs:\n  go:\n    uses: ./.github/workflows/callee.yml\n"
    called = tree(tmp_path / "called", {"callee.yml": callee, "ci.yml": caller})
    assert parity.check(called, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == [".github/workflows/callee.yml:build"]
    dead_caller = "on: workflow_call\njobs:\n  go:\n    uses: ./.github/workflows/callee.yml\n"
    chain = tree(tmp_path / "chain", {"callee.yml": callee, "mid.yml": dead_caller, "ci.yml": workflow("echo hi")})
    assert parity.check(chain, inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == []
    also_pushed = callee.replace(f"on: {trigger}", "on: [push, workflow_call]")
    assert parity.check(tree(tmp_path / "both", {"callee.yml": also_pushed, "ci.yml": workflow("echo hi")}), inventory(**NATIVE))["gates"]["native-stage"]["called_by"]


def test_a_conditionally_skipped_call_of_a_workflow_or_action_does_not_reach_it(tmp_path):
    callee = "on: workflow_call\njobs:\n  build:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
    caller = "on: push\njobs:\n  go:\n    if: false\n    uses: ./.github/workflows/callee.yml\n"
    assert parity.check(tree(tmp_path, {"callee.yml": callee, "ci.yml": caller}), inventory(**NATIVE))["gates"]["native-stage"]["called_by"] == []


def test_duplicate_keys_are_counted_in_one_pass_not_by_rescanning(tmp_path, monkeypatch):
    seen = []
    real = parity.Counter
    monkeypatch.setattr(parity, "Counter", lambda keys: seen.append(len(list(keys))) or real(keys))
    keys = "".join(f"  k{i}: 1\n" for i in range(5000))
    text = f"on: push\nenv:\n{keys}jobs:\n  build:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage native\n"
    report = parity.check(tree(tmp_path, {"ci.yml": text}), inventory(**NATIVE))
    assert report["gates"]["native-stage"]["called_by"] and 5000 in seen


def test_may_call_evidence_is_in_the_default_output_not_only_in_json(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(parity, "boundary_inventory", type("B", (), {"load": staticmethod(lambda r: inventory(**NATIVE)), "_argv_entrypoints": staticmethod(parity.boundary_inventory._argv_entrypoints)}))
    other = tree(tmp_path / "other", {"ci.yml": workflow("bash tools/b.sh")})
    (other / "tools/b.sh").write_text("bash tools/build.sh --stage native\n")
    assert parity.main([], root=other) in (0, 1)
    out = capsys.readouterr().out
    assert "Wiring unverified: native-stage" in out
    two_jobs = workflow("bash tools/build.sh --stage native") + "  other:\n    runs-on: x\n    steps:\n      - run: bash tools/build.sh --stage \"$S\"\n"
    third = tree(tmp_path / "third", {"ci.yml": two_jobs})
    assert parity.main([], root=third) in (0, 1)
    assert "May also run (not verified): native-stage" in capsys.readouterr().out
