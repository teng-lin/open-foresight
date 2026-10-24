"""Offline links must catch missing paths/fragments without fetching examples."""

from pathlib import Path
import subprocess
import sys

import pytest
import yaml

from tools import check_document_links as checker


def test_inline_reference_html_and_encoded_destinations(tmp_path):
    (tmp_path / "with spaces (1).md").write_text("# Target\n")
    (tmp_path / "picture.png").write_bytes(b"image")
    (tmp_path / "README.md").write_text(
        '[one](with%20spaces%20(1).md#target) '
        '[two](<with spaces (1).md#target> "a title")\n'
        '[named][ref] and [ref][] and [ref]\n\n'
        '[ref]: <with spaces (1).md#target>\n\n'
        '<img src="picture.png">\n'
        '<a href="with%20spaces%20(1).md#target">HTML</a>\n'
        '[remote](https://example.invalid/missing)\n'
    )
    count, problems = checker.check(tmp_path)
    assert not problems
    assert count == 7


def test_missing_path_heading_and_parent_escape_are_actionable(tmp_path):
    (tmp_path / "README.md").write_text(
        "# Existing\n[absent](gone.md) [anchor](#absent)\n"
        "[outside](../outside.md)\n"
    )
    count, problems = checker.check(tmp_path)
    assert count == 3
    assert problems == [
        "README.md:2: 'gone.md': missing path",
        "README.md:2: '#absent': missing heading or anchor",
        "README.md:3: '../outside.md': leaves repository",
    ]


def test_code_examples_and_excluded_vendor_trees_are_not_links(tmp_path):
    (tmp_path / "README.md").write_text(
        "`[inline](absent.md)` and ``[ticks ` example](absent.md)``\n"
        "```markdown\n[example](absent.md)\n```\n"
        "~~~\n[example](absent.md)\n~~~\n"
        "    [indented](absent.md)\n"
    )
    vendor = tmp_path / "third_party"
    vendor.mkdir()
    (vendor / "README.md").write_text("[external source](absent.md)\n")
    assert checker.check(tmp_path) == (0, [])


def test_nested_lists_quotes_and_multiline_reference_definitions_are_checked(tmp_path):
    (tmp_path / "README.md").write_text(
        "- first\n  - nested\n    [link](missing.md)\n\n"
        "> [quoted](other.md)\n\n[reference][target]\n\n[target]:\n  final.md\n"
    )
    count, problems = checker.check(tmp_path)
    assert count == 3
    assert [problem.split(": ")[-1] for problem in problems] == ["missing path"] * 3


def test_github_slugs_duplicate_headings_setext_and_explicit_ids(tmp_path):
    (tmp_path / "README.md").write_text(
        '# Unicode café &amp; `foo<T>`!\n# Same\n# Same\n# Same-1\n'
        'Setext heading\n==============\n<a id="manual"></a>\n'
        '[one](#unicode-café--foot) [two](#same) [three](#same-1) '
        '[four](#same-1-1) [five](#setext-heading) [six](#manual)\n'
    )
    assert checker.check(tmp_path) == (6, [])


def test_links_inside_nested_labels_and_parentheses_keep_both_destinations(tmp_path):
    (tmp_path / "README.md").write_text(
        "[first [nested] label](absent(1).md) and [second](absent2.md)\n"
    )
    count, problems = checker.check(tmp_path)
    assert count == 2
    assert "'absent(1).md'" in problems[0]
    assert "'absent2.md'" in problems[1]


def test_symlink_destination_cannot_leave_export(tmp_path):
    root = tmp_path / "export"
    root.mkdir()
    (tmp_path / "outside.md").write_text("# Outside\n")
    (root / "escape.md").symlink_to(tmp_path / "outside.md")
    (root / "README.md").write_text("[unsafe](escape.md)\n")
    assert checker.check(root)[1] == [
        "README.md:1: 'escape.md': leaves repository"
    ]


def test_git_free_cli_from_unrelated_cwd_fails_then_passes(tmp_path):
    export = tmp_path / "export"
    export.mkdir()
    readme = export / "README.md"
    readme.write_text("[broken](absent.md)\n")
    command = [sys.executable, str(Path(checker.__file__)), "--root", str(export)]
    failed = subprocess.run(command, cwd=tmp_path, capture_output=True,
                            text=True, timeout=10)
    assert failed.returncode == 1, failed.stdout + failed.stderr
    assert "README.md:1" in failed.stdout and "missing path" in failed.stdout
    (export / "absent.md").write_text("# Exists\n")
    passed = subprocess.run(command, cwd=tmp_path, capture_output=True,
                            text=True, timeout=10)
    assert passed.returncode == 0, passed.stdout + passed.stderr
    assert "Checked 1 local links; 0 problems" in passed.stdout


@pytest.mark.parametrize("target,reason", [
    ("file.py#L3", None),
    ("file.py#L3-L9", None),
    ("file.py#L0", "unsupported file fragment"),
    ("file.py#l3", "unsupported file fragment"),
    ("file.py#foo", "unsupported file fragment"),
    ("/sub/a.md#heading", None),
    ("sub#heading", None),
])
def test_repository_paths_and_historical_source_fragments(tmp_path, target, reason):
    (tmp_path / "file.py").write_text("# source\n" * 10)
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "a.md").write_text("# Heading\n")
    (sub / "README.md").write_text("# Heading\n")
    (tmp_path / "README.md").write_text(f"[destination]({target})\n")
    count, problems = checker.check(tmp_path)
    assert count == 1
    if reason is None:
        assert problems == []
    else:
        assert len(problems) == 1 and problems[0].endswith(reason)


def test_named_anchor_boolean_html_attributes_and_invalid_destination(tmp_path):
    (tmp_path / "README.md").write_text(
        '<a name="named"></a><a href></a>\n\n'
        '[named](#named)\n\n<a href="http://[bad">bad URL</a>\n'
    )
    count, problems = checker.check(tmp_path)
    assert count == 1
    assert problems == ["README.md:5: 'http://[bad': invalid destination"]


def test_missing_cli_root_is_failure_instead_of_empty_success(tmp_path):
    result = subprocess.run(
        [sys.executable, str(Path(checker.__file__)), "--root", str(tmp_path / "absent")],
        cwd=tmp_path, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "must be an existing directory" in result.stderr
    assert "0 problems" not in result.stdout


def test_quality_checks_links_after_installing_hash_locked_dependencies():
    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/quality.yml").read_text())
    steps = workflow["jobs"]["python"]["steps"]
    commands = [step.get("run", "") for step in steps]
    install = commands.index("python -m pip install --require-hashes -r requirements-dev.lock")
    links = commands.index("python -m tools.check_document_links")
    assert install < links
    assert "if" not in steps[links]
