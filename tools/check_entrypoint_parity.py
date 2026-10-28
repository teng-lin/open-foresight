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
repository shell script makes, and a call whose `--stage`/`--suite` value comes
from a shell variable. Script-mediated calls are over-approximated, not
evaluated: every command in a called script counts, whatever branch, loop or
function it sits in, and each script is read once per step. A gate whose only
evidence is `may_call` is wiring-unverified: it is listed in the output and must
be acknowledged with a `wiring_unverified_reason` in the inventory, so a new
unverified gate fails the guard and an acknowledged one that gains a direct
caller is a stale declaration. Hard limits (script size and lines, scripts and
calls per step, workflow size) are problems when hit, never silent truncation.
Static limits remain: `if false; then ...; fi` or code after `exit 0` inside a
step or script, shell functions never invoked, and the `--platform` argument
(not compared) are read as if they ran or matched.

Inline test-runner invocations in workflows (`dart test`, `flutter test`, `ctest`,
`pytest`) are reported for information. They are not failures.
"""

from __future__ import annotations

import argparse
from collections.abc import Mapping, Sequence
from collections import Counter, deque
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import shlex
import sys
from typing import Any, cast

import yaml

from tools import boundary_inventory

ROOT = Path(__file__).resolve().parents[1]
_PATH = re.compile(r"^(?:\./)?((?:tools|packaging)/[A-Za-z0-9_./-]+\.(?:py|sh))$")
_MODULE = re.compile(r"^(tools\.[A-Za-z0-9_]+)$")
_INLINE = re.compile(r"(?<![\w./-])(dart test|flutter test|ctest|pytest|python[\d.]* -m pytest)\b")
_OPERATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", ";;", "{", "}"}
_KEYWORDS = {"if", "then", "elif", "else", "do", "while", "until", "!", "fi", "done", "time"}
_DISCRIMINATORS = ("--stage", "--suite")
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
    entries: set[str] = field(default_factory=set)  # workflows something can trigger
    reaches: dict[str, set[str]] = field(default_factory=dict)  # file -> workflows and action files it calls


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
        duplicates = sorted(str(key) for key, count in Counter(keys).items() if count > 1)
        if duplicates:
            raise _Rejected("duplicate keys: " + ", ".join(duplicates))
        return super().construct_mapping(node, deep)


_Loader.yaml_implicit_resolvers = {
    key: [(tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:bool"]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def _local_target(uses: Any) -> str | None:
    """The repository path a local `uses:` names, or None for a marketplace or remote reference."""
    if not isinstance(uses, str) or not uses.startswith("./"):
        return None
    return uses[2:].rstrip("/")


def _steps(document: Any, where: str, parsed: Parsed, file: str) -> None:
    if not isinstance(document, list):
        parsed.problems.append(f"{where}: steps must be a list")
        return
    for index, step in enumerate(document):
        if not isinstance(step, dict):
            parsed.problems.append(f"{where}: step {index} is not a mapping")
            continue
        if not _literally_false(step.get("if")) and (target := _local_target(step.get("uses"))):
            parsed.reaches.setdefault(file, set()).add(target)  # a local composite action
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
        if path.stat().st_size > MAX_WORKFLOW_BYTES:
            parsed.problems.append(f"{name}: larger than the {MAX_WORKFLOW_BYTES} byte analysis cap")
            continue
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
            if _triggered(document.get("on", "push")):
                parsed.entries.add(name)
            if not isinstance(document["jobs"], dict):
                parsed.problems.append(f"{name}: jobs is not a mapping")
                continue
            for job, body in document["jobs"].items():
                if not isinstance(job, str):
                    parsed.problems.append(f"{name}: job id {job!r} is not text")
                elif isinstance(body, dict) and "uses" in body and "steps" not in body:
                    if not _literally_false(body.get("if")) and (target := _local_target(body["uses"])):
                        parsed.reaches.setdefault(name, set()).add(target)
                    continue  # a reusable-workflow call has no steps of its own
                elif not isinstance(body, dict) or "steps" not in body:
                    parsed.problems.append(f"{name}: job {job} has no steps")
                elif not _literally_false(body.get("if")):
                    _steps(body["steps"], f"{name}:{job}", parsed, name)
        elif isinstance(document.get("runs"), dict):
            _steps(document["runs"].get("steps", []), f"{name}:(action)", parsed, name)
        else:
            parsed.problems.append(f"{name}: neither a workflow with jobs nor a composite action")
    reachable = _reachable(parsed)
    return [run for run in parsed.runs if run.file in reachable], parsed.problems


def _triggered(trigger: Any) -> bool:
    """Whether anything but another workflow can start a workflow with this `on:`."""
    if isinstance(trigger, str):
        return trigger != "workflow_call"
    if isinstance(trigger, list):
        return any(item != "workflow_call" for item in trigger)
    if isinstance(trigger, dict):
        return any(key != "workflow_call" for key in trigger)
    return True


def _reachable(parsed: Parsed) -> set[str]:
    """Files whose steps can run: triggered workflows, and what they call, transitively."""
    known = {run.file for run in parsed.runs} | set(parsed.reaches) | parsed.entries
    reachable = set(parsed.entries)
    queue = list(reachable)
    while queue:
        for target in parsed.reaches.get(queue.pop(), ()):
            for file in known:
                same = file == target or Path(file).parent.as_posix() == target
                if same and file not in reachable:
                    reachable.add(file)
                    queue.append(file)
    return reachable


def _find_heredoc(line: str) -> tuple[int, bool, str] | None:
    """(start, strips tabs, delimiter) of a here-document opened on [line], or None.

    `<<` counts only outside quotes, comments and arithmetic (`$(( 1<<2 ))`,
    `(( x<<2 ))`), and never as the here-string `<<<`.
    """
    quote: str | None = None
    word_start = True
    index = 0
    length = len(line)
    while index < length:
        char = line[index]
        if quote is not None:
            if char == "\\" and quote == '"':
                index += 1
            elif char == quote:
                quote = None
        elif char == "\\":
            index += 1
            word_start = False
        elif char in "'\"":
            quote = char
            word_start = False
        elif char == "#" and word_start:
            return None
        elif line.startswith("$((", index) or (word_start and line.startswith("((", index)):
            end = line.find("))", index + 2)
            if end < 0:
                return None
            index = end + 1
            word_start = False
        elif line.startswith("<<<", index):
            index += 2
        elif line.startswith("<<", index):
            cursor = index + 2
            strip_tabs = cursor < length and line[cursor] == "-"
            cursor += strip_tabs
            while cursor < length and line[cursor] in " \t":
                cursor += 1
            if cursor < length and line[cursor] in "'\"":
                end = line.find(line[cursor], cursor + 1)
                return (index, strip_tabs, line[cursor + 1 : end]) if end > 0 else None
            word = re.match(r"[A-Za-z_][A-Za-z0-9_]*", line[cursor:])
            return (index, strip_tabs, word.group(0)) if word else None
        else:
            word_start = char in " \t;&|()"
        index += 1
    return None


def split_heredocs(text: str) -> tuple[str, list[str]]:
    """(the text without here-document bodies, the bodies fed to a shell).

    A body fed to a shell is run by it, but only as an over-approximation: the
    caller treats its commands as may_call, never as direct calls.
    """
    kept: list[str] = []
    bodies: list[str] = []
    delimiter: str | None = None
    strip_tabs = False
    feeds_shell = False
    for line in text.splitlines():
        if delimiter is not None:
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                delimiter = None
            elif feeds_shell:
                bodies.append(line)
            continue
        found = _find_heredoc(line)
        if found:
            start, strip_tabs, delimiter = found
            feeds_shell = bool(_SHELL_FEED.match(line))
            line = line[:start]
        kept.append(line)
    return "\n".join(kept), ["\n".join(bodies)] if bodies else []


def strip_heredocs(text: str) -> str:
    """The text without here-document bodies."""
    return split_heredocs(text)[0]


_PUNCTUATION = ";()<>|&\n"


def _tokens(text: str) -> list[str]:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=_PUNCTUATION)
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    lexer.commenters = ""  # comments are removed first, by strip_comments
    return list(lexer)


def _loose_tokens(text: str) -> list[str]:
    """Tokens of text shlex cannot read (an unclosed quote): words and operators, no quoting rules."""
    return [token for line in text.splitlines() for token in (*re.findall(r"[^\s;&|()]+|[;&|()]", line), "\n")]


def strip_comments(text: str) -> str:
    """The text without shell comments, in one pass that honors quotes and escapes.

    A comment starts at a `#` at the start of a word and runs to the end of the
    line, so an apostrophe inside a comment cannot open a quote.
    """
    out: list[str] = []
    quote: str | None = None
    word_start = True
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if quote is not None:
            out.append(char)
            if char == "\\" and quote == '"' and index + 1 < length:
                out.append(text[index + 1])
                index += 1
            elif char == quote:
                quote = None
        elif char == "\\" and index + 1 < length:
            out.append(char + text[index + 1])
            index += 1
            word_start = False
        elif char in "'\"":
            quote = char
            out.append(char)
            word_start = False
        elif char == "#" and word_start:
            while index + 1 < length and text[index + 1] != "\n":
                index += 1
        else:
            out.append(char)
            word_start = char in " \t\r\n;&|()"
        index += 1
    return "".join(out)


def command_stream(text: str) -> list[tuple[tuple[str, ...], list[str]]]:
    """(separators before, command) for each command of a shell text; the text is lexed once.

    Comments are stripped and quotes honored. Line continuations are joined. Text
    shlex cannot read (an unclosed quote) is split on whitespace and operators
    instead, so a hostile file costs one extra linear pass and never a re-lex per
    line.
    """
    cleaned = strip_comments(strip_heredocs(text).replace("\\\n", " "))
    try:
        tokens = _tokens(cleaned)
    except ValueError:
        tokens = _loose_tokens(cleaned)
    stream: list[tuple[tuple[str, ...], list[str]]] = []
    current: list[str] = []
    separators: list[str] = []
    for token in tokens:
        if token in _OPERATORS or ("\n" in token and set(token) <= set(_PUNCTUATION)):
            if current:
                stream.append((tuple(separators), current))
                current, separators = [], []
            separators.append(token.strip("\n") or "\n")
        else:
            current.append(token)
    if current:
        stream.append((tuple(separators), current))
    return stream


def command_segments(text: str) -> list[list[str]]:
    return [segment for _separators, segment in command_stream(text)]


_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
_SOURCERS = {"source", "."}
# Words that run the command they are given: the script after them is executed.
_WRAPPERS = {
    "env", "sudo", "time", "nohup", "exec", "xvfb-run", "dbus-run-session", "timeout", "nice", "ionice", "stdbuf",
    "command", "setsid", "unbuffer",
}
# Flags that make an interpreter read a script without running it, or run something else.
_NOT_RUNNING_FLAGS = {"-n", "-c", "--version", "-V", "--help", "-h", "--check"}


def _interpreter(word: str) -> bool:
    name = word.rsplit("/", 1)[-1]
    return name in _SHELLS or name in _SOURCERS or bool(re.fullmatch(r"python[0-9.]*", name))


def _skippable(word: str) -> bool:
    """Tokens between a runner and its script that do not change what runs: flags, counts, assignments, keywords."""
    return (
        word.startswith("-")
        or word in _KEYWORDS
        or bool(re.fullmatch(r"[0-9]+[smhd]?", word))
        or bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word))
    )


def _takes_value(segment: Sequence[str], cursor: int) -> bool:
    """The value of a shell option such as `bash -euo pipefail script`."""
    return cursor > 0 and bool(re.fullmatch(r"[-+][A-Za-z]*o", segment[cursor - 1])) and not segment[cursor].startswith("-")


def _runs_script(segment: Sequence[str], index: int) -> bool:
    """Whether the token at [index] sits where it is executed rather than read, linted or copied.

    It is executed when it is the command itself (nothing before it but
    keywords, assignments and wrappers) or the argument of an interpreter with no
    flag that stops the interpreter from running it (`bash -n`, `-c`).
    """
    flags: list[str] = []
    cursor = index - 1
    while cursor >= 0 and (_skippable(segment[cursor]) or _takes_value(segment, cursor)):
        flags.append(segment[cursor])
        cursor -= 1
    if cursor < 0:
        return True  # the script itself is the command, as in `FOO=1 tools/build.sh` or `then tools/build.sh`
    runner = segment[cursor]
    if runner in _SOURCERS and any(not _skippable(word) for word in segment[:cursor]):
        return False  # `find . -exec ...`: a dot that is an argument is not the `.` builtin
    if _interpreter(runner):
        return not _NOT_RUNNING_FLAGS.intersection(flags)
    return runner.rsplit("/", 1)[-1] in _WRAPPERS


_OPENERS = {"if", "case", "for", "while", "until", "select"}
_CLOSERS = {"fi", "esac", "done"}


def calls_in(text: str, prune: bool = True) -> list[tuple[str, tuple[str, ...]]]:
    """(script, arguments after it) for each repository script a command executes.

    With [prune] (the state below only ever changes then), commands that provably cannot run are dropped: those after a
    top-level `exit`, those joined to a bare `false` by `&&` or to a bare `true`
    by `||`, and the body of `if false`. That is all the guard decides about
    control flow; it is for a step's own text. A called script is read with
    [prune] off, because over-approximating is the contract there.
    """
    found: list[tuple[str, tuple[str, ...]]] = []
    depth = 0
    open_groups = {"(": 0, "{": 0}
    dead = False
    skip_joiner: str | None = None
    false_if_depth: int | None = None
    for separators, segment in command_stream(text):
        for separator in separators:
            if separator in open_groups:
                open_groups[separator] += 1
                depth += 1
            elif separator in (")", "}"):
                opener = "(" if separator == ")" else "{"
                if open_groups[opener]:  # an unmatched `)` ends a case pattern, not a group
                    open_groups[opener] -= 1
                    depth = max(0, depth - 1)
        head = segment[0]
        joiner = separators[-1] if separators and separators[-1] in ("&&", "||") else None
        if false_if_depth is not None and depth == false_if_depth and head in ("fi", "else", "elif"):
            false_if_depth = None  # the dead branch ends; an else or elif may run
        if head in _CLOSERS:
            depth = max(0, depth - 1)
            continue
        opens = head in _OPENERS
        if dead or false_if_depth is not None or (skip_joiner is not None and joiner == skip_joiner):
            depth += opens
            continue
        skip_joiner = None
        for index, token in enumerate(segment):
            path = _PATH.match(token)
            if path and ".." not in path.group(1).split("/") and _runs_script(segment, index):
                found.append((path.group(1), tuple(segment[index + 1 :])))
            elif index and segment[index - 1] == "-m" and _MODULE.match(token) and _runs_script(segment, index - 1):
                found.append((token.replace(".", "/") + ".py", tuple(segment[index + 1 :])))
        if prune:
            if segment == ["false"]:
                skip_joiner = "&&"
            elif segment in (["true"], [":"]):
                skip_joiner = "||"
            elif head == "exit" and depth == 0 and joiner is None:
                dead = True
            elif segment == ["if", "false"]:
                false_if_depth = depth + 1
        depth += opens
    return found


# Hard limits on what one workflow step may make the guard read. A cap that is
# hit is a problem, never a silent truncation: the guard fails closed.
MAX_SCRIPT_BYTES = 256 * 1024
MAX_SCRIPT_LINES = 5000
MAX_SCRIPTS_PER_STEP = 200
MAX_CALLS_PER_STEP = 5000
MAX_WORKFLOW_BYTES = 1024 * 1024


def _read_script(path: Path) -> tuple[str | None, str | None]:
    """(text, problem): a repository script, or why it was not read."""
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_SCRIPT_BYTES + 1)
    except OSError as error:
        return None, f"cannot be read ({type(error).__name__})"
    if len(data) > MAX_SCRIPT_BYTES:
        return None, f"is larger than the {MAX_SCRIPT_BYTES} byte analysis cap"
    text = data.decode(errors="replace")
    if text.count("\n") > MAX_SCRIPT_LINES:
        return None, f"has more than the {MAX_SCRIPT_LINES} line analysis cap"
    return text, None


def collect(runs: Sequence[Run], root: Path = ROOT) -> tuple[list[Call], list[str]]:
    """Calls made by workflow steps, and by the repository shell scripts those steps call.

    Script-mediated calls are over-approximated, not evaluated: every command in
    a called script counts, whatever branch, loop or function it is in, and each
    script is read once per step however often it is reached. Returns the calls
    and the problems for any cap that was hit.
    """
    calls: list[Call] = []
    problems: list[str] = []
    for run in runs:
        found = 0
        scripts: set[str] = set()
        main, bodies = split_heredocs(run.text)
        # A step's own text is pruned; a script and a here-document fed to a shell are not (over-approximation).
        queue: deque[tuple[str, str | None, bool]] = deque([(main, None, True), *((body, "<heredoc>", False) for body in bodies)])
        while queue:
            text, via, prune = queue.popleft()
            for script, args in calls_in(text, prune):
                if found >= MAX_CALLS_PER_STEP:
                    problems.append(f"{run.job}: step {run.step!r} makes more than {MAX_CALLS_PER_STEP} calls; the analysis stopped (wiring unverified)")
                    queue.clear()
                    break
                found += 1
                calls.append(Call(run.job, run.step, script, args, via))
                if not script.endswith(".sh") or script in scripts or not (root / script).is_file():
                    continue
                if len(scripts) >= MAX_SCRIPTS_PER_STEP:
                    problems.append(f"{run.job}: step {run.step!r} reaches more than {MAX_SCRIPTS_PER_STEP} scripts; the analysis stopped (wiring unverified)")
                    queue.clear()
                    break
                scripts.add(script)
                body, problem = _read_script(root / script)
                if problem:
                    problems.append(f"{run.job}: step {run.step!r}: {script} {problem} (wiring unverified)")
                else:
                    main, bodies = split_heredocs(cast(str, body))
                    queue.append((main, script, False))
                    queue.extend((fed, script, False) for fed in bodies)
    return calls, problems


def collect_calls(runs: Sequence[Run], root: Path = ROOT) -> list[Call]:
    return collect(runs, root)[0]


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
                result = "ambiguous"  # build.sh runs every stage when none is named: evidence, never an exact call
                continue
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
    calls, capped = collect(runs, root)
    problems.extend(capped)
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
        declared = gate.get("wiring_unverified_reason")
        gates[name] = {
            "scripts": scripts, "called_by": called_by, "may_call": may_call,
            "wiring_unverified": unverified, "local_only": local_only, "declared_unverified": declared,
        }
        if declared is not None and (not isinstance(declared, str) or not declared.strip()):
            problems.append(f"gate {name}: wiring_unverified_reason needs a reason")
        elif declared is not None and not unverified:
            problems.append(f"gate {name}: declared wiring_unverified_reason but it now has direct evidence or none; remove the stale declaration")
        elif unverified and declared is None:
            problems.append(f"gate {name}: only a script or a variable may call it ({may_call[0]}); call it directly or declare wiring_unverified_reason")
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
        for name, gate in sorted(report["gates"].items()):
            if gate["wiring_unverified"]:
                print(f"Wiring unverified: {name} (no step calls it directly; it may run via {', '.join(gate['may_call'])})")
            elif gate["may_call"]:
                print(f"May also run (not verified): {name} via {', '.join(gate['may_call'])}")
        for problem in report["problems"]:
            print(f"- {problem}", file=sys.stderr)
    return 1 if report["problems"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
