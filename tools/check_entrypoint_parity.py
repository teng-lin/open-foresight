"""Check that local boundary gates and hosted workflows call the same entrypoints.

The boundary inventory names the checked-in script each command gate runs. A
workflow that never calls it means "run locally" and "hosted CI" can drift apart
without anyone noticing, so every command gate must either be called by a
workflow `run:` step or say why not (`local_only`). A `local_only` claim that a
workflow now contradicts is stale. Workflows are only read, never changed, and
anything that does not parse into the expected shape fails the check instead of
being skipped.

What counts as a call is deliberate. A `run:` text is split into commands the way
a shell would (comments stripped, quotes honored, here-document bodies skipped
unless the document is fed to a shell, `;`, `&&`, `||`, pipes and newlines
separating commands), and a script is called only when it is a whole token of a
command that executes things: a mention in `echo`, `cp`, `chmod`, `test` or a
quoted string is not a call, nor is a step or job whose `if:` is the literal
`false`. A gate that names `--stage` or `--suite` is satisfied only by a call with
the same value, and a `--build-only` call does not satisfy a gate that does not
ask for it.

Only a step's own call, with a literal discriminator, puts a workflow step in a
gate's `called_by`. Two weaker kinds of evidence are `may_call`: a call a
repository shell script makes (the script is read with the caller's literal
arguments, so `if [[ "$suite" == deb ]]` branches and a taken `exit` are
followed, but any condition on the environment stays unknown), and a call whose
`--stage`/`--suite` value comes from a shell variable. A gate whose only
evidence is `may_call` is reported as wiring-unverified, listed in the output
and never counted as a pass. Static limits remain: `if false; then ...; fi` in a
step, shell functions that are never invoked, and code after `exit 0` in a
region the analysis cannot prove taken are still read as commands.

Inline test-runner invocations in workflows (`dart test`, `flutter test`, `ctest`,
`pytest`) are reported for information. They are not failures.
"""

from __future__ import annotations

import argparse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import shlex
import sys
from typing import Any

import yaml

from tools import boundary_inventory

ROOT = Path(__file__).resolve().parents[1]
_PATH = re.compile(r"^(?:\./)?((?:tools|packaging)/[A-Za-z0-9_./-]+\.(?:py|sh))$")
_MODULE = re.compile(r"^(tools\.[A-Za-z0-9_]+)$")
_INLINE = re.compile(r"(?<![\w./-])(dart test|flutter test|ctest|pytest|python[\d.]* -m pytest)\b")
_OPERATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", ";;", "{", "}"}
_KEYWORDS = {"if", "then", "elif", "else", "do", "while", "until", "!", "fi", "done", "time"}
# Commands whose arguments are data, not something to execute: a script path
# after them is a mention, not a call.
_NOT_EXECUTING = {
    "echo", "printf", "cat", "grep", "egrep", "fgrep", "sed", "awk", "test", "[", "[[", "ls", "cp", "mv", "rm",
    "ln", "mkdir", "touch", "chmod", "chown", "tee", "diff", "cmp", "sha256sum", "shasum", "md5sum", "stat",
    "wc", "head", "tail", "find", "read", "export", "local", "declare", "readonly", "set", "unset", "cd",
    "command", "which", "type", "readlink", "realpath", "dirname", "basename", "file", "du", "tar", "zip",
    "unzip", "curl", "wget", "git", "gh", "rsync", "install", "mapfile", "true", "false", ":",
}
_DISCRIMINATORS = ("--stage", "--suite")
_HEREDOC = re.compile(r"<<(-?)\s*(?:'([^']+)'|\"([^\"]+)\"|([A-Za-z_][A-Za-z0-9_]*))")
_SHELL_FEED = re.compile(r"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+|exec\s+|env\s+)?(?:bash|sh|zsh|dash|source|\.)\b")
_FALSE = {"false", "${{ false }}", "${{false}}", "0"}


def _literally_false(value: Any) -> bool:
    return value is False or (isinstance(value, str) and value.strip().lower() in _FALSE)


@dataclass(frozen=True)
class Run:
    file: str
    job: str
    step: str
    text: str


@dataclass(frozen=True)
class Call:
    where: str  # file:job (and the step is in `step`)
    step: str
    script: str  # repository path, such as tools/build.sh
    args: tuple[str, ...]
    via: str | None = None


@dataclass
class Parsed:
    runs: list[Run] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)


class _Rejected(yaml.YAMLError):
    """A construct this guard refuses to interpret."""


class _Loader(yaml.SafeLoader):
    """SafeLoader without the YAML 1.1 booleans, so a job named `on` or `off` stays text.

    It also refuses anchors and aliases (an alias expansion is a denial-of-service
    shape in a file a pull request controls) and duplicate mapping keys (the
    last one would silently win).
    """

    def compose_node(self, parent: Any, index: Any) -> Any:
        if getattr(self.peek_event(), "anchor", None) is not None:
            raise _Rejected("anchors and aliases are not accepted")
        return super().compose_node(parent, index)

    def construct_mapping(self, node: Any, deep: bool = False) -> Any:
        keys = [self.construct_object(key, deep=True) for key, _value in node.value]
        duplicates = sorted({str(key) for key in keys if keys.count(key) > 1})
        if duplicates:
            raise _Rejected("duplicate keys: " + ", ".join(duplicates))
        return super().construct_mapping(node, deep)


_Loader.yaml_implicit_resolvers = {
    key: [(tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:bool"]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def _steps(document: Any, where: str, parsed: Parsed, file: str) -> None:
    if not isinstance(document, list):
        parsed.problems.append(f"{where}: steps must be a list")
        return
    for index, step in enumerate(document):
        if not isinstance(step, dict):
            parsed.problems.append(f"{where}: step {index} is not a mapping")
            continue
        if "run" in step:
            if not isinstance(step["run"], str):
                parsed.problems.append(f"{where}: step {index} has a run that is not text")
                continue
            if _literally_false(step.get("if")):
                continue  # a step that can never run calls nothing
            parsed.runs.append(Run(file, where, str(step.get("name", f"step {index}")), step["run"]))


def workflow_runs(root: Path = ROOT) -> tuple[list[Run], list[str]]:
    """Every runnable `run:` step of every workflow and composite action, and parse problems."""
    parsed = Parsed()
    files = sorted(
        path
        for pattern in ("*.yml", "*.yaml")
        for path in (root / ".github/workflows").glob(pattern)
    ) + sorted(
        path
        for pattern in ("action.yml", "action.yaml")
        for path in (root / ".github/actions").glob("**/" + pattern)
    )
    if not (root / ".github/workflows").is_dir() or not files:
        return [], ["no workflow files were found; the parity check cannot pass vacuously"]
    for path in files:
        name = path.relative_to(root).as_posix()
        try:
            document = yaml.load(path.read_text(), Loader=_Loader)  # noqa: S506 - the loader derives from SafeLoader
        except _Rejected as error:
            parsed.problems.append(f"{name}: {error}")
            continue
        except (yaml.YAMLError, RecursionError) as error:
            parsed.problems.append(f"{name}: not valid YAML ({type(error).__name__})")
            continue
        if not isinstance(document, dict):
            parsed.problems.append(f"{name}: top level is not a mapping")
        elif "jobs" in document:
            if not isinstance(document["jobs"], dict):
                parsed.problems.append(f"{name}: jobs is not a mapping")
                continue
            for job, body in document["jobs"].items():
                if not isinstance(job, str):
                    parsed.problems.append(f"{name}: job id {job!r} is not text")
                elif isinstance(body, dict) and "uses" in body and "steps" not in body:
                    continue  # a reusable-workflow call has no steps of its own
                elif not isinstance(body, dict) or "steps" not in body:
                    parsed.problems.append(f"{name}: job {job} has no steps")
                elif not _literally_false(body.get("if")):
                    _steps(body["steps"], f"{name}:{job}", parsed, name)
        elif isinstance(document.get("runs"), dict):
            _steps(document["runs"].get("steps", []), f"{name}:(action)", parsed, name)
        else:
            parsed.problems.append(f"{name}: neither a workflow with jobs nor a composite action")
    return parsed.runs, parsed.problems


def _tokens(line: str) -> list[str]:
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    return list(lexer)


def strip_heredocs(text: str) -> str:
    """The text without here-document bodies, except those fed to a shell (which runs them)."""
    kept: list[str] = []
    delimiter: str | None = None
    strip_tabs = False
    feeds_shell = False
    for line in text.splitlines():
        if delimiter is not None:
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                delimiter = None
            elif feeds_shell:
                kept.append(line)
            continue
        found = _HEREDOC.search(line)
        if found:
            delimiter = found.group(2) or found.group(3) or found.group(4)
            strip_tabs = found.group(1) == "-"
            feeds_shell = bool(_SHELL_FEED.match(line))
            line = line[: found.start()]
        kept.append(line)
    return "\n".join(kept)


def command_segments(text: str) -> list[list[str]]:
    """Commands of a shell text, comments stripped and quotes honored.

    Line continuations are joined, a quote that spans lines keeps reading, and a
    line shlex cannot read at all is split on whitespace as a last resort.
    """
    segments: list[list[str]] = []
    pending = ""
    for line in strip_heredocs(text).replace("\\\n", " ").splitlines():
        pending = f"{pending}\n{line}" if pending else line
        try:
            tokens = _tokens(pending)
        except ValueError:
            continue  # an open quote: the command continues on the next line
        pending = ""
        current: list[str] = []
        for token in tokens:
            if token in _OPERATORS:
                if current:
                    segments.append(current)
                current = []
            else:
                current.append(token)
        if current:
            segments.append(current)
    if pending:
        segments.append(pending.split())
    return segments


def _executes(segment: Sequence[str]) -> bool:
    index = 0
    while index < len(segment) and (segment[index] in _KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", segment[index])):
        index += 1
    return index < len(segment) and segment[index] not in _NOT_EXECUTING


def calls_in(text: str) -> list[tuple[str, tuple[str, ...]]]:
    """(script, arguments after it) for each repository script a command executes."""
    found = []
    for segment in command_segments(text):
        if not _executes(segment):
            continue
        for index, token in enumerate(segment):
            path = _PATH.match(token)
            if path:
                found.append((path.group(1), tuple(segment[index + 1 :])))
            elif index and segment[index - 1] == "-m" and _MODULE.match(token):
                found.append((token.replace(".", "/") + ".py", tuple(segment[index + 1 :])))
    return found


_ASSIGN_POSITIONAL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=\"?\$(?:\{(\d)(?:[:?-][^}]*)?\}|(\d))\"?$")
_TEST = re.compile(r"\[\[\s*(.*?)\s*\]\]|\[\s+(.*?)\s+\]")
_ATOM = re.compile(r"^\s*\"?\$\{?(\w+|\d)\}?\"?\s*(==|!=|=)\s*\"?([A-Za-z0-9_.-]+)\"?\s*$")


def _atom(text: str, bindings: Mapping[str, str]) -> bool | None:
    found = _ATOM.match(text)
    if not found or found.group(1) not in bindings:
        return None
    equal = bindings[found.group(1)] == found.group(3)
    return equal if found.group(2) in ("==", "=") else not equal


def _and(values: Sequence[bool | None]) -> bool | None:
    if False in values:
        return False
    return None if None in values else True


def _or(values: Sequence[bool | None]) -> bool | None:
    if True in values:
        return True
    return None if None in values else False


def evaluate(condition: str, bindings: Mapping[str, str]) -> bool | None:
    """Three-valued truth of a shell condition made of `[[ a == b ]]` tests; None when unknown."""
    leftover = _TEST.sub("", condition)
    if re.sub(r"\|\||&&|[\s;]", "", leftover):
        return None  # something other than tests (a command): unknown
    parts: list[bool | None] = []
    for found in _TEST.finditer(condition):
        group = found.group(1) if found.group(1) is not None else found.group(2)
        parts.append(_or([_and([_atom(atom, bindings) for atom in clause.split("&&")]) for clause in group.split("||")]))
    # Connectors between groups: `||` and `&&` outside the brackets.
    connectors = re.findall(r"\|\||&&", leftover)
    if not parts:
        return None
    result = parts[0]
    pending_or: list[bool | None] = []
    run = [result]
    for connector, value in zip(connectors, parts[1:], strict=False):
        if connector == "&&":
            run.append(value)
        else:
            pending_or.append(_and(run))
            run = [value]
    pending_or.append(_and(run))
    return _or(pending_or)


def reachable_text(script: str, arguments: Sequence[str]) -> str:
    """The lines of [script] that can run when it is called with [arguments].

    Only literal arguments bind `$1`..: a variable assigned from one is followed
    through `if`/`elif`/`else`, a branch whose test is known false is dropped, and
    a top-level `exit` in a region known to run ends the scan. Everything else
    (a test on the environment, a loop, a function) is read as a command that may
    run, so the result over-approximates.
    """
    bindings = {str(index + 1): token for index, token in enumerate(arguments) if "$" not in token}
    kept: list[str] = []
    frames: list[dict[str, Any]] = []  # per open `if`: state of the current branch, whether one is already taken
    lines = strip_heredocs(script).replace("\\\n", " ").splitlines()
    for raw in lines:
        line = raw.strip()
        assign = _ASSIGN_POSITIONAL.match(line)
        if assign:
            position = assign.group(2) or assign.group(3)
            if position in bindings:
                bindings[assign.group(1)] = bindings[position]
        word = line.split(None, 1)[0] if line else ""
        if word in ("if", "elif"):
            condition = line[len(word):].split("; then", 1)[0].strip()
            value = evaluate(condition, bindings)
            if word == "if":
                frames.append({"state": value, "taken": value is True, "unsure": value is None})
            elif frames:
                frame = frames[-1]
                if frame["taken"] or value is False:
                    frame["state"] = False
                elif value is True:
                    frame["state"] = None if frame["unsure"] else True
                    frame["taken"] = not frame["unsure"]
                else:
                    frame["state"], frame["unsure"] = None, True
            tail = line.split("; then", 1)[1].strip() if "; then" in line else ""
            if tail and all(frame["state"] is not False for frame in frames):
                kept.append(tail)
            continue
        if word == "else" and frames:
            frame = frames[-1]
            frame["state"] = False if frame["taken"] else (None if frame["unsure"] else True)
            continue
        if word == "fi":
            if frames:
                frames.pop()
            continue
        if word == "then":
            continue
        if any(frame["state"] is False for frame in frames):
            continue
        kept.append(line)
        if word == "exit" and all(frame["state"] is True for frame in frames):
            break
    return "\n".join(kept)


def collect_calls(runs: Sequence[Run], root: Path = ROOT, depth: int = 4) -> list[Call]:
    """Calls made by workflow steps, and by repository shell scripts those steps call."""
    calls: list[Call] = []

    def expand(where: str, step: str, text: str, via: str | None, seen: frozenset[str], remaining: int) -> None:
        for script, args in calls_in(text):
            calls.append(Call(where, step, script, args, via))
            path = root / script
            if script.endswith(".sh") and remaining and script not in seen and path.is_file():
                body = reachable_text(path.read_text(errors="replace"), args)
                expand(where, step, body, script, seen | {script}, remaining - 1)

    for run in runs:
        expand(run.job, run.step, run.text, None, frozenset(), depth)
    return calls


def inline_runners(runs: Sequence[Run]) -> list[dict[str, str]]:
    return [
        {"where": run.job, "step": run.step, "runner": match}
        for run in runs
        for match in sorted(set(_INLINE.findall(run.text)))
    ]


def _flag_values(args: Sequence[str], flag: str) -> list[str]:
    values = []
    for index, token in enumerate(args):
        if token == flag and index + 1 < len(args):
            values.append(args[index + 1])
        elif token.startswith(flag + "="):
            values.append(token.split("=", 1)[1])
    return values


def satisfies(call: Call, script: str, argv: Sequence[str]) -> str | None:
    """"exact", "ambiguous" (a shell variable chooses the value) or None for a call and a gate."""
    if call.script != script:
        return None
    if "--build-only" in call.args and "--build-only" not in argv:
        return None  # builds the stage and runs none of its tests
    result = "exact"
    for flag in _DISCRIMINATORS:
        wanted = _flag_values(argv, flag)
        if not wanted:
            continue
        given = _flag_values(call.args, flag)
        if not given:
            if script == "tools/build.sh" and flag == "--stage":
                continue  # build.sh runs every stage when none is named
            return None
        if wanted[0] in given or (script == "tools/build.sh" and "all" in given):
            continue
        if any("$" in value for value in given):
            result = "ambiguous"
            continue
        return None
    return result


def check(root: Path = ROOT, inventory: Mapping[str, Any] | None = None) -> dict[str, Any]:
    inventory = boundary_inventory.load(root) if inventory is None else inventory
    runs, problems = workflow_runs(root)
    calls = collect_calls(runs, root)
    for call in calls:
        if not (root / call.script).is_file():
            problems.append(f"{call.where}: step {call.step!r} calls {call.script}, which does not exist")
    gates: dict[str, Any] = {}
    for name, gate in sorted(inventory["gates"].items()):
        if gate["kind"] != "command":
            continue
        scripts = boundary_inventory._argv_entrypoints(gate["argv"])
        evidence: dict[str, bool] = {}  # label -> a direct, literal call of this gate's own value
        for call in calls:
            for script in scripts:
                kind = satisfies(call, script, gate["argv"])
                if kind:
                    label = call.where + (f" via {call.via}" if call.via else "")
                    evidence[label] = evidence.get(label, False) or (kind == "exact" and call.via is None)
        called_by = sorted(label for label, direct in evidence.items() if direct)
        may_call = sorted(label for label, direct in evidence.items() if not direct)
        local_only = gate.get("local_only")
        unverified = local_only is None and not called_by and bool(may_call)
        gates[name] = {
            "scripts": scripts, "called_by": called_by, "may_call": may_call,
            "wiring_unverified": unverified, "local_only": local_only,
        }
        if local_only is not None and (not isinstance(local_only, str) or not local_only.strip()):
            problems.append(f"gate {name}: local_only needs a reason")
        elif local_only is not None and called_by:
            problems.append(f"gate {name}: declared local_only but {called_by[0]} calls it; remove the stale declaration")
        elif local_only is None and not called_by and not may_call:
            detail = " ".join(gate["argv"][1:] if gate["argv"][0] in ("bash", "{python}") else gate["argv"])
            problems.append(f"gate {name}: no workflow step calls `{detail}`; wire it or declare local_only with a reason")
    return {
        "problems": problems, "gates": gates, "inline_runners": inline_runners(runs), "runs": len(runs),
        "wiring_unverified": sorted(name for name, gate in gates.items() if gate["wiring_unverified"]),
    }


def main(argv: Sequence[str] | None = None, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    report = check(root)
    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Checked {report['runs']} workflow run steps against {len(report['gates'])} command gates.")
        for name in report["wiring_unverified"]:
            gate = report["gates"][name]
            print(f"Wiring unverified: {name} (no step calls it directly; it may run via {', '.join(gate['may_call'])})")
        for problem in report["problems"]:
            print(f"- {problem}", file=sys.stderr)
    return 1 if report["problems"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
