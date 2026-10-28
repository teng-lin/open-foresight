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
ACKNOWLEDGED = {"core-stage", "desktop-stage", "native-stage", "service-stage", "integration-virtual-audio"}


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
        "if true; then bash tools/build.sh --stage native; fi",
        "echo start && bash tools/build.sh --stage native",
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
    gates = {name: {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", name], "wiring_unverified_reason": "dispatcher"} for name in stages}
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
    gates = {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"], "wiring_unverified_reason": "via d.sh"}}
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
    assert problems == ["gate native-stage: only a script or a variable may call it (.github/workflows/ci.yml:build); call it directly or declare wiring_unverified_reason"]
    declared = {"gates": {"native-stage": {"kind": "command", "argv": ["bash", "tools/build.sh", "--stage", "native"], "wiring_unverified_reason": "reviewed"}}}
    assert parity.check(undeclared, declared)["problems"] == []
    direct = tree(tmp_path / "b", {"ci.yml": workflow("bash tools/build.sh --stage native")})
    assert parity.check(direct, declared)["problems"] == ["gate native-stage: declared wiring_unverified_reason but it now has direct evidence or none; remove the stale declaration"]
    for reason in ("", "  ", 7):
        blank = {"gates": {"native-stage": {**declared["gates"]["native-stage"], "wiring_unverified_reason": reason}}}
        assert "gate native-stage: wiring_unverified_reason needs a reason" in parity.check(undeclared, blank)["problems"]


def test_the_real_tree_acknowledges_exactly_the_unverified_gates_it_has():
    report = parity.check(ROOT)
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


# ------------------------------------------------- review round 6: heads, dead code, heredoc recognition, missing stage

@pytest.mark.parametrize(
    "command",
    ["bash tools/build.sh", "bash tools/build.sh --platform linux -G Ninja", "xvfb-run -a bash tools/build.sh --platform linux"],
)
def test_a_missing_stage_is_evidence_never_an_exact_call(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build"] and gate["wiring_unverified"] is True
    # Other discriminators never get that allowance: a missing --suite does not satisfy a suite gate.
    suite = {"gates": {"fast": {"kind": "command", "argv": ["{python}", "tools/integration_gates.py", "--suite", "fast"]}}}
    root = tree(tmp_path / "suite", {"ci.yml": workflow("python tools/integration_gates.py")}, scripts=("tools/integration_gates.py",))
    assert parity.check(root, suite)["gates"]["fast"]["may_call"] == []


@pytest.mark.parametrize(
    "command",
    [
        "false && tools/build.sh --stage native",
        "false && echo x && tools/build.sh --stage native",
        "true || tools/build.sh --stage native",
        ": || bash tools/build.sh --stage native",
        "exit 0\nbash tools/build.sh --stage native",
        "echo start\nexit 1\nbash tools/build.sh --stage native",
        "exit 0; bash tools/build.sh --stage native",
        "if false; then bash tools/build.sh --stage native; fi",
        "if false\nthen\n  bash tools/build.sh --stage native\nfi",
        "if false; then\n  if true; then bash tools/build.sh --stage native; fi\nfi",
        "if false; then for i in 1; do bash tools/build.sh --stage native; done; fi",
        "if x; then echo a; fi\nexit 0\nbash tools/build.sh --stage native",  # a closed block leaves the exit at the top level
        "if false; then\n  if x; then echo a; else echo b; fi\n  bash tools/build.sh --stage native\nfi",  # a nested else does not end the dead branch
    ],
)
def test_commands_that_provably_cannot_run_in_a_step_are_not_calls(tmp_path, command):
    gate = calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [], command


@pytest.mark.parametrize(
    "command",
    [
        "false || bash tools/build.sh --stage native",
        "false; bash tools/build.sh --stage native",
        "false && echo a; echo b && bash tools/build.sh --stage native",  # the short-circuit ends with its chain
        "true && bash tools/build.sh --stage native",
        "true; bash tools/build.sh --stage native",
        "if [ -f x ]; then exit 0; fi\nbash tools/build.sh --stage native",
        "test -f x || exit 1\nbash tools/build.sh --stage native",
        "f() { exit 1; }\nbash tools/build.sh --stage native",
        "for i in 1; do exit 2; done\nbash tools/build.sh --stage native",
        "case $x in a) exit 0 ;; esac\nbash tools/build.sh --stage native",
        "(exit 0)\nbash tools/build.sh --stage native",
        "{ exit 0; }\nbash tools/build.sh --stage native",
        "if false; then echo no; else bash tools/build.sh --stage native; fi",
        "if false; then echo no; elif true; then bash tools/build.sh --stage native; fi",
        "if false; then echo no; fi\nbash tools/build.sh --stage native",
        "if true; then bash tools/build.sh --stage native; fi",
        "if [ x ]; then if false; then echo; fi; bash tools/build.sh --stage native; fi",
    ],
)
def test_dead_code_pruning_stops_at_the_branch_it_proves_and_no_further(tmp_path, command):
    assert calling(tmp_path, command, extra=NATIVE)["gates"]["native-stage"]["called_by"] == [".github/workflows/ci.yml:build"], command


def test_scripts_and_heredoc_bodies_are_never_pruned(tmp_path):
    root = tree(tmp_path, {"ci.yml": workflow("bash tools/d.sh")})
    (root / "tools/d.sh").write_text("exit 0\nfalse && bash tools/build.sh --stage native\nif false; then bash tools/build.sh --stage native; fi\n")
    gate = parity.check(root, inventory(**NATIVE))["gates"]["native-stage"]
    assert gate["called_by"] == [] and gate["may_call"] == [".github/workflows/ci.yml:build via tools/d.sh"]
    assert parity.calls_in("exit 0\nbash tools/build.sh", prune=False) == [("tools/build.sh", ())]
    assert parity.calls_in("exit 0\nbash tools/build.sh") == []


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
        "echo 1<<2\nbash tools/build.sh --stage native",
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
    for line in ('echo "<<EOF"', "echo <<<EOF", "echo 1<<2", "cat <<'unterminated", "x=$((1<<3))", "# <<EOF", "(( 1<<EOF ))", "echo $((1<<2"):
        assert parity._find_heredoc(line) is None, line
    assert parity.split_heredocs("sh <<E\nbash tools/a.sh\nE\nz") == ("sh \nz", ["bash tools/a.sh"])
    assert parity.split_heredocs("cat <<E\nbody\nE") == ("cat ", [])
