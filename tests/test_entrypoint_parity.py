"""Local gates and hosted workflows call the same checked-in entrypoints."""

import copy
import json
import os
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


# Gates no workflow step names with a literal stage or suite. Each carries a reason in the inventory; the set is pinned,
# so a new one fails the guard and a shrinking one makes its declaration stale.
ACKNOWLEDGED = {"integration-virtual-audio"}


def test_the_real_gates_and_workflows_agree():
    report = parity.check(ROOT)
    assert report["problems"] == []
    assert report["runs"] > 100 and set(report["gates"]) >= {"platform-contracts", "bindings-check", "document-sandbox", "dmg-contracts"}
    assert report["gates"]["shared-guards"]["local_only"] and not report["gates"]["shared-guards"]["called_by"]
    assert all(gate["called_by"] or gate["may_call"] for gate in report["gates"].values() if not gate["local_only"])
    # The one gate no step calls directly: the hosted acceptance-audio job runs it inside a container through
    # tools/linux_acceptance.sh, under a selection variable. That is reported, never counted as a pass.
    assert report["wiring_unverified"] == sorted(ACKNOWLEDGED)
    assert all("tools/linux_acceptance.sh" in label for label in report["gates"]["integration-virtual-audio"]["may_call"])
    assert any("acceptance-cpu" in label for label in report["gates"]["integration-models"]["may_call"])
    assert parity.main([]) == 0


def test_a_gate_no_workflow_calls_must_say_why(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native")})
    report = parity.check(root, inventory())
    assert report["problems"] == ["gate bindings-check: no workflow step calls `tools/check_dart_bindings.py`; wire it or declare local_only with a reason"]
    assert report["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"] and report["gates"]["native-stage"]["may_call"] == []
    assert parity.check(root, inventory(**{"bindings-check": "runs only before a push"}))["problems"] == []


def test_a_local_only_declaration_a_workflow_now_contradicts_is_stale(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("python tools/check_dart_bindings.py", "bash tools/build.sh --stage native")})
    problems = parity.check(root, inventory(**{"native-stage": "never in CI"}))["problems"]
    assert problems == ["gate native-stage: declared local_only but .github/workflows/ci.yml:build calls it; remove the stale declaration"]


@pytest.mark.parametrize("reason", ["", "   ", 7])
def test_local_only_needs_a_reason(tmp_path, reason):
    root = tree(tmp_path, {"ci.yml": workflow("python tools/check_dart_bindings.py", "bash tools/build.sh --stage native")})
    assert "gate bindings-check: local_only needs a reason" in parity.check(root, inventory(**{"bindings-check": reason}))["problems"]


def test_a_workflow_calling_a_script_that_does_not_exist_is_reported(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native", "python tools/check_dart_bindings.py", "python tools/gone.py", "python -m tools.also_gone")})
    problems = parity.check(root, inventory())["problems"]
    assert any("tools/gone.py, which does not exist" in problem for problem in problems)
    assert any("tools/also_gone.py, which does not exist" in problem for problem in problems)


def test_python_module_invocations_and_composite_actions_count_as_calls(tmp_path):
    action = "runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: python -m tools.check_dart_bindings\n"
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native", uses=["./.github/actions/bindings"])}, {"bindings": action})
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
    root = tree(tmp_path, {"a.yml": reusable, "b.yml": workflow("bash tools/build.sh --stage native", "python tools/check_dart_bindings.py")})
    assert parity.check(root, inventory())["problems"] == []


def test_a_tree_with_no_workflows_cannot_pass_vacuously(tmp_path):
    root = tmp_path / "empty"
    root.mkdir()
    assert parity.check(root, inventory())["problems"][0].startswith("no workflow files were found")


def test_inline_test_runners_are_reported_but_never_fail(tmp_path, capsys):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native", "python tools/check_dart_bindings.py", "dart test test/a_test.dart", "flutter test && ctest --test-dir build")})
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
        "bash tools/build.sh --stage native # trailing comment is fine",
        "bash tools/build.sh \\\n  --platform linux \\\n  --stage native",
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
    assert report["wiring_unverified"] == ["native-stage"]
    assert [problem.split(":")[0] for problem in report["problems"]] == ["gate native-stage"]  # unverified wiring must be acknowledged
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
    assert parity.calls_in("python -m tools.check_dart_bindings --flag") == [("tools/check_dart_bindings.py", ("--flag",), True)]
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
        "sudo bash <<-EOF\n\tbash tools/build.sh --stage native\n\tEOF",
    ],
)
def test_a_heredoc_fed_to_a_shell_is_may_call_never_a_direct_call(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build via <heredoc>"]


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
if false; then bash tools/build.sh --stage hidden; fi
case "$task_suite" in
  cpu) docker run image python3 tools/build.sh --stage native; exit 0 ;;
esac
run_core() { exit 3; bash tools/build.sh --stage function; }
for item in a; do exit 4; done
if [[ "$task_suite" == audio ]]; then
  docker run image python3 tools/build.sh --stage core
else
  bash tools/build.sh --stage desktop
fi
"""


def dispatched(tmp_path, argument):
    root = tree(tmp_path, {"ci.yml": workflow(f"bash tools/d.sh {argument}")}, scripts=("tools/build.sh", "tools/check_dart_bindings.py"))
    (root / "tools/d.sh").write_text(DISPATCHER)
    stages = ("package", "native", "core", "desktop", "hidden", "function")
    gates = {name: {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", name], "wiring_unverified_reason": "dispatcher", "wiring_unverified_relies_on": [".github/workflows/ci.yml:build"]} for name in stages}
    return parity.check(root, {"gates": gates})


@pytest.mark.parametrize("argument", ["deb", "cpu", "audio", "other", '"$SUITE"'])
def test_script_mediated_calls_are_over_approximated_never_evaluated(tmp_path, argument):
    report = dispatched(tmp_path, argument)
    # Every command in the called script counts whatever the argument, branch, exit, case arm, loop or function:
    # the answer cannot depend on a condition the guard would have to interpret.
    assert {name for name, gate in report["gates"].items() if gate["may_call"]} == {"package", "native", "core", "desktop", "hidden", "function"}
    assert all(gate["called_by"] == [] for gate in report["gates"].values())
    assert all(label.endswith("via tools/d.sh") for gate in report["gates"].values() for label in gate["may_call"])
    assert report["problems"] == []  # every gate here acknowledged its unverified wiring


def test_a_one_line_false_if_or_an_exit_in_a_case_arm_cannot_hide_later_commands(tmp_path):
    script = "if false; then echo skipped; fi\ncase $1 in a) exit 0 ;; esac\nf() { exit 1; }\nfor i in 1; do exit 2; done\nbash tools/build.sh --stage native\n"
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/d.sh a")})
    (root / "tools/d.sh").write_text(script)
    gates = {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"], "wiring_unverified_reason": "via d.sh", "wiring_unverified_relies_on": [".github/workflows/ci.yml:build"]}}
    report = parity.check(root, {"gates": gates})
    assert report["gates"]["native-stage"]["may_call"] == [".github/workflows/ci.yml:build via tools/d.sh"]
    assert report["wiring_unverified"] == ["native-stage"] and report["problems"] == []


def test_the_shell_interpreter_is_gone():
    for name in ("evaluate", "reachable_text", "_TEST", "_ATOM", "_ASSIGN_POSITIONAL"):
        assert not hasattr(parity, name), name


def test_a_text_is_tokenized_once_even_with_an_unclosed_quote(monkeypatch):
    seen = []
    real = parity._tokens
    monkeypatch.setattr(parity, "_tokens", lambda text: seen.append(len(text)) or real(text))
    hostile = "echo 'never closed\n" + "bash tools/build.sh --stage native\n" * 3000
    segments = parity.command_segments(hostile)
    assert len(seen) == 1  # one failed lex, then one linear fallback; not one lex per line
    assert sum(1 for segment in segments if "tools/build.sh" in segment) == 3000
    seen.clear()
    parity.command_segments("bash tools/build.sh --stage native\n" * 3000)
    assert len(seen) == 1


def test_comments_with_apostrophes_do_not_open_quotes_and_hash_inside_words_is_kept():
    text = "# don't panic\nbash tools/build.sh --stage native # it's fine\necho a#b $# ${#x}\necho 'x # y'\n"
    segments = parity.command_segments(text)
    assert ["bash", "tools/build.sh", "--stage", "native"] in segments
    assert ["echo", "a#b", "$#", "${#x}"] in segments and ["echo", "x # y"] in segments
    assert parity.strip_comments("a # b\nc") == "a \nc" and parity.strip_comments("'#' \"#\" \\# x") == "'#' \"#\" \\# x"


def test_newlines_separate_commands_but_quoted_newlines_do_not():
    assert parity.command_segments("a b\nc d;e\n\nf && g") == [["a", "b"], ["c", "d"], ["e"], ["f"], ["g"]]
    assert parity.command_segments('echo "a\nb" c\nd') == [["echo", "a\nb", "c"], ["d"]]


def test_a_fan_out_of_scripts_is_read_once_each_not_once_per_path(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/s0.sh")})
    for index in range(40):
        (root / f"tools/s{index}.sh").write_text(f"bash tools/s{index + 1}.sh\nbash tools/s{index + 1}.sh\n")
    (root / "tools/s40.sh").write_text("bash tools/build.sh --stage native\n")
    calls = parity.collect_calls([parity.Run("ci.yml", "build", "step", "bash tools/s0.sh")], root)
    assert len(calls) == 1 + 40 * 2 + 1  # 2 calls per script, 40 scripts, the entry and the final build call; not 2**40


def test_a_script_larger_than_the_caps_fails_closed(tmp_path, monkeypatch):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/big.sh")})
    (root / "tools/big.sh").write_text("echo x\n" * 50)
    monkeypatch.setattr(parity, "MAX_SCRIPT_LINES", 10)
    gates = {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"], "local_only": "x"}}
    assert any("more than the 10 line analysis cap" in problem for problem in parity.check(root, {"gates": gates})["problems"])
    monkeypatch.setattr(parity, "MAX_SCRIPT_LINES", 5000)
    monkeypatch.setattr(parity, "MAX_SCRIPT_BYTES", 20)
    assert any("20 byte analysis cap" in problem for problem in parity.check(root, {"gates": gates})["problems"])
    monkeypatch.setattr(parity, "MAX_SCRIPT_BYTES", 262144)
    monkeypatch.setattr(parity, "MAX_CALLS_PER_STEP", 3)
    (root / "tools/big.sh").write_text("bash tools/a.sh\nbash tools/b.sh\nbash tools/c.sh\nbash tools/d.sh\n")
    assert any("more than 3 calls" in problem for problem in parity.check(root, {"gates": gates})["problems"])
    monkeypatch.setattr(parity, "MAX_CALLS_PER_STEP", 5000)
    monkeypatch.setattr(parity, "MAX_SCRIPTS_PER_STEP", 1)
    (root / "tools/big.sh").write_text("bash tools/a.sh\nbash tools/b.sh\n")
    for name in ("a", "b"):
        (root / f"tools/{name}.sh").write_text("")
    assert any("more than 1 scripts" in problem for problem in parity.check(root, {"gates": gates})["problems"])


def test_an_oversized_workflow_file_is_a_problem(tmp_path, monkeypatch):
    monkeypatch.setattr(parity, "MAX_WORKFLOW_BYTES", 50)
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --stage native")})
    assert any("50 byte analysis cap" in problem for problem in parity.check(root, inventory(**NATIVE))["problems"])


def test_an_unreadable_script_is_a_problem_not_silence(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/b.sh")})
    (root / "tools/b.sh").write_text("bash tools/build.sh --stage native\n")
    (root / "tools/b.sh").chmod(0)
    try:
        problems = parity.check(root, inventory(**NATIVE))["problems"]
    finally:
        (root / "tools/b.sh").chmod(0o644)
    if os.geteuid() != 0:
        assert any("tools/b.sh cannot be read" in problem for problem in problems)


def test_wiring_unverified_must_be_acknowledged_and_must_not_go_stale(tmp_path):
    undeclared = tree(tmp_path / "a", {"ci.yml": workflow('bash tools/build.sh --stage "$S"')})
    problems = parity.check(undeclared, inventory(**NATIVE))["problems"]
    assert problems == ["gate native-stage: no step calls it as a top-level command (.github/workflows/ci.yml:build); call it directly or declare wiring_unverified_reason"]
    declared = {"gates": {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"], "wiring_unverified_reason": "reviewed", "wiring_unverified_relies_on": [".github/workflows/ci.yml:build"]}}}
    assert parity.check(undeclared, declared)["problems"] == []
    direct = tree(tmp_path / "b", {"ci.yml": workflow("bash tools/build.sh --stage native")})
    assert parity.check(direct, declared)["problems"] == ["gate native-stage: declared wiring_unverified_reason but it now has direct evidence or none; remove the stale declaration"]
    for reason in ("", "  ", 7):
        blank = {"gates": {"native-stage": {**declared["gates"]["native-stage"], "wiring_unverified_reason": reason}}}
        assert "gate native-stage: wiring_unverified_reason needs a reason" in parity.check(undeclared, blank)["problems"]


def test_the_real_tree_acknowledges_exactly_the_unverified_gates_it_has():
    report = parity.check(ROOT)
    # The stage gates are verified on both platforms: Linux by the arch build, macOS by the literal matrix in macos.yml.
    for stage in ("core", "desktop", "native", "service"):
        gate = report["gates"][f"{stage}-stage"]
        assert sorted(gate["verified_platforms"]) == ["linux", "macos"] and gate["may_call"] == [], stage
        assert any(label.endswith("macos.yml:macos-checks") for label in gate["called_by"]), stage
    assert report["problems"] == []
    assert report["wiring_unverified"] == sorted(ACKNOWLEDGED)
    assert sorted(name for name, gate in report["gates"].items() if gate["declared_unverified"]) == sorted(ACKNOWLEDGED)
    assert all(report["gates"][name]["called_by"] == [] for name in ACKNOWLEDGED)


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
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert [*gate["called_by"], *gate["may_call"]] == [".github/workflows/ci.yml:build"], command


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
    assert parity.calls_in("bash tools/build.sh") == [("tools/build.sh", (), True)]
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


# ------------------------------------------------- review round 6: heads, dead code, heredoc recognition, missing stage

EXACT = [
    "bash tools/build.sh --stage native",
    "echo start\nbash tools/build.sh --stage native",
    "echo start; bash tools/build.sh --stage native",
    "bash tools/build.sh --stage native | tee log",
    "bash tools/build.sh --stage native 2>&1 | tee log",
    "echo x | exit 0\nbash tools/build.sh --stage native",  # an exit in a pipeline is a subshell: it ends nothing
    "{ echo a; bash tools/build.sh --stage native; } 2>&1 | tee log",  # an unconditional group is transparent
    "FOO=1 bash tools/build.sh --stage native",
    "set -e\nif x; then echo y; fi\nbash tools/build.sh --stage native",  # after a closed block
    "for i in 1; do echo $i; done\nbash tools/build.sh --stage native",
    "case x in a) echo a ;; esac\nbash tools/build.sh --stage native",  # an unmatched ) ends a pattern, not a group
    "f() { echo f; }\nbash tools/build.sh --stage native",
    "x=$(echo y)\nbash tools/build.sh --stage native",
    "test -f a || exit 1\nbash tools/build.sh --stage native",  # the exit is an and-or operand: it may not run
    "if [ -f x ]; then exit 0; fi\nbash tools/build.sh --stage native",
    "(exit 0)\nbash tools/build.sh --stage native",  # a subshell exit ends only the subshell
    "{ true; } && echo ok\nbash tools/build.sh --stage native",
]
MAY = [
    # The five shapes where bash really runs the call and a dead-code pruner dropped it.
    "test -f a || false && bash tools/build.sh --stage native",
    "test -f a && true || bash tools/build.sh --stage native",
    'if false || [[ -n "$A" ]]; then bash tools/build.sh --stage native; fi',
    "if false; true; then bash tools/build.sh --stage native; fi",
    "echo x | exit 0\nexit 0\nbash tools/build.sh --stage native",
    # Provably dead or live, it is not a top-level unconditional command: never dropped, never exact.
    "false && bash tools/build.sh --stage native",
    "true || bash tools/build.sh --stage native",
    ": || bash tools/build.sh --stage native",
    "false || bash tools/build.sh --stage native",
    "true && bash tools/build.sh --stage native",
    "bash tools/build.sh --stage native && echo done",
    "bash tools/build.sh --stage native || exit 1",
    "echo a && bash tools/build.sh --stage native",
    "false && echo a; echo b && bash tools/build.sh --stage native",
    "exit 0\nbash tools/build.sh --stage native",
    "echo start\nexit 1\nbash tools/build.sh --stage native",
    "exit 0; bash tools/build.sh --stage native",
    "if false; then bash tools/build.sh --stage native; fi",
    "if true; then bash tools/build.sh --stage native; fi",
    "if false\nthen\n  bash tools/build.sh --stage native\nfi",
    "if false; then\n  if x; then echo a; else echo b; fi\n  bash tools/build.sh --stage native\nfi",
    "if false; then echo no; else bash tools/build.sh --stage native; fi",
    "if false; then echo no; elif true; then bash tools/build.sh --stage native; fi",
    "if bash tools/build.sh --stage native; then echo ok; fi",
    "if x; then echo a; fi\nexit 0\nbash tools/build.sh --stage native",
    "for i in 1; do bash tools/build.sh --stage native; done",
    "while bash tools/build.sh --stage native; do break; done",
    "case x in a) bash tools/build.sh --stage native ;; esac",
    "f() { bash tools/build.sh --stage native; }\nf",
    "function f { bash tools/build.sh --stage native; }\nf",
    "(bash tools/build.sh --stage native)",
    "(bash tools/build.sh --stage native) 2>&1",
    "echo $(bash tools/build.sh --stage native)",
    "{ bash tools/build.sh --stage native; } && echo ok",
    "test -f x && { bash tools/build.sh --stage native; }",
    "test -f x || { bash tools/build.sh --stage native; }",
    "test -f x && { case x in a) echo a ;; esac; bash tools/build.sh --stage native; }",  # a case pattern's ) does not close the group
]


@pytest.mark.parametrize("command", EXACT)
def test_a_top_level_unconditional_command_is_an_exact_call(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [".github/workflows/ci.yml:build"] and gate["may_call"] == [], command
    assert parity.calls_in(command) == [("tools/build.sh", ("--stage", "native"), True)] or parity.calls_in(command)[-1][2] is True


@pytest.mark.parametrize("command", MAY)
def test_anything_conditional_chained_or_after_an_exit_is_may_call_and_never_dropped(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build"], command
    calls = parity.calls_in(command)
    assert [(script, exact) for script, _args, exact in calls] == [("tools/build.sh", False)], command


def test_nothing_is_dropped_by_shell_reasoning():
    # Every shape that bash can run is reported; the verdict is only how much it proves.
    for command in MAY + EXACT:
        assert any(script == "tools/build.sh" for script, _args, _exact in parity.calls_in(command)), command


def test_scripts_and_heredoc_bodies_are_never_exact(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/d.sh")})
    (root / "tools/d.sh").write_text("exit 0\nbash tools/build.sh --stage native\n")
    gate = parity.check(root, inventory(**NATIVE))["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build via tools/d.sh"]


@pytest.mark.parametrize(
    "command",
    [
        'echo "a <<EOF"\nbash tools/build.sh --stage native\nEOF',
        "echo 'a <<EOF'\nbash tools/build.sh --stage native\nEOF",
        "echo $((1<<EOF))\nbash tools/build.sh --stage native\nEOF",
        "(( x = 1<<EOF ))\nbash tools/build.sh --stage native\nEOF",
        "cat <<<EOF\nbash tools/build.sh --stage native\nEOF",
        "# cat <<EOF\nbash tools/build.sh --stage native\nEOF",
        "echo a\\<<EOF\nbash tools/build.sh --stage native",
    ],
)
def test_a_heredoc_opens_only_outside_quotes_comments_and_arithmetic(tmp_path, command):
    assert calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"], command


@pytest.mark.parametrize(
    "command",
    [
        "cat <<EOF\nbash tools/build.sh --stage native\nEOF",
        'echo "x" <<EOF\nbash tools/build.sh --stage native\nEOF',
        "cat <<'EOF'\nbash tools/build.sh --stage native\nEOF",
        'cat <<"EOF" > f\nbash tools/build.sh --stage native\nEOF',
        "cat <<-EOF\n\tbash tools/build.sh --stage native\n\tEOF",
        "echo $((1<<2)) && cat <<EOF\nbash tools/build.sh --stage native\nEOF",
    ],
)
def test_a_real_heredoc_body_is_still_skipped(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [], command


def test_find_heredoc_reports_where_the_delimiter_and_tab_stripping_are():
    assert parity._find_heredoc("cat <<EOF") == (4, False, "EOF")
    assert parity._find_heredoc('cat <<<"x"; cat <<EOF') == (16, False, "EOF")  # a here-string does not hide a later heredoc
    assert parity._find_heredoc("cat <<-'X Y'") == (4, True, "X Y")
    assert parity._find_heredoc('cat <<  "EOF" | sh') == (4, False, "EOF")
    for line in ('echo "<<EOF"', "echo <<<EOF", "cat <<'unterminated", "x=$((1<<3))", "# <<EOF", "(( 1<<EOF ))", "echo $((1<<2"):
        assert parity._find_heredoc(line) is None, line
    assert parity.split_heredocs("sh <<E\nbash tools/a.sh\nE\nz") == ("sh \nz", ["bash tools/a.sh"])
    assert parity.split_heredocs("cat <<E\nbody\nE") == ("cat ", [])


# ------------------------------------------------- review round 7: matrix values and platforms

STAGES = ("native", "core", "desktop", "service")


def stage_gates(**platforms):
    return {
        "gates": {
            f"{stage}-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--platform", "{platform}", "--stage", stage], "platforms": list(platforms.get(stage, ("linux", "macos")))}
            for stage in STAGES
        }
    }


MACOS_JOB = """  macos-checks:
    runs-on: macos-15
    strategy:
      fail-fast: false
      matrix:
        stage: [{stages}]{extra}
    env:
      JOB_STAGE: ${{{{ matrix.stage }}}}
    steps:
      - name: contracts
        if: matrix.stage == 'contracts'
        run: python tools/check_dart_bindings.py
      - name: stage
        if: matrix.stage != 'contracts'
        env:
          MACOS_CHECK_STAGE: ${{{{ matrix.stage }}}}
        run: |
          set -o pipefail
          {{
            if [[ "$MACOS_CHECK_STAGE" != native ]]; then
              tools/build.sh --platform macos --stage native --build-only
            fi
            tools/build.sh --platform macos --stage "$MACOS_CHECK_STAGE"
          }} 2>&1 | tee "log-$MACOS_CHECK_STAGE.txt"
"""
ARCH_JOB = """  arch:
    runs-on: ubuntu-24.04
    steps:
      - run: |
          .venv/bin/python tools/run_ci_user.py -- \\
            bash tools/build.sh --platform linux -G Ninja
"""


def stage_tree(tmp_path, *, stages="contracts, native, core, desktop, service", extra="", arch=True):
    jobs = MACOS_JOB.format(stages=stages, extra=extra) + (ARCH_JOB if arch else "")
    return tree(tmp_path, {"ci.yml": "on: push\njobs:\n" + jobs}, scripts=("tools/build.sh", "tools/check_dart_bindings.py", "tools/run_ci_user.py"))


def stage_report(tmp_path, **options):
    return parity.check(stage_tree(tmp_path, **options), stage_gates())


def test_a_literal_matrix_makes_the_variable_call_exact_once_per_listed_stage(tmp_path):
    report = stage_report(tmp_path)
    assert report["problems"] == [] and report["wiring_unverified"] == []
    for stage in STAGES:
        gate = report["gates"][f"{stage}-stage"]
        assert sorted(gate["verified_platforms"]) == ["linux", "macos"] and gate["may_call"] == []
        assert gate["called_by"] == [".github/workflows/ci.yml:arch", ".github/workflows/ci.yml:macos-checks"]


def test_dropping_core_from_the_macos_matrix_fails_the_guard_even_with_the_linux_build(tmp_path):
    report = stage_report(tmp_path, stages="contracts, native, desktop, service")
    assert report["problems"] == ["gate core-stage: no workflow step calls `tools/build.sh --platform {platform} --stage core` for macos; wire it or declare local_only with a reason"]
    assert report["gates"]["core-stage"]["verified_platforms"] == ["linux"]
    assert sorted(report["gates"]["native-stage"]["verified_platforms"]) == ["linux", "macos"]


def test_deleting_the_linux_build_step_does_not_mask_or_get_masked_by_macos(tmp_path):
    only_macos = stage_report(tmp_path / "a", arch=False)
    assert sorted(problem.split("`")[0] for problem in only_macos["problems"]) == sorted(f"gate {stage}-stage: no workflow step calls " for stage in STAGES)
    assert all(problem.endswith("for linux; wire it or declare local_only with a reason") for problem in only_macos["problems"])
    neither = stage_report(tmp_path / "b", arch=False, stages="contracts, native, desktop, service")
    core = [problem for problem in neither["problems"] if problem.startswith("gate core-stage")]
    assert len(core) == 1 and "for linux, macos;" in core[0]


def test_a_matrix_an_include_or_exclude_touches_is_not_resolved(tmp_path):
    include = stage_report(tmp_path / "i", extra="\n        include:\n          - stage: extra")
    exclude = stage_report(tmp_path / "e", extra="\n        exclude:\n          - stage: core")
    for report in (include, exclude):
        gate = report["gates"]["core-stage"]
        assert gate["verified_platforms"] == ["linux"] and gate["wiring_unverified"] is True
        assert gate["may_call"] == [".github/workflows/ci.yml:macos-checks"]
        assert any(problem.startswith("gate core-stage: no step calls it as a top-level command on macos") for problem in report["problems"])
    unreadable = stage_report(tmp_path / "x", extra="\n        include: ${{ fromJson(needs.plan.outputs.extra) }}")
    assert unreadable["gates"]["core-stage"]["verified_platforms"] == ["linux"]
    assert unreadable["gates"]["core-stage"]["may_call"] == [".github/workflows/ci.yml:macos-checks"]
    untouched = stage_report(tmp_path / "u", extra="\n        include:\n          - os: macos-15\n            flavor: debug")
    assert untouched["problems"] == []  # an include that adds other keys leaves the stage list alone


@pytest.mark.parametrize(
    "matrix",
    ["stage: ${{ fromJson(needs.plan.outputs.stages) }}", "stage: core", "stage: []", "stage: [[core]]", "stage: [{a: b}]", "other: [core]"],
)
def test_a_matrix_that_is_not_a_literal_scalar_list_is_not_resolved(tmp_path, matrix):
    workflow_text = MACOS_JOB.format(stages="x", extra="").replace("stage: [x]", matrix)
    root = tree(tmp_path, {"ci.yml": "on: push\njobs:\n" + workflow_text}, scripts=("tools/build.sh", "tools/check_dart_bindings.py"))
    gate = parity.check(root, stage_gates())["gates"]["core-stage"]
    assert gate["called_by"] == [] and gate["verified_platforms"] == []
    assert gate["may_call"] == [".github/workflows/ci.yml:macos-checks"]  # the variable is still evidence, never silently absent


def test_expansions_bind_env_variables_and_expressions_and_nothing_else():
    job = {"strategy": {"matrix": {"stage": ["a", "b"], "os": ["x", "y"]}}, "env": {"JOB_STAGE": "${{ matrix.stage }}"}}
    step = {"env": {"S": "${{ matrix.stage }}", "NOT": "prefix-${{ matrix.stage }}", "OS": "${{ matrix.os }}"}}
    text = 'run "$S" "${S}" "$S2" "$NOT" "$JOB_STAGE" ${{ matrix.os }} "$OS"'
    variants = parity._expansions(step, job, text)
    assert len(variants) == 4  # stage x os
    assert variants[0] == ('run "a" "a" "$S2" "$NOT" "a" x "x"', {"os": "x", "stage": "a"})
    assert {variant[0].split()[1] for variant in variants} == {'"a"', '"b"'}
    assert parity._expansions({}, job, "no variables here") == [("no variables here", {})]
    assert parity._expansions({}, {}, "$S") == [("$S", {})]


def test_a_job_level_variable_and_an_inline_expression_are_resolved_too(tmp_path):
    text = (
        "on: push\njobs:\n  m:\n    runs-on: macos-15\n    strategy:\n      matrix:\n        stage: [core]\n    env:\n      STAGE: ${{ matrix.stage }}\n"
        "    steps:\n      - run: tools/build.sh --platform macos --stage \"$STAGE\"\n      - run: tools/build.sh --platform macos --stage ${{ matrix.stage }}\n"
    )
    root = tree(tmp_path, {"ci.yml": text}, scripts=("tools/build.sh",))
    gate = parity.check(root, stage_gates())["gates"]["core-stage"]
    assert gate["called_by"] == [".github/workflows/ci.yml:m"] and gate["verified_platforms"] == ["macos"]


def test_a_stage_less_build_is_the_default_all_and_exact(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/build.sh --platform linux -G Ninja")})
    gate = parity.check(root, stage_gates())["gates"]["core-stage"]
    assert gate["called_by"] == [".github/workflows/ci.yml:build"] and gate["verified_platforms"] == ["linux"]
    plain = calling(tmp_path / "plain", "bash tools/build.sh", extra=NATIVE)["gates"]["native-stage"]
    assert plain["called_by"] == [".github/workflows/ci.yml:build"] and plain["may_call"] == []


@pytest.mark.parametrize(
    ("runs_on", "command", "verified", "may"),
    [
        ("ubuntu-24.04", "bash tools/build.sh --stage core", ["linux"], False),  # no --platform: the runner decides
        ("macos-15", "bash tools/build.sh --stage core", ["macos"], False),
        ("[self-hosted, macos]", "bash tools/build.sh --stage core", [], True),  # an unreadable runner proves nothing
        ("${{ inputs.runner }}", "bash tools/build.sh --stage core", [], True),
        ("ubuntu-24.04", 'bash tools/build.sh --platform "$P" --stage core', [], True),
        ("ubuntu-24.04", "bash tools/build.sh --platform windows --stage core", [], False),  # another platform: not this gate's
        ("ubuntu-24.04", "bash tools/build.sh --platform macos --stage core", [], True),  # the flag and the runner disagree: evidence for neither
        ("macos-15", "bash tools/build.sh --platform linux --stage core", [], True),
        ("macos-15", "bash tools/build.sh --platform macos --stage core", ["macos"], False),
        ("[self-hosted, macos]", "bash tools/build.sh --platform linux --stage core", ["linux"], False),  # an unreadable runner cannot disagree
    ],
)
def test_the_platform_of_a_call_is_its_flag_else_the_runner(tmp_path, runs_on, command, verified, may):
    text = f"on: push\njobs:\n  j:\n    runs-on: {runs_on}\n    steps:\n      - run: {json.dumps(command)}\n"
    root = tree(tmp_path, {"ci.yml": text}, scripts=("tools/build.sh",))
    gate = parity.check(root, stage_gates())["gates"]["core-stage"]
    assert sorted(gate["verified_platforms"]) == verified
    assert bool(gate["may_call"]) is may


def test_only_the_gates_that_pass_platform_get_a_per_platform_requirement(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("python tools/check_dart_bindings.py")})
    report = parity.check(root, {"gates": {"bindings-check": {"kind": "command", "argv": ["{python}", "tools/check_dart_bindings.py"], "platforms": ["linux", "macos"]}}})
    assert report["problems"] == [] and report["gates"]["bindings-check"]["platforms"] == []
    assert parity._wants_platform(["bash", "x", "--platform", "{platform}"]) and not parity._wants_platform(["bash", "--platform", "linux"])
    assert not parity._wants_platform(["--platform"])


# ------------------------------------------------- review round 8: heads, budgets, heredoc words, punctuation, hostile files

@pytest.mark.parametrize(
    "command",
    [
        "echo use bash tools/build.sh --stage native",
        "grep -q bash tools/build.sh --stage native",
        "git commit -m x bash tools/build.sh --stage native",
        "command -v tools/build.sh --stage native",
        "command -V bash tools/build.sh --stage native",
        "type tools/build.sh",
        "which bash tools/build.sh",
        "printf '%s' bash tools/build.sh",
        "xargs bash tools/build.sh --stage native",
        "ls -l bash tools/build.sh",
        "FOO=1 echo bash tools/build.sh --stage native",
        "if echo bash tools/build.sh --stage native; then true; fi",
    ],
)
def test_a_script_after_a_word_that_does_not_execute_its_arguments_is_not_a_call(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [], command
    assert parity.calls_in(command) == []


@pytest.mark.parametrize(
    "command",
    [
        'tools/run_ci_user.py --workspace "$W" -- bash tools/build.sh --stage native',
        ".venv/bin/python tools/run_ci_user.py --workspace x -- xvfb-run -a bash tools/build.sh --stage native",
        "docker run --rm -v a:b image bash tools/build.sh --stage native",
        "podman run image python3 tools/build.sh --stage native",
        "timeout 5 env FOO=1 bash tools/build.sh --stage native",
        "sudo -E bash tools/build.sh --stage native",
    ],
)
def test_a_chain_that_starts_with_an_executor_still_reaches_the_script(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert [*gate["called_by"], *gate["may_call"]] == [".github/workflows/ci.yml:build"], command


def test_a_call_with_more_arguments_than_the_limit_keeps_only_the_limit_and_forgets_the_discriminators():
    command = "bash tools/build.sh " + "x " * 500 + "--stage core"
    [(script, args, exact)] = parity.calls_in(command)
    assert script == "tools/build.sh" and exact and len(args) == parity.ARGUMENT_LIMIT + len(parity._TRUNCATED)
    assert args[-len(parity._TRUNCATED):] == parity._TRUNCATED and "--build-only" in parity._TRUNCATED
    # An unknown stage is not evidence for any one gate: a truncated call might be a build-only one, so it satisfies nothing.
    gate = {"gates": {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"]}}}
    assert parity.satisfies(parity.Call("w", "s", "tools/build.sh", args, None, True), "tools/build.sh", gate["gates"]["native-stage"]["argv"]) is None
    short = parity.calls_in("bash tools/build.sh --stage native")[0][1]
    assert short == ("--stage", "native")


def test_the_call_limit_stops_a_text_early_instead_of_after_the_fact():
    text = "env tools/a.sh; " * 8000
    found = parity.calls_in(text, limit=10)
    assert len(found) == 11  # limit + 1: enough for the caller to see that it was exceeded
    assert len(parity.calls_in("env tools/a.sh; " * 5)) == 5
    assert all(len(args) <= parity.ARGUMENT_LIMIT + len(parity._TRUNCATED) for _script, args, _exact in parity.calls_in(text, limit=100))


def test_a_script_reached_by_many_steps_is_lexed_once(tmp_path, monkeypatch):
    steps = "\n".join("      - run: bash tools/big.sh" for _ in range(20))
    text = f"on: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n{steps}\n"
    root = tree(tmp_path, {"ci.yml": text})
    (root / "tools/big.sh").write_text("bash tools/build.sh --stage native\n" * 50)
    lexed = []
    real = parity._lex_script
    monkeypatch.setattr(parity, "_lex_script", lambda path, script: lexed.append(script) or real(path, script))
    report = parity.check(root, inventory(**NATIVE))
    assert lexed.count("tools/big.sh") == 1 and len(lexed) == len(set(lexed))
    assert report["gates"]["native-stage"]["may_call"] == [".github/workflows/ci.yml:j via tools/big.sh"]


def test_the_total_budget_is_a_fail_closed_problem(tmp_path, monkeypatch):
    steps = "\n".join(f"      - run: bash tools/s{i}.sh" for i in range(5))
    root = tree(tmp_path, {"ci.yml": f"on: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n{steps}\n"})
    for i in range(5):
        (root / f"tools/s{i}.sh").write_text("echo hello\n" * 100)
    monkeypatch.setattr(parity, "MAX_TOTAL_BYTES", 1500)
    problems = parity.check(root, inventory(**NATIVE))["problems"]
    assert any("analysis budget of 1500 bytes was exhausted" in problem and "wiring unverified" in problem for problem in problems)
    monkeypatch.setattr(parity, "MAX_TOTAL_BYTES", 10)
    assert any("exhausted before" in problem for problem in parity.check(root, inventory(**NATIVE))["problems"])
    monkeypatch.setattr(parity, "MAX_TOTAL_BYTES", 4 * 1024 * 1024)
    assert not [problem for problem in parity.check(root, inventory(**NATIVE))["problems"] if "budget" in problem]


def test_a_script_with_too_many_calls_is_a_problem_once(tmp_path, monkeypatch):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/big.sh", "bash tools/big.sh")})
    (root / "tools/big.sh").write_text("env tools/a.sh\n" * 20)
    monkeypatch.setattr(parity, "MAX_CALLS_PER_STEP", 5)
    problems = [problem for problem in parity.check(root, inventory(**NATIVE))["problems"] if "tools/big.sh" in problem]
    assert len(problems) == 1 and "more than 5 calls" in problems[0]


@pytest.mark.parametrize(
    ("command", "expected"),
    [
        ("cat <<\\EOF\nbash tools/build.sh --stage native\nEOF\nbash tools/build.sh --stage native", [True]),
        ("cat <<A <<B\nbash tools/build.sh --stage native\nA\nbash tools/build.sh --stage native\nB\nbash tools/build.sh --stage native", [True]),
        ("cat <<END-OF\nbash tools/build.sh --stage native\nEND-OF\nbash tools/build.sh --stage native", [True]),
        ("cat <<-X.Y\n\tbash tools/build.sh --stage native\n\tX.Y\nbash tools/build.sh --stage native", [True]),
        ("cat <<a\\b\nbash tools/build.sh --stage native\nab\nbash tools/build.sh --stage native", [True]),
        ("cat <<'A' <<\"B\"\nbash tools/build.sh --stage native\nA\nbash tools/build.sh --stage native\nB", []),
    ],
)
def test_heredoc_words_are_parsed_as_the_shell_reads_them(command, expected):
    main, bodies = parity.split_heredocs(command)
    assert bodies == []
    assert [exact for _script, _args, exact in parity.calls_in(main)] == expected, command


@pytest.mark.parametrize(
    "command",
    [
        'cat <<E"O"F\nbash tools/build.sh --stage native\nEOF',
        "cat <<EOF\nbash tools/build.sh --stage native",
        "cat <<A <<B\nbash tools/build.sh --stage native\nA\nbash tools/build.sh --stage native",
        "bash <<EOF\nbash tools/build.sh --stage native\nEOF",
        "cat <<E'O'F\nbash tools/build.sh --stage native\nEOF",
    ],
)
def test_a_heredoc_that_may_be_something_else_is_read_as_may_call_never_dropped(tmp_path, command):
    main, bodies = parity.split_heredocs(command)
    assert bodies and any("tools/build.sh" in body for body in bodies)
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build via <heredoc>"], command


def test_find_heredocs_returns_every_document_on_a_line_with_its_delimiter_form():
    assert parity._find_heredocs("cat <<A <<-'B C' <<\\D") == [(4, False, "A", False, 7), (8, True, "B C", False, 16), (17, False, "D", False, 21)]
    assert parity._find_heredocs('cat <<E"O"F')[0][2:] == ("EOF", True, 11)
    assert parity._find_heredocs("cat <<END-OF")[0][2] == "END-OF"
    assert parity._find_heredocs("cat <<'x") == [] and parity._find_heredocs("cat << ") == []
    assert parity._find_heredoc("cat <<EOF") == (4, False, "EOF")


@pytest.mark.parametrize(
    ("command", "exact"),
    [
        ("(true)&&tools/build.sh --stage native", False),
        ("(true) && tools/build.sh --stage native", False),
        ("true;(tools/build.sh --stage native)", False),
        ("{ true; }&&tools/build.sh --stage native", False),
        ("true||tools/build.sh --stage native", False),
        ("true;tools/build.sh --stage native", True),
        ("true&tools/build.sh --stage native", True),
        ("tools/build.sh --stage native 2>&1|tee log", True),
        ("tools/build.sh --stage native&>log", True),
        ("true|tools/build.sh --stage native", True),
    ],
)
def test_fused_punctuation_is_split_before_the_call_is_classified(command, exact):
    assert [(script, tier) for script, _args, tier in parity.calls_in(command)] == [("tools/build.sh", exact)], command


def test_pieces_split_operators_but_keep_redirects_whole():
    assert parity._pieces(")&&") == [")", "&&"]
    assert parity._pieces("&&&") == ["&&", "&"]
    assert parity._pieces(">&") == [">&"] and parity._pieces("2") == ["2"] and parity._pieces("&>") == ["&>"]
    assert parity._pieces(";\n") == [";", "\n"] and parity._pieces("word") == ["word"]


def test_hostile_workflow_files_are_problem_lines_never_tracebacks(tmp_path):
    root = tree(tmp_path, {"ok.yml": workflow("bash tools/build.sh --stage native")})
    workflows = root / ".github/workflows"
    (workflows / "dangling.yml").symlink_to(workflows / "nowhere.yml")
    (workflows / "binary.yml").write_bytes(b"\xff\xfe\x00\x01 not text \x80")
    (workflows / "unhashable.yml").write_text("on: push\n? [a, b]\n: 1\n? [a, b]\n: 2\njobs: {}\n")
    (workflows / "complex.yml").write_text("on: push\n? [a, b]\n: 1\njobs: {}\n")
    problems = parity.check(root, inventory(**NATIVE))["problems"]
    joined = "\n".join(problems)
    assert "dangling.yml: cannot be read (FileNotFoundError)" in joined
    assert "binary.yml: cannot be read (UnicodeDecodeError)" in joined
    assert "unhashable.yml: duplicate keys" in joined
    assert "complex.yml" in joined and "Traceback" not in joined


def test_an_unreadable_workflow_directory_entry_is_reported(tmp_path):
    root = tree(tmp_path, {"ok.yml": workflow("bash tools/build.sh --stage native"), "locked.yml": "on: push\njobs: {}\n"})
    locked = root / ".github/workflows/locked.yml"
    locked.chmod(0)
    try:
        problems = parity.check(root, inventory(**NATIVE))["problems"]
    finally:
        locked.chmod(0o644)
    if os.geteuid() != 0:  # root reads a mode-0 file; there is nothing to report then
        assert any("locked.yml: cannot be read (PermissionError)" in problem for problem in problems)


# ----------------------------------- acknowledgements rest on named jobs, and a gate that states a platform is compared

def acknowledged_gate(reason="reviewed", relies_on=(".github/workflows/ci.yml:build",)):
    gate = {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"], "wiring_unverified_reason": reason}
    if relies_on is not None:
        gate["wiring_unverified_relies_on"] = list(relies_on) if isinstance(relies_on, tuple) else relies_on
    return {"gates": {"native-stage": gate}}


def test_an_acknowledgement_must_name_a_job_that_still_reaches_the_gate(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow('bash tools/build.sh --stage "$S"')})
    assert parity.check(root, acknowledged_gate())["problems"] == []
    gone = parity.check(root, acknowledged_gate(relies_on=[".github/workflows/ci.yml:vanished"]))["problems"]
    assert gone == ["gate native-stage: wiring_unverified_reason relies on .github/workflows/ci.yml:vanished, which no longer reaches it; revisit the acknowledgement"]
    for relies_on in (None, [], "ci.yml:build", [3]):
        problems = parity.check(root, acknowledged_gate(relies_on=relies_on))["problems"]
        assert problems == ["gate native-stage: wiring_unverified_reason needs wiring_unverified_relies_on, the workflow:job entries it rests on"], relies_on
    assert parity.check(root, acknowledged_gate())["gates"]["native-stage"]["reached_by"] == [".github/workflows/ci.yml:build"]


def test_deleting_the_job_an_acknowledgement_rests_on_fails_the_guard(tmp_path):
    with_job = tree(tmp_path / "a", {"ci.yml": workflow('bash tools/build.sh --stage "$S"')})
    other = tree(tmp_path / "b", {"ci.yml": workflow('bash tools/build.sh --stage "$S"', job="renamed")})
    assert parity.check(with_job, acknowledged_gate())["problems"] == []
    assert any("relies on .github/workflows/ci.yml:build, which no longer reaches it" in problem for problem in parity.check(other, acknowledged_gate())["problems"])


def test_the_real_acknowledgement_rests_on_jobs_that_exist():
    report = parity.check(ROOT)
    gate = report["gates"]["integration-virtual-audio"]
    inventory_gate = parity.boundary_inventory.load(ROOT)["gates"]["integration-virtual-audio"]
    assert inventory_gate["wiring_unverified_relies_on"] and set(inventory_gate["wiring_unverified_relies_on"]) <= set(gate["reached_by"])
    assert report["problems"] == []


@pytest.mark.parametrize(
    ("runs_on", "command", "kind"),
    [
        ("ubuntu-24.04", "bash tools/build.sh --platform linux --stage native", "called"),
        ("macos-15", "bash tools/build.sh --platform linux --stage native", "may"),  # the flag and the runner disagree
        ("ubuntu-24.04", "bash tools/build.sh --platform macos --stage native", "none"),
        ("ubuntu-24.04", "bash tools/build.sh --stage native", "called"),  # no flag: the runner decides
        ("macos-15", "bash tools/build.sh --stage native", "none"),
        ("[self-hosted]", "bash tools/build.sh --stage native", "may"),
        ("ubuntu-24.04", 'bash tools/build.sh --platform "$P" --stage native', "may"),
        ("ubuntu-24.04", "bash tools/build.sh --platform=linux --stage native", "called"),
    ],
)
def test_a_gate_that_states_its_platform_is_satisfied_only_by_a_call_for_it(tmp_path, runs_on, command, kind):
    text = f"on: push\njobs:\n  j:\n    runs-on: {runs_on}\n    steps:\n      - run: {json.dumps(command)}\n"
    root = tree(tmp_path, {"ci.yml": text})
    gate = parity.check(root, {"gates": {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--platform", "linux", "--stage", "native"], "platforms": ["linux"], "local_only": "x"}}})["gates"]["native-stage"]
    assert (bool(gate["called_by"]), bool(gate["may_call"])) == {"called": (True, False), "none": (False, False), "may": (False, True)}[kind]


def test_many_calls_in_one_segment_do_not_copy_the_rest_of_the_segment_each_time():
    import tracemalloc

    text = "env tools/a.sh; " * 6000
    tracemalloc.start()
    try:
        found = parity.calls_in(text)
        peak = tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()
    assert len(found) == 6000
    assert peak < 80 * 1024 * 1024, peak  # quadratic copying of the tail takes over a gigabyte


# ------------------------------------------------- review round 9: separators across lines, nesting, chains, matrix size and conditions

@pytest.mark.parametrize(
    "command",
    [
        "false &&\ntools/build.sh --stage native",
        '[ -n "$X" ] &&\n  tools/build.sh --stage native',
        "false ||\ntools/build.sh --stage native",
        "true &&\n\n  tools/build.sh --stage native",
        "tools/build.sh --stage native &&\necho done",
        "tools/build.sh --stage native ||\nexit 1",
        "{ true; } &&\ntools/build.sh --stage native",
        "test -f x &&\n{ tools/build.sh --stage native; }",
        "test -f x ||\n{\n  tools/build.sh --stage native\n}",
        "{ tools/build.sh --stage native; echo x; } && echo y",  # the group is an and-or operand: nothing inside is unconditional
        "{ echo x; tools/build.sh --stage native; } ||\necho y",
        # nesting the old counter lost: the first fi closes the inner if, the call is still inside the outer one
        "if a; then echo; else if b; then echo; fi; tools/build.sh --stage native; fi",
        "if a; then if b; then echo; fi; tools/build.sh --stage native; fi",
        "while a; do if b; then echo; fi; tools/build.sh --stage native; done",
        "if a; then echo; else\nif b; then echo; fi\ntools/build.sh --stage native\nfi",
        "if x; then echo; fi\n! if y; then echo; fi\nfi\ntools/build.sh --stage native",  # an unmatched fi makes everything after it may_call
        "fi\ntools/build.sh --stage native",
        "done\ntools/build.sh --stage native",
        "esac\ntools/build.sh --stage native",
        "if x; then echo; fi\nfi\nfi\ntools/build.sh --stage native",
        "exec tools/a.sh; tools/build.sh --stage native",
        "exec true\ntools/build.sh --stage native",
    ],
)
def test_a_call_that_is_not_provably_top_level_is_may_call_not_exact(tmp_path, command):
    calls = [(script, exact) for script, _args, exact in parity.calls_in(command) if script == "tools/build.sh"]
    assert calls == [("tools/build.sh", False)], command


@pytest.mark.parametrize(
    "command",
    [
        "true;\ntools/build.sh --stage native",
        "true\n\ntools/build.sh --stage native",
        "if a; then echo; else if b; then echo; fi; fi\ntools/build.sh --stage native",
        "if a; then if b; then echo; fi; fi\ntools/build.sh --stage native",
        "for i in 1; do if b; then echo; fi; done\ntools/build.sh --stage native",
        "! if y; then echo; fi\ntools/build.sh --stage native",
        "if a; then echo; fi; tools/build.sh --stage native",
        "while a; do echo; done; tools/build.sh --stage native",
    ],
)
def test_balanced_nesting_returns_to_the_top_level(command):
    assert [exact for script, _args, exact in parity.calls_in(command) if script == "tools/build.sh"] == [True], command


@pytest.mark.parametrize(
    ("command", "tier"),
    [
        ("env echo bash tools/build.sh --stage native", "may"),
        ("sudo grep bash tools/build.sh --stage native", "may"),
        ("docker run --rm img echo bash tools/build.sh --stage native", "may"),
        ("docker run --rm img python3 tools/build.sh --stage native", "may"),
        ("timeout -s KILL 5 bash tools/build.sh --stage native", "may"),
        ("env FOO=1 mytool bash tools/build.sh --stage native", "may"),
        ("env bash ./run.sh tools/build.sh --stage native", "may"),
        ("bash ./run.sh tools/build.sh --stage native", "none"),
        ("nice -n 5 bash tools/build.sh --stage native", "exact"),
        ("timeout 5 env FOO=1 bash tools/build.sh --stage native", "exact"),
        ("xvfb-run -a dbus-run-session -- bash tools/build.sh --stage native", "exact"),
        ("env tools/build.sh --stage native", "exact"),
        ("exec tools/build.sh --stage native", "exact"),
        ("sudo -E env bash tools/build.sh --stage native", "exact"),
        ('tools/run_ci_user.py --workspace "$W" -- xvfb-run -a bash tools/build.sh --stage native', "exact"),
        (".venv/bin/python tools/run_ci_user.py --workspace w -- env bash tools/build.sh --stage native", "exact"),
        ("tools/run_ci_user.py tools/build.sh --stage native", "none"),  # an argument of a script, not a command
        ("python tools/run_ci_user.py tools/build.sh --stage native", "none"),
    ],
)
def test_a_launcher_chain_is_exact_only_when_every_word_in_it_is_a_launcher(command, tier):
    calls = [exact for script, _args, exact in parity.calls_in(command) if script == "tools/build.sh"]
    assert calls == {"exact": [True], "may": [False], "none": []}[tier], command


def test_a_token_far_into_one_command_is_may_call_without_a_quadratic_walk(monkeypatch):
    walked = []
    real = parity._chain
    monkeypatch.setattr(parity, "_chain", lambda segment, index: walked.append(index) or real(segment, index))
    command = "bash " + "x " * 600 + "tools/build.sh --stage native"
    assert [(script, exact) for script, _args, exact in parity.calls_in(command)] == [("tools/build.sh", False)]
    assert walked == []  # beyond CHAIN_LIMIT no walk happens at all
    assert [exact for _script, _args, exact in parity.calls_in("bash tools/build.sh --stage native")] == [True]


def test_a_truncated_call_never_satisfies_a_gate_that_does_not_ask_for_build_only(tmp_path):
    args = parity.calls_in("bash tools/build.sh " + "x " * 100)[0][1]
    call = parity.Call("w", "s", "tools/build.sh", args, None, True)
    assert parity.satisfies(call, "tools/build.sh", ["bash", "tools/build.sh", "--stage", "native"]) is None
    assert parity.satisfies(call, "tools/build.sh", ["bash", "tools/build.sh", "--stage", "native", "--build-only"]) in (None, "ambiguous")


def test_heredoc_operator_lines_keep_the_rest_of_the_line_as_a_command():
    assert [(script, exact) for script, _args, exact in parity.calls_in(parity.split_heredocs("cat <<EOF | tools/build.sh --stage native\nbody\nEOF")[0])] == [("tools/build.sh", True)]
    assert [(script, exact) for script, _args, exact in parity.calls_in(parity.split_heredocs("cat <<EOF && tools/build.sh --stage native\nbody\nEOF")[0])] == [("tools/build.sh", False)]
    assert parity.split_heredocs("cat <<A <<B | cat\na\nA\nb\nB")[0] == "cat   | cat"
    main, bodies = parity.split_heredocs("bash <<EOF | tee log\ntools/build.sh --stage native\nEOF")
    assert main == "bash  | tee log" and bodies == ["tools/build.sh --stage native"]


# --- the matrix: size first, conditions read

def matrix_workflow(keys, values, extra_step=""):
    matrix = "\n".join(f"        k{i}: [{', '.join(str(n) for n in range(values))}]" for i in range(keys))
    uses = " ".join(f"${{{{ matrix.k{i} }}}}" for i in range(keys))
    return (
        f"on: push\njobs:\n  m:\n    runs-on: macos-15\n    strategy:\n      matrix:\n{matrix}\n    steps:\n"
        f"      - run: tools/build.sh --platform macos --stage {uses}\n{extra_step}"
    )


def test_a_matrix_too_large_to_expand_is_a_problem_and_never_materialized(tmp_path, monkeypatch):
    def refuse(*arguments):
        raise AssertionError("the product was built")

    monkeypatch.setattr(parity.itertools, "product", refuse)
    root = tree(tmp_path, {"ci.yml": matrix_workflow(6, 12)}, scripts=("tools/build.sh",))
    report = parity.check(root, stage_gates())
    assert any("a matrix of 2985984 combinations is not expanded" in problem for problem in report["problems"])
    gate = report["gates"]["core-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:m"]  # still evidence, never exact


def test_a_matrix_over_the_per_step_cap_but_within_the_run_budget_is_refused_too(tmp_path):
    report = parity.check(tree(tmp_path, {"ci.yml": matrix_workflow(3, 5)}, scripts=("tools/build.sh",)), stage_gates())
    assert any("a matrix of 125 combinations is not expanded" in problem for problem in report["problems"])
    within = parity.check(tree(tmp_path / "ok", {"ci.yml": matrix_workflow(2, 5)}, scripts=("tools/build.sh",)), stage_gates())
    assert not [problem for problem in within["problems"] if "is not expanded" in problem]


def test_the_run_wide_expansion_budget_stops_expansion_and_says_so(tmp_path, monkeypatch):
    monkeypatch.setattr(parity, "MAX_EXPANDED_RUNS", 20)
    steps = "".join("      - run: tools/build.sh --platform macos --stage ${{ matrix.k0 }}\n" for _ in range(6))
    text = "on: push\njobs:\n  m:\n    runs-on: macos-15\n    strategy:\n      matrix:\n        k0: [a, b, c, d, e, f, g, h]\n    steps:\n" + steps
    report = parity.check(tree(tmp_path, {"ci.yml": text}, scripts=("tools/build.sh",)), stage_gates())
    problems = [problem for problem in report["problems"] if "is not expanded" in problem]
    assert len(problems) == 4  # two steps of eight fit in twenty; the other four do not
    parsed = parity.Parsed()
    parity._expansions({}, {"strategy": {"matrix": {"k": ["a", "b"]}}}, "${{ matrix.k }}", parsed, "w")
    assert parsed.expanded == 2


@pytest.mark.parametrize(
    ("condition", "verdict"),
    [
        (None, True), (True, True), ("true", True), ("${{ true }}", True), ("github.event_name == 'push'", True),
        ("matrix.stage == 'core'", True), ("matrix.stage != 'core'", False), ("${{ matrix.stage == 'core' }}", True),
        ("matrix.stage == 'native'", False), ("matrix.stage != 'native'", True),
        ("matrix.stage == 'core' && github.ref == 'x'", None), ("matrix.stage in ('core')", None), ("matrix.other == 'x'", None),
        ("contains(matrix.stage, 'o')", None), ("matrix.stage == \"core\"", None),
    ],
)
def test_a_step_condition_on_the_matrix_is_read_against_the_expanded_value(condition, verdict):
    assert parity._condition(condition, {"stage": "core"}, {"stage": ["core", "native"]}) is verdict


def test_an_unbound_condition_runs_if_any_listed_value_satisfies_it():
    values = {"stage": ["a", "b"]}
    assert parity._condition("matrix.stage == 'a'", {}, values) is True
    assert parity._condition("matrix.stage != 'a'", {}, values) is True
    assert parity._condition("matrix.stage == 'z'", {}, values) is False
    assert parity._condition("matrix.stage != 'z'", {}, values) is True
    assert parity._condition("matrix.stage == 'a'", {}, {}) is None


def test_an_excluded_matrix_value_stops_verifying_its_stage_and_an_unreadable_condition_stops_proving_it(tmp_path):
    base = stage_report(tmp_path / "base")
    assert base["problems"] == [] and sorted(base["gates"]["service-stage"]["verified_platforms"]) == ["linux", "macos"]
    skipped = stage_tree(tmp_path / "skip").joinpath(".github/workflows/ci.yml")
    skipped.write_text(skipped.read_text().replace("if: matrix.stage != 'contracts'", "if: matrix.stage != 'service'"))
    report = parity.check(skipped.parents[2], stage_gates())
    assert report["gates"]["service-stage"]["verified_platforms"] == ["linux"]
    assert report["problems"] == ["gate service-stage: no workflow step calls `tools/build.sh --platform {platform} --stage service` for macos; wire it or declare local_only with a reason"]
    unreadable = stage_tree(tmp_path / "unreadable").joinpath(".github/workflows/ci.yml")
    unreadable.write_text(unreadable.read_text().replace("if: matrix.stage != 'contracts'", "if: matrix.stage != 'contracts' && always()"))
    gate = parity.check(unreadable.parents[2], stage_gates())["gates"]["core-stage"]
    assert gate["verified_platforms"] == ["linux"] and gate["may_call"] == [".github/workflows/ci.yml:macos-checks"]


# --- the runner and the flag must agree

def test_an_ubuntu_job_does_not_satisfy_the_macos_requirement(tmp_path):
    root = stage_tree(tmp_path)
    workflow_file = root / ".github/workflows/ci.yml"
    workflow_file.write_text(workflow_file.read_text().replace("runs-on: macos-15", "runs-on: ubuntu-24.04"))
    report = parity.check(root, stage_gates())
    for stage in STAGES:
        gate = report["gates"][f"{stage}-stage"]
        assert gate["verified_platforms"] == ["linux"], stage
        assert gate["may_call"] == [".github/workflows/ci.yml:macos-checks"], stage
    assert any(problem.startswith("gate core-stage: no step calls it as a top-level command on macos") for problem in report["problems"])


def test_a_macos_job_does_not_satisfy_the_linux_requirement(tmp_path):
    root = stage_tree(tmp_path)
    workflow_file = root / ".github/workflows/ci.yml"
    workflow_file.write_text(workflow_file.read_text().replace("runs-on: ubuntu-24.04", "runs-on: macos-15"))
    report = parity.check(root, stage_gates())
    for stage in STAGES:
        gate = report["gates"][f"{stage}-stage"]
        assert gate["verified_platforms"] == ["macos"], stage
        assert ".github/workflows/ci.yml:arch" in gate["may_call"], stage
    assert any("on linux" in problem for problem in report["problems"])


@pytest.mark.parametrize(
    ("flag", "runner", "expected"),
    [("macos", "macos", ("macos", False)), ("linux", "macos", ("linux", True)), ("macos", "linux", ("macos", True)), ("linux", None, ("linux", False)),
     (None, "macos", ("macos", False)), (None, None, (None, False)), ("windows", "linux", ("windows", False)), ("$P", "linux", (None, False))],
)
def test_call_platform_reports_the_platform_and_whether_flag_and_runner_disagree(flag, runner, expected):
    args = (("--platform", flag) if flag else ()) + ("--stage", "core")
    assert parity._call_platform(parity.Call("w", "s", "tools/build.sh", args, None, True, runner)) == expected


def test_a_gate_that_states_a_platform_is_not_satisfied_by_a_disagreeing_runner():
    gate = ["bash", "tools/build.sh", "--platform", "linux", "--stage", "native"]
    agree = parity.Call("w", "s", "tools/build.sh", ("--platform", "linux", "--stage", "native"), None, True, "linux")
    clash = parity.Call("w", "s", "tools/build.sh", ("--platform", "linux", "--stage", "native"), None, True, "macos")
    assert parity.satisfies(agree, "tools/build.sh", gate) == "exact" and parity.satisfies(clash, "tools/build.sh", gate) == "ambiguous"
