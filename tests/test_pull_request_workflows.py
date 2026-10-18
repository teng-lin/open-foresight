"""Pull-request workflows must run the shipped package, acceptance, and offline suites."""

import ast
import json
import re
import shlex
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"


def _strip_comment(line):
    out = []
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if quote == "'" and i + 1 < len(line) and line[i + 1] == "'":
                out.append(line[i + 1])
                i += 2
                continue
            if ch == "\\" and quote == '"' and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "#":
            break
        out.append(ch)
        i += 1
    return "".join(out).rstrip()


def _unquote(text):
    quote = text[0]
    inner = text[1:-1]
    if quote == "'":
        return inner.replace("''", "'")
    escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"'}
    out = []
    i = 0
    while i < len(inner):
        if inner[i] == "\\" and i + 1 < len(inner):
            out.append(escapes.get(inner[i + 1], inner[i + 1]))
            i += 2
        else:
            out.append(inner[i])
            i += 1
    return "".join(out)


def _split_top(text, sep=","):
    parts, buf, quote, depth = [], [], None, 0
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            buf.append(ch)
            if quote == "'" and i + 1 < len(text) and text[i + 1] == "'":
                buf.append(text[i + 1])
                i += 2
                continue
            if ch == "\\" and quote == '"' and i + 1 < len(text):
                buf.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch in "[{":
            depth += 1
            buf.append(ch)
        elif ch in "]}":
            depth = max(0, depth - 1)
            buf.append(ch)
        elif ch == sep and depth == 0:
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail or parts:
        parts.append(tail)
    return [part for part in parts if part != ""]


def _split_key(text):
    if text[:1] in "'\"":
        quote = text[0]
        i = 1
        while i < len(text):
            if (
                quote == "'"
                and text[i] == "'"
                and i + 1 < len(text)
                and text[i + 1] == "'"
            ):
                i += 2
                continue
            if quote == '"' and text[i] == "\\" and i + 1 < len(text):
                i += 2
                continue
            if text[i] == quote:
                break
            i += 1
        else:
            return None
        rest = text[i + 1 :]
        if not rest.startswith(":"):
            return None
        return _unquote(text[: i + 1]), rest[1:].lstrip(" ")
    for i, ch in enumerate(text):
        if ch == ":" and (i + 1 == len(text) or text[i + 1] == " "):
            if i == 0:
                return None
            return text[:i], text[i + 1 :].lstrip(" ")
    return None


def _parse_scalar(text):
    text = text.strip()
    if text in ("", "null", "~"):
        return None
    if text == "true":
        return True
    if text == "false":
        return False
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return _unquote(text)
    if re.fullmatch(r"-?(0|[1-9]\d*)", text):
        return int(text)
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        return [] if not inner else [_parse_scalar(part) for part in _split_top(inner)]
    if text.startswith("{") and text.endswith("}"):
        inner = text[1:-1].strip()
        if not inner:
            return {}
        mapping = {}
        for part in _split_top(inner):
            split = _split_key(part)
            if split is None:
                raise ValueError("bad flow mapping: " + part)
            mapping[split[0]] = _parse_scalar(split[1])
        return mapping
    return text


class _Parser:
    def __init__(self, text):
        self.lines = text.splitlines()
        self.i = 0

    def parse(self):
        value = self._node(-1)
        if self._peek() is not None:
            line, _, text = self._peek()
            raise ValueError(f"unparsed workflow content at line {line + 1}: {text}")
        return {} if value is None else value

    def _peek(self):
        j = self.i
        while j < len(self.lines):
            content = _strip_comment(self.lines[j])
            if content.strip():
                indent = len(content) - len(content.lstrip(" "))
                return j, indent, content.lstrip(" ")
            j += 1
        return None

    def _node(self, parent):
        peeked = self._peek()
        if peeked is None:
            return None
        _, indent, text = peeked
        if indent <= parent:
            return None
        if text.startswith("- ") or text == "-":
            return self._sequence(indent)
        return self._mapping(indent)

    def _mapping(self, indent):
        mapping = {}
        self._fill_mapping(mapping, indent)
        return mapping

    def _fill_mapping(self, mapping, indent):
        while True:
            peeked = self._peek()
            if peeked is None:
                return
            line, line_indent, text = peeked
            if line_indent != indent or text.startswith("- ") or text == "-":
                return
            split = _split_key(text)
            if split is None:
                raise ValueError(f"expected a mapping key at line {line + 1}: {text}")
            self.i = line + 1
            mapping[split[0]] = self._value(split[1], line_indent)

    def _sequence(self, indent):
        items = []
        while True:
            peeked = self._peek()
            if peeked is None:
                return items
            line, line_indent, text = peeked
            if line_indent != indent or not (text.startswith("- ") or text == "-"):
                return items
            self.i = line + 1
            if text == "-":
                items.append(self._node(indent))
                continue
            rest = text[2:]
            column = line_indent + 2
            split = _split_key(rest)
            if split is None:
                items.append(_parse_scalar(rest))
                continue
            mapping = {split[0]: self._value(split[1], column)}
            self._fill_mapping(mapping, column)
            items.append(mapping)
        return items

    def _value(self, raw, key_indent):
        raw = raw.strip()
        if raw == "":
            peeked = self._peek()
            if peeked is None:
                return None
            _, indent, text = peeked
            if (text.startswith("- ") or text == "-") and indent >= key_indent:
                return self._sequence(indent)
            if indent > key_indent:
                return self._node(key_indent)
            return None
        if raw.startswith("|") or raw.startswith(">"):
            return self._block(raw, key_indent)
        if raw[:1] in "[{'\"":
            return _parse_scalar(raw)
        # A more-indented following line continues a plain scalar (joined with a space).
        parts = [raw]
        while True:
            peeked = self._peek()
            if peeked is None:
                break
            line, indent, text = peeked
            if indent <= key_indent:
                break
            self.i = line + 1
            parts.append(text)
        return _parse_scalar(" ".join(parts))

    def _block(self, indicator, key_indent):
        chomp = "strip" if "-" in indicator else "keep" if "+" in indicator else "clip"
        lines = []
        content_indent = None
        while self.i < len(self.lines):
            line = self.lines[self.i]
            if line.strip() == "":
                lines.append("")
                self.i += 1
                continue
            indent = len(line) - len(line.lstrip(" "))
            if content_indent is None:
                if indent <= key_indent:
                    break
                content_indent = indent
            elif indent < content_indent:
                break
            lines.append(line[content_indent:])
            self.i += 1
        text = "\n".join(lines).rstrip("\n")
        if chomp == "strip" or text == "":
            return text
        return text + "\n"


def parse_workflow(text):
    return _Parser(text).parse()


def _allows_pull_request(job):
    condition = job.get("if")
    if not isinstance(condition, str):
        return True
    return "!= 'pull_request'" not in condition and '!= "pull_request"' not in condition


def _linux_job(job):
    runs_on = job.get("runs-on") or ""
    if isinstance(runs_on, list):
        runs_on = " ".join(str(item) for item in runs_on)
    container = job.get("container") or ""
    if isinstance(container, dict):
        container = container.get("image") or ""
    text = f"{runs_on} {container}"
    return "ubuntu" in text or "linux" in text


class PullRequestWorkflowTests(unittest.TestCase):
    def workflow(self, name):
        return parse_workflow((WORKFLOWS / name).read_text())

    def test_parser_reads_compact_sequences_blocks_and_triggers(self):
        sample = parse_workflow("""
name: Sample
on:
  pull_request:
    paths:
    - apps/desktop/**
    - 'packages/foresight_core/lib/**'
  workflow_dispatch:
jobs:
  linux:
    runs-on: ubuntu-24.04
    if: github.event_name == 'pull_request'
    steps:
    - name: Build
      run: |
        echo packaging/build.Dockerfile
        echo packaging/ci/package-and-test.sh deb
      with:
        file: packaging/build.Dockerfile
""")
        self.assertEqual(sample["name"], "Sample")
        self.assertEqual(
            sample["on"]["pull_request"]["paths"],
            ["apps/desktop/**", "packages/foresight_core/lib/**"],
        )
        self.assertIsNone(sample["on"]["workflow_dispatch"])
        step = sample["jobs"]["linux"]["steps"][0]
        self.assertIn("packaging/ci/package-and-test.sh", step["run"])
        self.assertEqual(step["with"]["file"], "packaging/build.Dockerfile")
        self.assertEqual(sample["jobs"]["linux"]["runs-on"], "ubuntu-24.04")

    def test_ubuntu_package_job_builds_and_installs_on_scoped_pull_requests(self):
        workflow = self.workflow("linux-packages.yml")
        paths = workflow["on"]["pull_request"]["paths"]
        for required in (
            "apps/desktop/**",
            "packages/foresight_core/**",
            "packaging/**",
            ".github/workflows/linux-packages.yml",
        ):
            self.assertIn(required, paths)
        matches = []
        for name, job in workflow["jobs"].items():
            if not _allows_pull_request(job) or job.get("runs-on") != "ubuntu-24.04":
                continue
            blob = json.dumps(job)
            if (
                "packaging/build.Dockerfile" in blob
                and "packaging/ci/package-and-test.sh" in blob
                and "ubuntu:24.04" in blob
                and re.search(r"\bdeb\b", blob)
            ):
                for step in job["steps"]:
                    self.assertIsNot(step.get("continue-on-error"), True)
                matches.append(name)
        self.assertEqual(matches, ["ubuntu-package"])
        self.assertIn("pull_request", workflow["jobs"]["ubuntu-package"]["if"])

    def test_acceptance_paths_include_product_sources_and_meeting_workflow(self):
        workflow = self.workflow("integration-acceptance.yml")
        self.assertNotIn("paths", workflow["on"].get("pull_request") or {})
        from tools.ci_changes import select_gates

        self.assertEqual(workflow["jobs"]["linux"]["needs"], "changes")
        self.assertEqual(workflow["jobs"]["acceptance-checks"]["if"], "always()")
        for path in (
            "apps/desktop/lib/main.dart",
            "packages/foresight_core/lib/src/application.dart",
            "packaging/build.Dockerfile",
            "native/foresight_native.cpp",
        ):
            self.assertTrue(select_gates([path])["linux-bundle"])
        self.assertFalse(select_gates(["docs/README.md"])["linux-bundle"])
        runs = [
            step.get("run")
            for step in workflow["jobs"]["linux"]["steps"]
            if isinstance(step.get("run"), str)
        ]
        combined = "\n".join(runs)
        self.assertNotIn("tools/test_meeting_workflow.py", combined)
        self.assertIn("--suite virtual-audio", combined)
        self.assertIn("--suite models", combined)
        source = (ROOT / "tools/integration_gates.py").read_text()
        audio = source[
            source.index("def audio_gate") : source.index(
                "\ndef ", source.index("def audio_gate") + 1
            )
        ]
        self.assertIn("integration_test/meeting_workflow_test.dart", audio)
        function = next(
            node
            for node in ast.parse(source).body
            if isinstance(node, ast.FunctionDef) and node.name == "audio_gate"
        )
        self.assertTrue(
            any(
                isinstance(node, ast.keyword)
                and node.arg == "FORESIGHT_PRIVATE_PIPEWIRE"
                and isinstance(node.value, ast.Constant)
                and node.value.value == "1"
                for node in ast.walk(function)
            )
        )

    def test_platform_selection_is_wired_per_job_and_enforced_by_aggregate(self):
        workflow = self.workflow("macos.yml")
        jobs = workflow["jobs"]
        for name in ("macos", "linux-native", "linux-document-imports", "linux-bundle"):
            output = name.replace("-", "_")
            self.assertEqual(
                jobs["changes"]["outputs"][output],
                "${{ steps.changes.outputs." + output + " }}",
            )
            self.assertIn(
                "needs.changes.outputs." + output + " == 'true'", jobs[name]["if"]
            )
            self.assertIn(name, jobs["platform-checks"]["needs"])
        step = jobs["platform-checks"]["steps"][-1]
        self.assertEqual(
            step["env"]["SELECTION"], "${{ needs.changes.outputs.selection }}"
        )
        self.assertIn("--check-gates", step["run"])
        self.assertIn(
            "--force",
            next(
                step for step in jobs["changes"]["steps"] if step.get("id") == "changes"
            )["env"]["FORCE"],
        )

    def test_maintenance_has_offline_tests_without_a_platform_build(self):
        workflow = self.workflow("quality.yml")
        runs = [step.get("run", "") for step in workflow["jobs"]["python"]["steps"]]
        self.assertTrue(any(run.startswith("python -m pytest --cov ") for run in runs))
        install = next(run for run in runs if "protoc-35.1-linux-x86_64.zip" in run)
        reference = next(
            step["run"]
            for step in self.workflow("rpc-contracts.yml")["jobs"]["contracts"]["steps"]
            if step.get("name") == "Install pinned protobuf toolchain"
        )
        self.assertEqual(
            re.findall(r"https://\S*protoc-35\.1-linux-x86_64\.zip", install),
            re.findall(r"https://\S*protoc-35\.1-linux-x86_64\.zip", reference),
        )
        self.assertEqual(
            re.findall(r"\b[a-f0-9]{64}\b", install),
            re.findall(r"\b[a-f0-9]{64}\b", reference),
        )
        self.assertIn("sha256sum --check", install)
        self.assertIn('>> "$GITHUB_PATH"', install)
        self.assertIn("--version", install)
        self.assertLess(
            runs.index(install),
            next(
                index
                for index, run in enumerate(runs)
                if run.startswith("python -m pytest --cov ")
            ),
        )

    def test_registry_aliases_are_isolated_from_dependency_builds(self):
        workflow = self.workflow("linux-registry.yml")
        self.assertNotIn("pull_request", workflow["on"])
        self.assertEqual(workflow["on"]["workflow_run"]["branches"], ["main"])
        job = workflow["jobs"]["aliases"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertIn("conclusion == 'success'", job["if"])
        self.assertIn("head_repository.full_name == github.repository", job["if"])
        self.assertEqual(job["steps"][0]["with"]["ref"], "main")
        self.assertIn("publish_linux_package_aliases.py", job["steps"][-1]["run"])
        dependency = self.workflow("ci-dependencies.yml")
        self.assertNotIn("Publish readable current alias", json.dumps(dependency))

    def test_linux_pull_request_runs_offline_pytest(self):
        workflow = self.workflow("macos.yml")
        self.assertIn("pull_request", workflow["on"])
        found = []
        for name, job in workflow["jobs"].items():
            if not _linux_job(job):
                continue
            for step in job.get("steps") or []:
                if re.search(r"(^|\s)pytest(\s|$)", step.get("run") or ""):
                    found.append(name)
        self.assertIn("linux-native", found)

    def test_linux_sdk_consumers_forward_their_own_pull_request_context(self):
        consumers = set()
        for filename in (
            "integration-acceptance.yml",
            "linux-packages.yml",
            "macos.yml",
        ):
            for name, job in self.workflow(filename)["jobs"].items():
                for step in job.get("steps") or []:
                    for line in step.get("run", "").splitlines():
                        if "ci_artifacts.py pull --component linux-sdk" not in line:
                            continue
                        with self.subTest(workflow=filename, job=name):
                            lexer = shlex.shlex(line, posix=True, punctuation_chars=";")
                            lexer.whitespace_split = True
                            arguments = list(lexer)
                            for flag, variable in (
                                ("--own-head", "$OWN_HEAD"),
                                ("--own-pr", "$OWN_PR"),
                            ):
                                self.assertIn(flag, arguments)
                                self.assertEqual(
                                    arguments[arguments.index(flag) + 1], variable
                                )
                            self.assertEqual(
                                step["env"]["OWN_HEAD"],
                                "${{ github.event.pull_request.head.sha || github.sha }}",
                            )
                            self.assertEqual(
                                step["env"]["OWN_PR"],
                                "${{ github.event.pull_request.number || 0 }}",
                            )
                            consumers.add((filename, name))
        self.assertEqual(
            consumers,
            {
                ("integration-acceptance.yml", "linux"),
                ("linux-packages.yml", "ubuntu-package"),
                ("macos.yml", "linux-bundle"),
            },
        )


if __name__ == "__main__":
    unittest.main()


def test_release_latest_and_push_concurrency_are_explicit():
    release = (WORKFLOWS / "release.yml").read_text()
    assert 'tools/release_latest.py --tag "$TAG"' in release
    assert '--latest="$latest"' in release
    assert not re.search(r"--latest(?:\s|$)", release)
    for name in ("quality.yml", "integration-acceptance.yml"):
        assert (
            "github.event_name == 'pull_request' && github.ref || github.sha"
            in (WORKFLOWS / name).read_text()
        )
    package = (WORKFLOWS / "linux-packages.yml").read_text()
    for required in (
        "native/**",
        "services/**",
        "proto/**",
        "cmake/**",
        "CMakeLists.txt",
        "third_party/**",
        "tools/package.py",
        "tools/build.sh",
        "requirements-*.lock",
    ):
        assert required in package


def test_installers_have_pinned_attestations_and_job_scoped_permissions():
    for name, job in (("linux-packages.yml", "packages"), ("macos-release.yml", "dmg")):
        workflow = parse_workflow((WORKFLOWS / name).read_text())
        permissions = workflow["jobs"][job]["permissions"]
        assert permissions["id-token"] == "write"
        assert permissions["attestations"] == "write"
        assert "id-token" not in workflow.get("permissions", {})
        steps = workflow["jobs"][job]["steps"]
        for action in (
            "anchore/sbom-action",
            "actions/attest-build-provenance",
            "actions/attest-sbom",
        ):
            uses = [
                step["uses"]
                for step in steps
                if step.get("uses", "").startswith(action + "@")
            ]
            assert len(uses) == 1 and re.fullmatch(
                re.escape(action) + r"@[0-9a-f]{40}", uses[0]
            )


def test_candidate_dispatch_has_unique_display_name_and_concurrency_identity():
    workflow = parse_workflow((WORKFLOWS / "macos.yml").read_text())
    assert "request_id" in workflow["on"]["workflow_dispatch"]["inputs"]
    assert "Release candidate {0}" in workflow["run-name"]
    assert "inputs.request_id" in workflow["run-name"]
    assert "inputs.request_id" in workflow["concurrency"]["group"]
    for name in ("macos-release.yml", "preview-packages.yml"):
        assert "tools/create_dmg.py" in (WORKFLOWS / name).read_text()


def test_macos_consumer_uses_same_pr_head_as_dependency_producer():
    workflow = parse_workflow((WORKFLOWS / "macos.yml").read_text())
    job = workflow["jobs"]["macos"]
    checkout = next(
        step
        for step in job["steps"]
        if step.get("uses", "").startswith("actions/checkout@")
    )
    assert (
        checkout["with"]["ref"]
        == "${{ inputs.source || github.event.pull_request.head.sha || github.sha }}"
    )
    source = json.dumps(job)
    assert source.count("tools/ci_macos_dependencies.py") == 2
    assert "--wait 5400" not in source


def test_every_non_reusable_job_has_a_finite_timeout():
    for path in WORKFLOWS.glob("*.yml"):
        for name, job in parse_workflow(path.read_text()).get("jobs", {}).items():
            if "uses" not in job:
                assert 0 < job.get("timeout-minutes", 0) <= 300, (path.name, name)


def test_every_flutter_clone_verifies_the_reviewed_framework_commit():
    pins = json.loads((ROOT / "tools/pins.json").read_text())
    for path in WORKFLOWS.glob("*.yml"):
        for job in parse_workflow(path.read_text()).get("jobs", {}).values():
            for step in job.get("steps", []):
                run = step.get("run", "")
                if "flutter/flutter.git" in run:
                    assert pins["flutter"]["version"] in run, path.name
                    assert pins["flutter"]["commit"] in run, path.name
                    assert run.index("flutter/flutter.git") < run.index(
                        pins["flutter"]["commit"]
                    ), path.name


def test_protobuf_plugin_uses_a_locked_local_tool_package():
    workflow = (WORKFLOWS / "rpc-contracts.yml").read_text()
    assert "dart pub global activate" not in workflow
    assert "cd tools/protoc_plugin && dart pub get --enforce-lockfile" in workflow
    assert (ROOT / "tools/protoc_plugin/pubspec.lock").is_file()
