from pathlib import Path
import subprocess
import sys

import pytest

from tools import check_migration_integrity as gate


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], text=True, timeout=30
    ).strip()


def write(root, path, content):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)


def commit(root, message):
    git(root, "add", ".")
    git(
        root,
        "-c",
        "user.email=fixture@example.invalid",
        "-c",
        "user.name=Fixture",
        "commit",
        "-m",
        message,
    )
    return git(root, "rev-parse", "HEAD")


@pytest.fixture
def repository(tmp_path, monkeypatch):
    main = tmp_path / "upstream"
    main.mkdir()
    git(main, "init", "-b", "main")
    write(main, gate.CORE / "pubspec.yaml", "fixture: origin\n")
    origin = commit(main, "reviewed original migrations")
    monkeypatch.setattr(gate, "BOOTSTRAP", origin)
    candidate = tmp_path / "candidate"
    git(tmp_path, "clone", str(main), str(candidate))
    write(candidate, gate.CHECKER, "candidate checker\n")
    write(candidate, gate.MANIFEST, "candidate manifest\n")
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    return main, candidate, scratch, origin


def record_dart(monkeypatch):
    commands = []
    real_run = gate.run

    def run(command, *, cwd, timeout=180):
        if command[0] != "fixture-dart":
            return real_run(command, cwd=cwd, timeout=timeout)
        commands.append((command, cwd))
        if command[1] == "run":
            trusted = Path(command[command.index("--trusted-root") + 1])
            assert not (trusted / ".git").exists()
            assert (trusted / gate.CORE / "pubspec.yaml").exists()
        return ""

    monkeypatch.setattr(gate, "run", run)
    return commands


def test_bootstrap_fetches_actual_main_and_proves_frozen_ancestor(
    repository, monkeypatch
):
    main, candidate, scratch, origin = repository
    write(main, "unrelated.txt", "main moved\n")
    actual_main = commit(main, "unrelated main advance")
    # A stale/malicious local tracking main cannot become authority.
    git(candidate, "update-ref", "refs/remotes/origin/main", origin)
    commands = record_dart(monkeypatch)
    result = gate.check(candidate, str(main), "fixture-dart", scratch)
    assert result == {"trusted_main": actual_main, "bootstrap": True, "checker_runs": 1}
    command, cwd = commands[-1]
    assert cwd == candidate / gate.CORE
    assert command[2] == str(candidate / gate.CHECKER)
    assert command[-5:] == [
        "--bootstrap",
        "--bootstrap-root",
        str(scratch / "bootstrap"),
        "--bootstrap-commit",
        origin,
    ]
    assert (scratch / "main/unrelated.txt").read_text() == "main moved\n"
    assert not (scratch / "bootstrap/unrelated.txt").exists()


def test_existing_main_executes_main_checker_with_its_dependencies_first(
    repository, monkeypatch
):
    main, candidate, scratch, _ = repository
    write(main, gate.CHECKER, "trusted checker\n")
    write(main, gate.MANIFEST, "trusted manifest\n")
    actual_main = commit(main, "guard already reviewed and merged")
    commands = record_dart(monkeypatch)
    result = gate.check(candidate, str(main), "fixture-dart", scratch)
    assert result == {
        "trusted_main": actual_main,
        "bootstrap": False,
        "checker_runs": 2,
    }
    assert [cwd for _, cwd in commands] == [scratch / "main" / gate.CORE] * 2 + [
        candidate / gate.CORE
    ] * 2
    first = commands[1][0]
    assert Path(first[2]).read_text() == "trusted checker\n"
    assert "--bootstrap" not in first
    assert commands[0][0] == ["fixture-dart", "pub", "get", "--enforce-lockfile"]
    assert commands[3][0][2] == str(candidate / gate.CHECKER)


def test_nonreachable_bootstrap_fails_before_any_dart(repository, monkeypatch):
    main, candidate, scratch, _ = repository
    git(main, "checkout", "--orphan", "replacement")
    write(main, "unrelated", "different root")
    commit(main, "unrelated history")
    git(main, "branch", "-M", "main")
    commands = record_dart(monkeypatch)
    with pytest.raises(subprocess.CalledProcessError):
        gate.check(candidate, str(main), "fixture-dart", scratch)
    assert commands == []


def test_existing_manifest_without_main_checker_cannot_bootstrap(
    repository, monkeypatch
):
    main, candidate, scratch, _ = repository
    write(main, gate.MANIFEST, "trusted manifest")
    commit(main, "broken reviewed source")
    commands = record_dart(monkeypatch)
    with pytest.raises(ValueError, match="authoritative checker"):
        gate.check(candidate, str(main), "fixture-dart", scratch)
    assert commands == []


def test_authoritative_checker_failure_stops_candidate_checker(repository, monkeypatch):
    main, candidate, scratch, _ = repository
    write(main, gate.CHECKER, "trusted checker")
    write(main, gate.MANIFEST, "trusted manifest")
    commit(main, "guard merged")
    run = gate.run
    seen = []

    def reject(command, *, cwd, timeout=180):
        if command[0] == "fixture-dart":
            seen.append(command)
            if command[1] == "run":
                raise subprocess.CalledProcessError(1, command, "migration changed")
            return ""
        return run(command, cwd=cwd, timeout=timeout)

    monkeypatch.setattr(gate, "run", reject)
    with pytest.raises(subprocess.CalledProcessError):
        gate.check(candidate, str(main), "fixture-dart", scratch)
    assert len(seen) == 2
    assert str(candidate / gate.CHECKER) not in seen[-1]


def test_failure_preserves_captured_output(tmp_path, capsys):
    with pytest.raises(subprocess.CalledProcessError):
        gate.run(
            [
                sys.executable,
                "-c",
                "import sys; print('stdout proof'); print('stderr proof', file=sys.stderr); sys.exit(9)",
            ],
            cwd=tmp_path,
        )
    captured = capsys.readouterr().out
    assert "stdout proof" in captured and "stderr proof" in captured


def test_fetch_must_resolve_a_full_commit(repository, monkeypatch):
    main, candidate, scratch, _ = repository
    actual_run = gate.run

    def broken_ref(command, *, cwd, timeout=180):
        if command[1] == "rev-parse":
            return "main"
        return actual_run(command, cwd=cwd, timeout=timeout)

    monkeypatch.setattr(gate, "run", broken_ref)
    with pytest.raises(ValueError, match="full source commit"):
        gate.check(candidate, str(main), "fixture-dart", scratch)


def test_actual_cli_refuses_missing_platform_repository_before_fetch(monkeypatch):
    monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)
    result = subprocess.run(
        [sys.executable, str(Path(gate.__file__))],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode != 0
    assert "platform-owned repository" in result.stderr


@pytest.mark.parametrize(
    "repository", ["", "../../evil", "owner/repo/extra", "https://evil/repo"]
)
def test_cli_rejects_nonplatform_repository(repository, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", repository)
    monkeypatch.setattr(sys, "argv", ["check_migration_integrity.py"])
    with pytest.raises(ValueError, match="platform-owned repository"):
        gate.main()


def test_cli_uses_platform_repository_and_private_export(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_REPOSITORY", "fixture/reviewed-repo")
    monkeypatch.setattr(
        sys, "argv", ["check_migration_integrity.py", "--dart", "pinned-dart"]
    )
    seen = []

    def check(root, url, dart, scratch):
        assert scratch.is_dir()
        assert oct(scratch.stat().st_mode & 0o777) == "0o700"
        seen.append((root, url, dart, scratch))

    monkeypatch.setattr(gate, "check", check)
    gate.main()
    assert seen[0][:3] == (
        gate.ROOT,
        "https://github.com/fixture/reviewed-repo.git",
        "pinned-dart",
    )
    assert not seen[0][3].exists()


def test_quality_job_is_unconditional_read_only_and_sdk_pinned():
    import yaml

    workflow = yaml.safe_load((gate.ROOT / ".github/workflows/quality.yml").read_text())
    job = workflow["jobs"]["migration-integrity"]
    assert workflow["permissions"] == {"contents": "read"}
    assert "if" not in job and "needs" not in job
    assert job["steps"][0]["with"] == {"persist-credentials": False, "fetch-depth": 0}
    assert job["steps"][1]["with"]["sdk"] == "3.9.2"
    assert job["steps"][-1]["run"] == "python tools/check_migration_integrity.py"
    assert all("cache" not in step.get("uses", "") for step in job["steps"])
