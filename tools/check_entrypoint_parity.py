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
the same value (`tools/build.sh` defaults to `--stage all`, so a call without
`--stage` satisfies every stage), and a `--build-only` call does not satisfy a
gate that does not ask for it.

Two tiers, and nothing is ever dropped by reasoning about shell control flow. A
call is `exact` (the gate's `called_by`) only when it is a top-level
unconditional simple command of the step's own text, with a literal
`--stage`/`--suite` (and, for a gate that passes `--platform {platform}`, the
platform of its flag or its runner). Everything else that mentions a script in an
executing position is `may_call`: a call inside `if`/`case`/a loop/a function/a
subshell/a conditional group, in an and-or list, after a top-level `exit`, made
by a repository shell script, fed to a shell as a here-document, or whose stage
or suite comes from a variable the guard cannot resolve. Script-mediated calls
are over-approximated, not evaluated: every command in a called script counts,
and each script is read once per step. The one thing resolved is a GitHub matrix:
a variable bound to `${{ matrix.key }}` is replaced by each value of a literal
list that no include or exclude touches (the step's own `if:` is not evaluated).
A gate (on a platform) whose only evidence is `may_call` is wiring-unverified:
it is listed in the output and must be acknowledged with a
`wiring_unverified_reason` in the inventory, so a new unverified gate fails the
guard and an acknowledged one that gains an exact caller is a stale declaration.
Hard limits (script size and lines, scripts and calls per step, workflow size)
are problems when hit, never silent truncation. Static limits: the guard does not
tell whether a conditional call runs, and `--build-only`/`--platform` are the
only other arguments it compares.

Inline test-runner invocations in workflows (`dart test`, `flutter test`, `ctest`,
`pytest`) are reported for information. They are not failures.
"""

from __future__ import annotations

import argparse
from collections.abc import Mapping, Sequence
from collections import Counter, deque
from dataclasses import dataclass, field
import itertools
import json
import math
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
    platform: str | None = None  # linux or macos when the job's runs-on says so
    exact_allowed: bool = True  # False when an `if:` on the step could not be evaluated and mentions the matrix


@dataclass(frozen=True)
class Call:
    where: str  # file:job (and the step is in `step`)
    step: str
    script: str  # repository path, such as tools/build.sh
    args: tuple[str, ...]
    via: str | None = None
    exact: bool = False  # a top-level unconditional command of a step's own text
    platform: str | None = None


@dataclass
class Parsed:
    runs: list[Run] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    entries: set[str] = field(default_factory=set)  # workflows something can trigger
    reaches: dict[str, set[str]] = field(default_factory=dict)  # file -> workflows and action files it calls
    expanded: int = 0  # steps produced by matrix expansion so far, against MAX_EXPANDED_RUNS


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
        counts = Counter(repr(item) for item in keys)  # repr: a key such as `? [a, b]` is not hashable
        duplicates = sorted(str(item) for item in keys if counts[repr(item)] > 1)
        duplicates = sorted(set(duplicates))
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


_MATRIX_EXPRESSION = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")
_MAX_EXPANSIONS = 64


def _runner_platform(runs_on: Any) -> str | None:
    label = runs_on[0] if isinstance(runs_on, list) and runs_on else runs_on
    if isinstance(label, str):
        label = label.lower()
        if label.startswith("macos"):
            return "macos"
        if label.startswith(("ubuntu", "linux")):
            return "linux"
    return None


def _matrix_values(job: Mapping[str, Any]) -> dict[str, list[str]]:
    """Matrix keys whose values are a literal list that no include or exclude touches."""
    strategy = job.get("strategy")
    matrix = strategy.get("matrix") if isinstance(strategy, dict) else None
    if not isinstance(matrix, dict):
        return {}
    touched = {
        key
        for rule in ("include", "exclude")
        if isinstance(matrix.get(rule), list)
        for entry in matrix[rule]
        if isinstance(entry, dict)
        for key in entry
    }
    unreadable = any(rule in matrix and not isinstance(matrix[rule], list) for rule in ("include", "exclude"))
    return {
        str(key): [str(item) for item in values]
        for key, values in matrix.items()
        if key not in ("include", "exclude") and key not in touched and not unreadable
        and isinstance(values, list) and values and all(isinstance(item, (str, int, float)) for item in values)
    }


PLATFORM_NAMES = ("linux", "macos")
MAX_EXPANDED_RUNS = 2000  # matrix-expanded steps in one run of the guard
_IF_MATRIX = re.compile(r"^\s*(?:\$\{\{\s*)?matrix\.([A-Za-z0-9_-]+)\s*(==|!=)\s*'([^']*)'\s*(?:\}\}\s*)?$")


def _expansions(
    step: Mapping[str, Any], job: Mapping[str, Any], text: str, parsed: Parsed | None = None, label: str = ""
) -> list[tuple[str, dict[str, str]]]:
    """(text, matrix values) once per literal matrix combination the step is bound to, or once as written.

    A variable is bound when the step's or job's `env` sets it to exactly
    `${{ matrix.key }}`; an expression `${{ matrix.key }}` written in the text is
    bound too. The size of the product is computed first: more than
    `_MAX_EXPANSIONS` combinations, or more than the run's expansion budget, is not
    expanded at all (a problem line; the unresolved variable keeps the call
    may_call).
    """
    values = _matrix_values(job)
    if not values:
        return [(text, {})]
    env: dict[str, Any] = {}
    for source in (job.get("env"), step.get("env")):
        if isinstance(source, dict):
            env.update(source)
    bound: dict[str, str] = {}  # replacement pattern -> matrix key
    for name, value in env.items():
        found = _MATRIX_EXPRESSION.match(value.strip()) if isinstance(value, str) else None
        if found and found.group(1) in values:
            bound[rf"\$\{{?{re.escape(str(name))}\}}?(?![A-Za-z0-9_])"] = found.group(1)
    for key in values:
        if re.search(rf"\$\{{\{{\s*matrix\.{re.escape(key)}\s*\}}\}}", text):
            bound[rf"\$\{{\{{\s*matrix\.{re.escape(key)}\s*\}}\}}"] = key
    bound = {pattern: key for pattern, key in bound.items() if re.search(pattern, text)}
    if not bound:
        return [(text, {})]
    keys = sorted(set(bound.values()))
    size = math.prod(len(values[key]) for key in keys)
    if size > _MAX_EXPANSIONS or (parsed is not None and parsed.expanded + size > MAX_EXPANDED_RUNS):
        if parsed is not None:
            parsed.problems.append(f"{label}: a matrix of {size} combinations is not expanded (more than the cap or the run's budget of {MAX_EXPANDED_RUNS}); its calls stay may_call")
        return [(text, {})]
    if parsed is not None:
        parsed.expanded += size
    result = []
    for combo in itertools.product(*(values[key] for key in keys)):
        combination = dict(zip(keys, combo, strict=True))
        variant = text
        for pattern, key in bound.items():
            variant = re.sub(pattern, combination[key].replace("\\", "\\\\"), variant)
        result.append((variant, combination))
    return result


def _condition(expression: Any, combination: Mapping[str, str], values: Mapping[str, list[str]]) -> bool | None:
    """Whether a step's `if:` lets it run: True, False, or None when it mentions the matrix and cannot be read.

    Only `matrix.key == 'v'` and `!= 'v'` are read, against the expanded value, or
    against every listed value when the key is not bound (the step runs if any
    does). Anything else that does not mention the matrix is treated as true: the
    guard does not evaluate workflow expressions.
    """
    if expression is None or expression is True or (isinstance(expression, str) and expression.strip().lower() in ("true", "${{ true }}")):
        return True
    text = expression if isinstance(expression, str) else str(expression)
    if "matrix." not in text:
        return True
    found = _IF_MATRIX.match(text)
    if not found or found.group(1) not in values:
        return None
    key, operator, literal = found.groups()

    def holds(value: str) -> bool:
        return (value == literal) == (operator == "==")

    if key in combination:
        return holds(combination[key])
    return any(holds(value) for value in values[key])


def _steps(document: Any, where: str, parsed: Parsed, file: str, job: Mapping[str, Any] | None = None) -> None:
    if not isinstance(document, list):
        parsed.problems.append(f"{where}: steps must be a list")
        return
    job = job or {}
    platform = _runner_platform(job.get("runs-on"))
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
            values = _matrix_values(job)
            for text, combination in _expansions(step, job, step["run"], parsed, f"{where}: step {index}"):
                verdict = _condition(step.get("if"), combination, values)
                if verdict is False:
                    continue  # no listed value lets this step run
                parsed.runs.append(Run(file, where, str(step.get("name", f"step {index}")), text, platform, verdict is not None))


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
            if path.stat().st_size > MAX_WORKFLOW_BYTES:
                parsed.problems.append(f"{name}: larger than the {MAX_WORKFLOW_BYTES} byte analysis cap")
                continue
            document = yaml.load(path.read_text(), Loader=_Loader)  # noqa: S506 - the loader derives from SafeLoader
        except _Rejected as error:
            parsed.problems.append(f"{name}: {error}")
            continue
        except (yaml.YAMLError, RecursionError) as error:
            parsed.problems.append(f"{name}: not valid YAML ({type(error).__name__})")
            continue
        except Exception as error:  # noqa: BLE001 - a broken symlink, binary or unreadable file is a problem line, not a traceback
            parsed.problems.append(f"{name}: cannot be read ({type(error).__name__})")
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
                    _steps(body["steps"], f"{name}:{job}", parsed, name, body)
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


_DELIMITER_WORD = re.compile(r"[^\s;&|<>()'\"\\]+")


def _heredoc_delimiter(line: str, cursor: int) -> tuple[str, int, bool] | None:
    """(delimiter, end of the word, unsure) of the here-document word at [cursor], or None.

    The word is quoted (`'EOF'`, `"EOF"`), backslash-quoted (`\\EOF`) or bare
    (`EOF`, `END-OF`). A word that mixes quoting (`E"O"F`) is read as written and
    marked unsure: its body is then kept as may_call instead of being dropped.
    """
    length = len(line)
    if cursor >= length:
        return None
    char = line[cursor]
    if char in "'\"":
        end = line.find(char, cursor + 1)
        return None if end < 0 else (line[cursor + 1 : end], end + 1, False)
    word = ""
    unsure = False
    while cursor < length and line[cursor] not in " \t;&|<>()":
        char = line[cursor]
        if char == "\\" and cursor + 1 < length:
            word += line[cursor + 1]
            cursor += 2
        elif char in "'\"":
            end = line.find(char, cursor + 1)
            if end < 0:
                return None
            word += line[cursor + 1 : end]
            cursor = end + 1
            unsure = True
        else:
            word += char
            cursor += 1
    return (word, cursor, unsure) if word else None


def _find_heredocs(line: str) -> list[tuple[int, bool, str, bool, int]]:
    """(start, strips tabs, delimiter, unsure, end) of every here-document opened on [line], in order.

    `<<` counts only outside quotes, comments and arithmetic (`$(( 1<<2 ))`,
    `(( x<<2 ))`), and never as the here-string `<<<`. `cat <<A <<B` opens two.
    """
    found: list[tuple[int, bool, str, bool, int]] = []
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
            return found
        elif line.startswith("$((", index) or (word_start and line.startswith("((", index)):
            end = line.find("))", index + 2)
            if end < 0:
                return found
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
            parsed = _heredoc_delimiter(line, cursor)
            if parsed is None:
                return found
            delimiter, end, unsure = parsed
            found.append((index, strip_tabs, delimiter, unsure, end))
            index = end - 1
            word_start = False
        else:
            word_start = char in " \t;&|()"
        index += 1
    return found


def _find_heredoc(line: str) -> tuple[int, bool, str] | None:
    """The first here-document on [line] as (start, strips tabs, delimiter), or None."""
    found = _find_heredocs(line)
    return found[0][:3] if found else None


def split_heredocs(text: str) -> tuple[str, list[str]]:
    """(the text without here-document bodies, the bodies that must still be read).

    A body is dropped only when it is a plain, terminated document. A body fed to
    a shell is run by it, a body with an unsure delimiter may be something else
    than it looks, and a body that never terminates is whatever follows: all three
    are returned to be read as may_call, never dropped.
    """
    kept: list[str] = []
    bodies: list[str] = []
    pending: deque[tuple[bool, str, bool]] = deque()  # (strips tabs, delimiter, keep body)
    current: list[str] = []
    for line in text.splitlines():
        if pending:
            strip_tabs, delimiter, keep = pending[0]
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                pending.popleft()
                if keep and current:
                    bodies.append("\n".join(current))
                current = []
            else:
                current.append(line)
            continue
        found = _find_heredocs(line)
        if found:
            feeds_shell = bool(_SHELL_FEED.match(line))
            pending.extend((tabs, delimiter, feeds_shell or unsure) for _start, tabs, delimiter, unsure, _end in found)
            for start, _tabs, _delimiter, _unsure, end in reversed(found):
                line = line[:start] + line[end:]  # the operator and its word go; the rest of the line is still a command
        kept.append(line)
    if pending and current:
        bodies.append("\n".join(current))  # never terminated: not provably a document, so read it
    return "\n".join(kept), bodies


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


_PUNCTUATION_PIECE = re.compile(r"&&|\|\||;;|\|&|&>>?|[<>]+&?-?|[;|&()\n]")
_PUNCTUATION_SET = set(_PUNCTUATION)


def _pieces(token: str) -> list[str]:
    """A token of fused punctuation as shell words: `)&&` is `)` then `&&`; a redirect such as `>&` stays one."""
    if not set(token) <= _PUNCTUATION_SET:
        return [token]
    return _PUNCTUATION_PIECE.findall(token) or [token]


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
    for fused in tokens:
        for piece in _pieces(fused):
            if piece in _OPERATORS or piece == "\n":
                if current:
                    stream.append((tuple(separators), current))
                    current, separators = [], []
                separators.append(piece.strip("\n") or "\n")
            else:
                current.append(piece)
    if current:
        stream.append((tuple(separators), current))
        separators = []
    if separators:
        stream.append((tuple(separators), []))  # trailing separators close groups: keep them, with no command
    return stream


def command_segments(text: str) -> list[list[str]]:
    return [segment for _separators, segment in command_stream(text) if segment]


_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
_SOURCERS = {"source", "."}
# Words that run the command they are given: the script after them is executed.
_WRAPPERS = {
    "env", "sudo", "time", "nohup", "exec", "xvfb-run", "dbus-run-session", "timeout", "nice", "ionice", "stdbuf",
    "setsid", "unbuffer",
}
# `docker run ... IMAGE python3 script`: the options and the image have unknown arity, so these chains are only "may".
_CONTAINERS = {"docker", "podman", "nerdctl"}
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


def _first_word(segment: Sequence[str]) -> int:
    """Index of the first word that is neither a keyword nor an assignment, or len(segment)."""
    cursor = 0
    while cursor < len(segment) and (segment[cursor] in _KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", segment[cursor])):
        cursor += 1
    return cursor


def _chain(segment: Sequence[str], index: int) -> str:
    """How the token at [index] is reached: "yes" (it is run), "may" (it might be) or "no" (it is only mentioned).

    The segment must start with an executor, and every word between the start and
    the token must be part of a launcher chain, so `echo use bash tools/build.sh`,
    `grep`, `git commit -m x ...` and `command -v` mention a script without
    running it. Walking from the head:

    - an interpreter (`bash`, `python`) takes its flags, and then a program; if that
      program is the token the script runs (unless a flag such as `-n` or `-c`
      stops it); if it is another repository script, that script may pass the
      rest of the line on after a `--`;
    - a wrapper (`env`, `timeout`, `xvfb-run`) takes options, counts and
      assignments, and the next word must itself be an executor: if it is not, or
      its option arity is unknown, the answer is "may", never "yes";
    - a container launcher (`docker run ...`) has options and an image of unknown
      arity: always "may";
    - a repository script as the command passes on only what follows a `--`.
    """
    cursor = _first_word(segment)
    if cursor >= index:
        return "yes" if cursor == index else "no"
    after_wrapper = False
    while cursor < index:
        word = segment[cursor]
        name = word.rsplit("/", 1)[-1]
        if _interpreter(word):
            flags = []
            cursor += 1
            while cursor < index and (segment[cursor].startswith("-") or _takes_value(segment, cursor)):
                flags.append(segment[cursor])
                cursor += 1
            if cursor == index:
                return "no" if _NOT_RUNNING_FLAGS.intersection(flags) else "yes"
            if not _PATH.match(segment[cursor]):
                return "may" if after_wrapper else "no"
            after_wrapper = False
            continue  # a repository script now heads the chain
        if name in _WRAPPERS:
            cursor += 1
            while cursor < index and _skippable(segment[cursor]):
                cursor += 1
            if cursor == index:
                return "yes"
            after_wrapper = True  # the next word must itself be an executor, or the answer below is "may"
            continue
        if name in _CONTAINERS:
            return "may"
        if _PATH.match(word):
            try:
                cursor = segment.index("--", cursor + 1, index) + 1
            except ValueError:
                return "no"
            cursor = _skip_to_command(segment, cursor, index)
            after_wrapper = False
            continue
        return "may" if after_wrapper else "no"
    return "yes"


def _skip_to_command(segment: Sequence[str], cursor: int, index: int) -> int:
    while cursor < index and (segment[cursor] in _KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", segment[cursor])):
        cursor += 1
    return cursor


_OPENERS = {"if", "case", "for", "while", "until", "select"}
_CLOSERS = {"fi", "esac", "done"}
_AND_OR = ("&&", "||")
_AFTER_KEYWORD = {"then", "else", "do", "!", "time"}  # `else if`, `then if`, `do while` open a block too
_ENDS = {"exit", "exec"}  # a top-level exit or exec ends the text for every later command
_PIPES = ("|", "|&")


def _unconditional(stream: Sequence[tuple[tuple[str, ...], list[str]]]) -> list[bool]:
    """For each command: is it a top-level unconditional simple command of the text?

    It is not when it sits in an `if`/`case`/loop, a function body, a subshell or
    a group that is itself conditional (an and-or operand, or a function), when it
    belongs to an and-or list (`a && b`, `a || b`), or when a top-level `exit`
    came before it. Nothing is ever dropped: this only decides how much a call
    proves, and shell control flow is not evaluated.
    """
    events: list[tuple[str, int | str]] = []
    for index, (separators, segment) in enumerate(stream):
        events.extend(("sep", separator) for separator in separators)
        if segment:
            events.append(("seg", index))

    # For every event: is one of the operators among the run of consecutive separators right before it (or right
    # after it)? `a &&\n b` has a newline right before `b` and the `&&` one separator further. Computed in one pass
    # each way, so a long run of separators is never rescanned.
    def runs(operators: tuple[str, ...]) -> tuple[list[bool], list[bool]]:
        before, after = [False] * len(events), [False] * len(events)
        flag = False
        for position, (kind, value) in enumerate(events):
            before[position] = flag
            flag = (flag or value in operators) if kind == "sep" else False
        flag = False
        for position in range(len(events) - 1, -1, -1):
            after[position] = flag
            kind, value = events[position]
            flag = (flag or value in operators) if kind == "sep" else False
        return before, after

    and_or_before, and_or_after = runs(_AND_OR)
    pipe_before, pipe_after = runs(_PIPES)

    stack: list[tuple[str, int]] = []
    conditional_group: dict[int, bool] = {}
    closing: set[int] = set()
    for position, (kind, value) in enumerate(events):
        if kind != "sep":
            continue
        if value in ("{", "("):
            stack.append((str(value), position))
            if len(stack) > MAX_GROUP_DEPTH:
                return [False] * len(stream)  # nesting this deep is not a shell script worth classifying: all may_call
        elif value in ("}", ")") and stack and stack[-1][0] == ("{" if value == "}" else "("):
            opener, start = stack.pop()
            before = events[start - 1] if start else None
            function = bool(
                (start >= 2 and before == ("sep", ")") and events[start - 2] == ("sep", "("))
                or (before is not None and before[0] == "seg" and (stream[int(before[1])][1][-1] == "()" or stream[int(before[1])][1][0] == "function"))
            )
            conditional_group[start] = opener == "(" or function or and_or_before[start] or and_or_after[position]
            closing.add(position)
    open_flags: list[bool] = []
    conditional_open = 0  # how many of the open groups are conditional: a counter, not a rescan of the stack
    blocks = 0
    reliable = True  # False once the block nesting can no longer be trusted: everything after is may_call
    after_exit = False
    result = [False] * len(stream)
    for position, (kind, value) in enumerate(events):
        if kind == "sep":
            if position in conditional_group:
                open_flags.append(conditional_group[position])
                conditional_open += conditional_group[position]
            elif position in closing and open_flags:
                conditional_open -= open_flags.pop()
            continue
        segment = stream[int(value)][1]
        head = segment[0]
        if head in _CLOSERS:
            if blocks == 0:
                reliable = False  # a fi, done or esac nothing opened
            else:
                blocks -= 1
        opened = sum(1 for index, word in enumerate(segment) if word in _OPENERS and (index == 0 or segment[index - 1] in _AFTER_KEYWORD))
        in_list = and_or_before[position] or and_or_after[position]
        piped = pipe_before[position] or pipe_after[position]
        conditional = blocks > 0 or conditional_open > 0 or opened > 0 or in_list
        result[int(value)] = reliable and not conditional and not after_exit
        if head in _ENDS and not conditional and not piped:
            after_exit = True
        blocks += opened
    return result


MAX_GROUP_DEPTH = 64  # groups nested deeper than this make the whole text may_call
CHAIN_LIMIT = 512  # a token further into one command than this is only "may": walking back to the head would be quadratic
ARGUMENT_LIMIT = 64  # tokens kept after a call: enough for --stage, --suite, --platform and --build-only
# Appended when a call's arguments were cut: whatever the discarded tokens said, the discriminators are no longer known.
_TRUNCATED = ("--stage=$TRUNCATED", "--suite=$TRUNCATED", "--platform=$TRUNCATED", "--build-only")


def _arguments(segment: Sequence[str], index: int) -> tuple[str, ...]:
    rest = segment[index + 1 : index + 2 + ARGUMENT_LIMIT]
    return tuple(rest[:ARGUMENT_LIMIT]) + (_TRUNCATED if len(rest) > ARGUMENT_LIMIT else ())


def calls_in(text: str, limit: int | None = None) -> list[tuple[str, tuple[str, ...], bool]]:
    """(script, arguments after it, exact) for each repository script a command executes.

    Two tiers, and nothing is dropped. A call is exact only when it is a top-level
    unconditional simple command of the text. Every other call in an executing
    position (inside a conditional, an and-or list, a function or subshell, or
    after a top-level `exit`) is reported with exact False, i.e. as `may_call`.
    At most [limit] + 1 calls are returned, so a caller with a budget stops early;
    the arguments kept after a call are the first `ARGUMENT_LIMIT` tokens.
    """
    stream = command_stream(text)
    eligible = _unconditional(stream)
    found: list[tuple[str, tuple[str, ...], bool]] = []
    for (_separators, segment), exact in zip(stream, eligible, strict=True):
        for index, token in enumerate(segment):
            path = _PATH.match(token)
            if path and ".." not in path.group(1).split("/"):
                reached = _chain(segment, index) if index <= CHAIN_LIMIT else "may"
                script = path.group(1)
            elif index and segment[index - 1] == "-m" and _MODULE.match(token):
                reached = _chain(segment, index - 1) if index <= CHAIN_LIMIT else "may"
                script = token.replace(".", "/") + ".py"
            else:
                continue
            if reached != "no":
                found.append((script, _arguments(segment, index), exact and reached == "yes"))
            if limit is not None and len(found) > limit:
                return found
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


MAX_TOTAL_BYTES = 4 * 1024 * 1024  # text lexed in one run of the guard, steps and scripts together

ScriptCalls = tuple[list[tuple[str, tuple[str, ...]]], list[tuple[str, tuple[str, ...]]], str | None]


def _lex_script(path: Path, script: str) -> tuple[ScriptCalls, int]:
    """(calls of the script's own text, calls of its shell-fed heredocs, problem) and the bytes lexed."""
    text, problem = _read_script(path)
    if problem or text is None:
        return ([], [], f"{script} {problem} (wiring unverified)"), 0
    main, bodies = split_heredocs(text)
    own = [(name, args) for name, args, _exact in calls_in(main, MAX_CALLS_PER_STEP)]
    fed = [(name, args) for body in bodies for name, args, _exact in calls_in(body, MAX_CALLS_PER_STEP)]
    if len(own) + len(fed) > MAX_CALLS_PER_STEP:
        return ([], [], f"{script} makes more than {MAX_CALLS_PER_STEP} calls; the analysis stopped (wiring unverified)"), len(text)
    return (own, fed, None), len(text)


def collect(runs: Sequence[Run], root: Path = ROOT) -> tuple[list[Call], list[str]]:
    """Calls made by workflow steps, and by the repository shell scripts those steps call.

    Script-mediated calls are over-approximated, not evaluated: every command in
    a called script counts, whatever branch, loop or function it is in. A script
    is lexed once per run of the guard however many steps reach it, each step
    reads it at most once, and a total byte budget bounds all lexing. Returns the
    calls and the problems for any cap or budget that was hit.
    """
    calls: list[Call] = []
    problems: list[str] = []
    budget = MAX_TOTAL_BYTES
    cache: dict[str, ScriptCalls] = {}
    reported: set[str] = set()
    for run in runs:
        budget -= len(run.text)
        if budget < 0:
            problems.append(f"the analysis budget of {MAX_TOTAL_BYTES} bytes was exhausted before {run.job}: step {run.step!r}; later steps were not read (wiring unverified)")
            break
        found = 0
        scripts: set[str] = set()
        main, bodies = split_heredocs(run.text)
        # Only a step's own text can prove a call exact; a script and a heredoc fed to a shell are over-approximated.
        queue: deque[tuple[list[tuple[str, tuple[str, ...], bool]], str | None]] = deque(
            [(calls_in(main, MAX_CALLS_PER_STEP), None)]
            + [(calls_in(body, MAX_CALLS_PER_STEP), "<heredoc>") for body in bodies]
        )
        while queue:
            batch, via = queue.popleft()
            for script, args, exact in batch:
                if found >= MAX_CALLS_PER_STEP:
                    problems.append(f"{run.job}: step {run.step!r} makes more than {MAX_CALLS_PER_STEP} calls; the analysis stopped (wiring unverified)")
                    queue.clear()
                    break
                found += 1
                calls.append(Call(run.job, run.step, script, args, via, exact and via is None and run.exact_allowed, run.platform))
                if not script.endswith(".sh") or script in scripts or not (root / script).is_file():
                    continue
                if len(scripts) >= MAX_SCRIPTS_PER_STEP:
                    problems.append(f"{run.job}: step {run.step!r} reaches more than {MAX_SCRIPTS_PER_STEP} scripts; the analysis stopped (wiring unverified)")
                    queue.clear()
                    break
                scripts.add(script)
                if script not in cache:
                    cache[script], lexed = _lex_script(root / script, script)
                    budget -= lexed
                own, fed, problem = cache[script]
                if problem:
                    if script not in reported:  # a script that cannot be read is one problem, not one per step
                        reported.add(script)
                        problems.append(f"{run.job}: step {run.step!r}: {problem}")
                    continue
                queue.append(([(name, arguments, False) for name, arguments in own], script))
                queue.append(([(name, arguments, False) for name, arguments in fed], "<heredoc>"))
        if budget < 0:
            problems.append(f"the analysis budget of {MAX_TOTAL_BYTES} bytes was exhausted while reading scripts for {run.job}: step {run.step!r} (wiring unverified)")
            break
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
                continue  # build.sh defaults to --stage all, which runs every stage
            return None
        if wanted[0] in given or (script == "tools/build.sh" and "all" in given):
            continue
        if any("$" in value for value in given):
            result = "ambiguous"
            continue
        return None
    wanted_platform = next((argv[i + 1] for i, word in enumerate(argv[:-1]) if word == "--platform" and not argv[i + 1].startswith("{")), None)
    if wanted_platform is not None:  # a gate that states its platform is satisfied only by a call for it
        given_platform = _flag_values(call.args, "--platform")
        if given_platform:
            if wanted_platform not in given_platform:
                if not any("$" in value for value in given_platform):
                    return None
                result = "ambiguous"
            elif call.platform in PLATFORM_NAMES and call.platform != wanted_platform:
                result = "ambiguous"  # the flag names this platform, the runner another
        elif call.platform is None:
            result = "ambiguous"
        elif call.platform != wanted_platform:
            return None
    return result


def _wants_platform(argv: Sequence[str]) -> bool:
    """Whether the gate runs once per platform: its argv passes `--platform {platform}`."""
    return any(word == "--platform" and index + 1 < len(argv) and argv[index + 1] == "{platform}" for index, word in enumerate(argv))


def _call_platform(call: Call) -> tuple[str | None, bool]:
    """(the platform a call is for, whether its flag and its runner disagree).

    The platform is the literal `--platform`, else the job's runner. When both are
    known and differ, the call proves nothing for either platform.
    """
    values = _flag_values(call.args, "--platform")
    if values:
        flag = values[0] if "$" not in values[0] else None  # a literal platform (even an unknown one) or a variable
        return flag, flag in PLATFORM_NAMES and call.platform in PLATFORM_NAMES and flag != call.platform
    return call.platform, False


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
        platform_aware = _wants_platform(gate["argv"])
        platforms: list[str | None] = list(gate.get("platforms") or ()) if platform_aware else [None]
        # platform -> label -> whether some call under that label is exact for that platform
        evidence: dict[str | None, dict[str, bool]] = {platform: {} for platform in platforms}
        reached_by: set[str] = set()
        for call in calls:
            for script in scripts:
                kind = satisfies(call, script, gate["argv"])
                if not kind:
                    continue
                label = call.where + (f" via {call.via}" if call.via else "")
                reached_by.add(call.where)
                own, conflict = _call_platform(call) if platform_aware else (None, False)
                if conflict:
                    own = None  # the flag says one platform and the runner another: evidence for neither
                for platform in platforms:
                    if platform_aware and own not in (None, platform):
                        continue  # a call for another platform
                    certain = kind == "exact" and call.exact and (own == platform)
                    evidence[platform][label] = evidence[platform].get(label, False) or certain
        called_by = sorted({label for labels in evidence.values() for label, certain in labels.items() if certain})
        may_call = sorted({label for labels in evidence.values() for label in labels} - set(called_by))
        local_only = gate.get("local_only")
        no_exact = [str(platform) for platform, labels in evidence.items() if labels and not any(labels.values())]
        missing = [str(platform) for platform, labels in evidence.items() if not labels]
        unverified = local_only is None and not missing and bool(no_exact)
        declared = gate.get("wiring_unverified_reason")
        relies_on = gate.get("wiring_unverified_relies_on")
        gates[name] = {
            "scripts": scripts, "called_by": called_by, "may_call": may_call, "platforms": [str(p) for p in platforms if p],
            "verified_platforms": [str(platform) for platform, labels in evidence.items() if platform and any(labels.values())],
            "wiring_unverified": unverified, "unverified_platforms": no_exact if unverified else [],
            "local_only": local_only, "declared_unverified": declared, "reached_by": sorted(reached_by),
        }
        if declared is not None and (not isinstance(declared, str) or not declared.strip()):
            problems.append(f"gate {name}: wiring_unverified_reason needs a reason")
        elif declared is not None and not unverified:
            problems.append(f"gate {name}: declared wiring_unverified_reason but it now has direct evidence or none; remove the stale declaration")
        elif declared is not None and (not isinstance(relies_on, list) or not relies_on or not all(isinstance(item, str) for item in relies_on)):
            problems.append(f"gate {name}: wiring_unverified_reason needs wiring_unverified_relies_on, the workflow:job entries it rests on")
        elif declared is not None and (gone := [item for item in relies_on if item not in reached_by]):
            problems.append(f"gate {name}: wiring_unverified_reason relies on {gone[0]}, which no longer reaches it; revisit the acknowledgement")
        elif unverified and declared is None:
            where = f" on {', '.join(no_exact)}" if platform_aware else ""
            problems.append(f"gate {name}: no step calls it as a top-level command{where} ({may_call[0]}); call it directly or declare wiring_unverified_reason")
        if local_only is not None and (not isinstance(local_only, str) or not local_only.strip()):
            problems.append(f"gate {name}: local_only needs a reason")
        elif local_only is not None and called_by:
            problems.append(f"gate {name}: declared local_only but {called_by[0]} calls it; remove the stale declaration")
        elif local_only is None and missing:
            detail = " ".join(gate["argv"][1:] if gate["argv"][0] in ("bash", "{python}") else gate["argv"])
            on = f" for {', '.join(missing)}" if platform_aware else ""
            problems.append(f"gate {name}: no workflow step calls `{detail}`{on}; wire it or declare local_only with a reason")
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
