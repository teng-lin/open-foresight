"""Application caches remain usable with qualified local SDK archives."""

import json
from pathlib import Path
import subprocess

import pytest
import yaml

from tools import ci_app_build_transport as transport

ROOT = Path(__file__).resolve().parents[1]


def cli(arguments, **_kwargs):
    if arguments == ["docker", "context", "show"]:
        return "setup-docker-action\n"
    if arguments[:3] == ["docker", "buildx", "inspect"]:
        assert arguments[3] == "setup-docker-action"
        assert arguments == ["docker", "buildx", "inspect", "setup-docker-action"]
        return (ROOT / "tests/fixtures/buildx/docker-inspect.txt").read_text()
    if arguments[:2] == ["docker", "info"]:
        return '[["driver-type","io.containerd.snapshotter.v1"]]'
    assert arguments[:4] == ["docker", "buildx", "imagetools", "inspect"]
    assert arguments[4] in (
        "ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:app-deps-buildcache-v1",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:ci-tools-buildcache-v1",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:acceptance-tools-buildcache-v1",
    )
    assert arguments[5] == "--raw"
    return json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.buildkit.cacheconfig.v0",
                "digest": "sha256:" + "a" * 64,
                "size": 123,
            },
            "layers": [],
        }
    )


@pytest.mark.parametrize(
    "stage,tag",
    [
        ({}, "app-deps-buildcache-v1"),
        ({"ci": True}, "ci-tools-buildcache-v1"),
        ({"acceptance": True}, "acceptance-tools-buildcache-v1"),
    ],
)
def test_current_context_docker_builder_keeps_sdk_archive_visible(stage, tag):
    assert transport.prepare("teng-lin/open-foresight", request=cli, **stage) == {
        "builder": "setup-docker-action",
        "cache": "ghcr.io/teng-lin/open-foresight/linux-sdk:" + tag,
        "legacy_cache": "ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64",
        "cache_available": True,
    }


@pytest.mark.parametrize("wrong", ["builder", "storage"])
def test_missing_registry_support_never_silently_disables_reuse(wrong):
    def request(arguments, **kwargs):
        if wrong == "builder" and arguments[:3] == ["docker", "buildx", "inspect"]:
            return "Name: setup-docker-action\nDriver: docker-container\n"
        if wrong == "storage" and arguments[:2] == ["docker", "info"]:
            return '[["Backing Filesystem","extfs"]]'
        return cli(arguments, **kwargs)

    with pytest.raises(RuntimeError, match="before loading the SDK"):
        transport.prepare("teng-lin/open-foresight", request=request)


def test_registry_failure_is_not_permission_to_compile_uncached():
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"]:
            raise subprocess.CalledProcessError(
                1, arguments, stderr="TLS handshake timeout"
            )
        return cli(arguments, **kwargs)

    with pytest.raises(RuntimeError, match="retry lookup"):
        transport.prepare("teng-lin/open-foresight", request=request)


@pytest.mark.parametrize("job", ["linux-build", "linux-test"])
def test_shared_daemon_is_provisioned_before_sdk_load_and_seed_is_always_consumed(job):
    workflow = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())
    selected = workflow["jobs"][job]
    steps = selected["steps"]
    setup = next(
        i
        for i, step in enumerate(steps)
        if step.get("uses", "").startswith("docker/setup-docker-action@")
    )
    fetch = next(i for i, step in enumerate(steps) if step.get("id") == "sdk")
    assert setup < fetch
    assert json.loads(steps[setup]["with"]["daemon-config"])["features"][
        "containerd-snapshotter"
    ]
    builders = [
        step
        for step in steps
        if step.get("uses", "").startswith("docker/setup-buildx-action@")
    ]
    assert len(builders) == 1 and builders[0]["with"]["driver"] == "docker"
    transport_step = next(
        step for step in steps if "ci_app_build_transport.py" in step.get("run", "")
    )
    assert '--repository "$GITHUB_REPOSITORY"' in transport_step["run"]
    assert "--ci" in transport_step["run"]
    script = (ROOT / "tools/build_linux_container.sh").read_text()
    assert "tools/ci_app_dependency_seed.py" in script
    assert "--verify-existing" in script
    assert "--target ci" in script
    assert "appdeps_seed=$task_seed" in script
    for cache in (
        "ci-tools-buildcache-v1",
        "app-deps-buildcache-v1",
        "app-buildcache-x86-64",
    ):
        assert cache in script
    assert "REQUIRE_DEPENDENCY_REUSE=1" in script
    assert "--cache-to" not in script
    assert selected["permissions"]["packages"] == "read"


def test_new_cache_absence_retains_original_seed_and_does_not_republish_it(capsys):
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"] and arguments[
            4
        ].endswith(":app-deps-buildcache-v1"):
            raise subprocess.CalledProcessError(
                1, arguments, stderr=arguments[4] + ": not found"
            )
        return cli(arguments, **kwargs)

    result = transport.prepare("teng-lin/open-foresight", request=request)
    assert result["cache_available"] is False
    assert result["cache"].endswith(":app-deps-buildcache-v1")
    assert result["legacy_cache"].endswith(":app-buildcache-x86-64")
    message = capsys.readouterr().out
    assert "qualified dependency objects remain required" in message
    assert "artifact probe already missed" not in message


def test_legacy_tag_disappearance_requires_recovery_not_dependency_rebuild():
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"] and arguments[
            4
        ].endswith(":app-buildcache-x86-64"):
            raise subprocess.CalledProcessError(
                1, arguments, stderr=arguments[4] + ": not found"
            )
        return cli(arguments, **kwargs)

    with pytest.raises(RuntimeError, match="restore its reviewed manifest"):
        transport.prepare("teng-lin/open-foresight", request=request)


def test_registry_namespace_normalizes_github_repository_case():
    assert transport.reference("Teng-Lin/Open-Foresight") == transport.reference(
        "teng-lin/open-foresight"
    )


@pytest.mark.parametrize("existing_seed", [False, True])
@pytest.mark.parametrize("mode", ["--build-only", "--test-only"])
@pytest.mark.parametrize("schedule_value", [None, "0", "1", "bad"])
def test_own_run_driver_uses_the_shared_daemon_and_required_seed_without_cache_writes(
    tmp_path, existing_seed, mode, schedule_value
):
    """Exercise the workflow's real driver, leaving Docker and SDK bytes untouched."""
    import os
    import sys

    workflow = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())
    job = workflow["jobs"]["linux-build"]
    steps = job["steps"]
    assert job["permissions"]["packages"] == "read"
    assert any(
        "bash tools/build_linux_container.sh --build-only" in step.get("run", "")
        for step in steps
    )
    sdk_index = next(i for i, step in enumerate(steps) if step.get("id") == "sdk")
    daemon_index = next(
        i
        for i, step in enumerate(steps)
        if step.get("uses", "").startswith("docker/setup-docker-action@")
    )
    assert daemon_index < sdk_index
    driver = next(
        step
        for step in steps
        if step.get("uses", "").startswith("docker/setup-buildx-action@")
    )
    assert driver["with"]["driver"] == "docker"
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    seed = tmp_path / "qualified-seed"
    if existing_seed:
        seed.mkdir()
        (seed / "sentinel").write_bytes(b"existing verified objects")
    script = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['TRANSPORT_LOG'], 'a') as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == 'docker' and sys.argv[1:] == ['context', 'show']:
    print('shared-daemon')
if name == 'docker' and sys.argv[1] == 'run':
    forwarded = dict()
    for index, value in enumerate(sys.argv):
        if value == '-e':
            key, separator, literal = sys.argv[index + 1].partition('=')
            if separator or key in os.environ:
                forwarded[key] = literal if separator else os.environ[key]
    with open(os.environ['TRANSPORT_LOG'], 'a') as stream:
        stream.write(json.dumps(['container-env', forwarded]) + '\\n')
if name == 'host-python':
    if 'tools/ci_app_dependency_seed.py' in sys.argv:
        Path(sys.argv[sys.argv.index('--output') + 1]).mkdir(exist_ok=True)
    elif 'tools/ci_linux_handoff.py' in sys.argv:
        Path(sys.argv[sys.argv.index('--output') + 1]).write_text('{{}}')
    elif sys.argv[1:3] == ['-I', '-c']:
        assert 'sys.base_prefix' in sys.argv[3]
        print(Path(sys.base_prefix).resolve())
    elif '-c' in sys.argv:
        print('frozen-snapshot')
"""
    for name in ("docker", "host-python"):
        path = binary / name
        path.write_text(script)
        path.chmod(0o755)
    environment = {
        **os.environ,
        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        "FORESIGHT_HOST_PYTHON": str(binary / "host-python"),
        "TRANSPORT_LOG": str(log),
        "GITHUB_REPOSITORY": "Owner/Repo",
        "SOURCE_REVISION": "a" * 40,
        "SOURCE_DATE_EPOCH": "123",
        "VERSION": "0.1.2",
        "FORESIGHT_GOOGLE_CLIENT_FILE": "",
        "FORESIGHT_GOOGLE_CLIENT_JSON": "",
        "FORESIGHT_SEARCH_API_KEY": "",
        "FORESIGHT_WEB_CONTENT_API_KEY": "",
    }
    environment.pop("FORESIGHT_LINUX_TEST_SCHEDULE", None)
    if schedule_value is not None:
        environment["FORESIGHT_LINUX_TEST_SCHEDULE"] = schedule_value
    result = subprocess.run(
        [
            "bash",
            str(ROOT / "tools/build_linux_container.sh"),
            mode,
            "--sdk-image",
            "verified-sdk:original",
            "--seed",
            str(seed),
            "--output",
            str(tmp_path / "output"),
        ],
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    rows = [json.loads(line) for line in log.read_text().splitlines()]
    seed_command = next(row for row in rows if "tools/ci_app_dependency_seed.py" in row)
    assert ("--verify-existing" in seed_command) == existing_seed
    build = next(row for row in rows if row[:3] == ["docker", "buildx", "build"])
    assert build[build.index("--builder") + 1] == "shared-daemon"
    assert build[build.index("--build-context") + 1] == "appdeps_seed=" + str(seed)
    assert "REQUIRE_DEPENDENCY_REUSE=1" in build
    for tag in (
        "ci-tools-buildcache-v1",
        "app-deps-buildcache-v1",
        "app-buildcache-x86-64",
    ):
        assert "type=registry,ref=ghcr.io/owner/repo/linux-sdk:" + tag in build
    assert "--cache-to" not in build
    runs = [row for row in rows if row[:2] == ["docker", "run"]]
    assert len(runs) == 1
    runtime = str(Path(sys.base_prefix).resolve())
    assert runtime + ":" + runtime + ":ro" in runs[0]
    assert "FORESIGHT_TOOLING_PYTHON_RUNTIME=" + runtime + "/bin/python3" in runs[0]
    target = "test" if mode == "--test-only" else "build"
    assert runs[0][-1] == f"/workspace/tools/linux_container_{target}.sh"
    assert runs[0][runs[0].index("FORESIGHT_LINUX_TEST_SCHEDULE") - 1] == "-e"
    container_env = next(row[1] for row in rows if row[0] == "container-env")
    assert container_env.get("FORESIGHT_LINUX_TEST_SCHEDULE") == schedule_value
    assert ("FORESIGHT_LINUX_TEST_SCHEDULE" in container_env) == (
        schedule_value is not None
    )
    assert "sdk.Dockerfile" not in json.dumps(rows)
    if existing_seed:
        assert (seed / "sentinel").read_bytes() == b"existing verified objects"


@pytest.mark.parametrize("flags", [[], ["--ci"], ["--acceptance"]])
def test_transport_cli_selects_only_one_cache_stage(monkeypatch, flags, capsys):
    import sys

    calls = []
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    monkeypatch.setattr(
        sys, "argv", ["ci_app_build_transport.py", "--repository", "owner/repo", *flags]
    )

    def prepare(repository, **options):
        calls.append((repository, options))
        return {"cache_available": True}

    monkeypatch.setattr(transport, "prepare", prepare)
    transport.main()
    assert calls == [
        ("owner/repo", {"ci": "--ci" in flags, "acceptance": "--acceptance" in flags})
    ]
    assert json.loads(capsys.readouterr().out) == {"cache_available": True}


def test_transport_rejects_combined_ci_and_acceptance(monkeypatch):
    import sys

    with pytest.raises(ValueError, match="Choose one"):
        transport.reference("owner/repo", ci=True, acceptance=True)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_app_build_transport.py",
            "--repository",
            "owner/repo",
            "--ci",
            "--acceptance",
        ],
    )
    with pytest.raises(SystemExit) as result:
        transport.main()
    assert result.value.code == 2


def test_missing_ci_tools_cache_keeps_verified_sdk_and_dependency_seed(capsys):
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"] and arguments[
            4
        ].endswith(":ci-tools-buildcache-v1"):
            raise subprocess.CalledProcessError(
                1, arguments, stderr=arguments[4] + ": not found"
            )
        return cli(arguments, **kwargs)

    result = transport.prepare("teng-lin/open-foresight", request=request, ci=True)
    assert result["cache_available"] is False
    assert result["cache"].endswith(":ci-tools-buildcache-v1")
    assert result["legacy_cache"].endswith(":app-buildcache-x86-64")
    message = capsys.readouterr().out
    assert "CI tools cache is absent" in message
    assert "verified SDK and qualified dependency seed unchanged" in message
    assert "No SDK or dependency compilation is authorized" in message
    assert "acceptance tools" not in message
