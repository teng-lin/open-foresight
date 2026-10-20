"""Repeated shell-driver runs publish only the current package and bundle files."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import textwrap

import pytest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "open-foresight-1.0.0-1-linux-x86_64.tar.gz"


def write_script(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(body))


@pytest.fixture
def driver(tmp_path):
    # Insert both container mount names into real host paths. Namespace mapping
    # must never rewrite text that an earlier substitution already inserted.
    tmp_path = tmp_path / "src/out"
    tmp_path.mkdir(parents=True)
    checkout = tmp_path / "checkout"
    tools = checkout / "tools"
    tools.mkdir(parents=True)
    for name in (
        "build_linux_container.sh",
        "linux_container_build.sh",
        "copy_linux_source.sh",
    ):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    (tools / "pins.json").write_text('{"ubuntu_snapshot":"fixture"}')
    write_script(tools / "build.sh", "set -eu\nprintf '%s\\n' \"$@\" > build-args\n")
    write_script(
        tools / "ci_app_dependency_seed.py",
        """
        from pathlib import Path
        import sys
        seed = Path(sys.argv[sys.argv.index('--output') + 1])
        seed.mkdir(exist_ok=True)
        (seed / 'qualification.json').write_text('{}')
        """,
    )
    write_script(
        tools / "ci_linux_handoff.py",
        """
        from pathlib import Path
        import sys
        args = sys.argv
        if args[1] == 'identity':
            Path(args[args.index('--output') + 1]).write_text('{}')
        else:
            output = Path(args[args.index('--directory') + 1])
            output.mkdir(exist_ok=True)
            (output / 'revision').write_text(args[args.index('--revision') + 1])
        """,
    )
    write_script(
        tools / "package.py",
        """
        import json
        from pathlib import Path
        import sys
        output = Path(sys.argv[sys.argv.index('--output') + 1])
        output.mkdir(parents=True, exist_ok=True)
        for name, value in json.loads(Path('payload.json').read_text()).items():
            (output / name).write_text(value)
        (output / 'revision').write_text(sys.argv[sys.argv.index('--revision') + 1])
        """,
    )
    write_script(
        checkout / "packaging/check_abi.py", "# Tiny fixture has no native ABI.\n"
    )
    write_script(
        checkout / "packaging/package_linux.py",
        """
        import hashlib
        from pathlib import Path
        import sys
        import tarfile
        args = sys.argv
        version = args[args.index('--version') + 1]
        release = args[args.index('--release') + 1]
        output = Path('dist/packages')
        output.mkdir(parents=True, exist_ok=True)
        name = f'open-foresight-{version}-{release}-linux-x86_64.tar.gz'
        package = output / name
        with tarfile.open(package, 'w:gz') as archive:
            archive.add(args[args.index('--bundle') + 1], arcname='open-foresight')
        digest = hashlib.sha256(package.read_bytes()).hexdigest()
        (output / (name + '.sha256')).write_text(f'{digest}  {name}\\n')
        """,
    )
    # Replace only Docker's mount namespace. The complete production Bash
    # scripts, system cp, sha256sum and Python tar extraction execute normally.
    docker = tmp_path / "bin/docker"
    write_script(
        docker,
        f"#!{sys.executable}\n"
        + textwrap.dedent(
            """
            import os
            from pathlib import Path
            import re
            import subprocess
            import sys
            args = sys.argv[1:]
            if args[:2] == ['buildx', 'build']:
                assert 'type=registry,ref=ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64' in args
                sys.exit(0)
            assert args[0] == 'run', args
            mounts = {}
            for index, value in enumerate(args):
                if value == '-v':
                    host, container, *_ = args[index + 1].split(':')
                    mounts[container] = host
            output = Path(mounts['/out'])
            if args[-1].endswith('linux_container_test.sh'):
                assert (Path(mounts['/handoff']) / 'revision').is_file()
                if os.environ['FIXTURE_TEST_FAILURE'] == '1':
                    message = 'fixture runner failed before writing service results'
                    (output / 'runner.log').write_text(message)
                    print(message, file=sys.stderr)
                    sys.exit(17)
                (output / 'tested').write_text(os.environ['SOURCE_REVISION'])
                service = output / 'test-results/service/results.xml'
                service.parent.mkdir(parents=True, exist_ok=True)
                service.write_text('<testsuite tests="1"><testcase name="old-service"/></testsuite>')
                sys.exit(0)
            assert args[-1] == '/workspace/tools/linux_container_build.sh'
            workspace = Path(mounts['/workspace'])
            counter = Path(os.environ['FIXTURE_CONTAINERS'])
            count = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(count))
            container = counter.parent / ('container-' + str(count))
            container.mkdir()
            script = (workspace / 'tools/linux_container_build.sh').read_text()
            paths = {'/workspace': workspace, '/src': container / 'src',
                     '/out': output, '/ci-inputs.json': Path(mounts['/ci-inputs.json']),
                     '/run/secrets': container / 'secrets'}
            script = re.sub('|'.join(map(re.escape, paths)),
                            lambda match: str(paths[match[0]]), script)
            runner = container / 'build.sh'
            runner.write_text(script)
            subprocess.run(['bash', str(runner)], check=True, timeout=30)
            """
        ),
    )
    docker.chmod(0o755)
    output = tmp_path / "output"

    def run(payload, revision, mode, *, test_failure=False):
        (checkout / "payload.json").write_text(json.dumps(payload))
        environment = {
            **os.environ,
            "PATH": str(docker.parent) + os.pathsep + os.environ["PATH"],
            "FORESIGHT_HOST_PYTHON": sys.executable,
            "FORESIGHT_PYTHON": sys.executable,
            "FORESIGHT_BUILDER": "fixture",
            "SDK_IMAGE": "fixture-sdk",
            "GITHUB_REPOSITORY": "TeNg-Lin/Open-Foresight",
            "FORESIGHT_GOOGLE_CLIENT_FILE": "",
            "FORESIGHT_GOOGLE_CLIENT_JSON": "",
            "FORESIGHT_SEARCH_API_KEY": "",
            "FORESIGHT_WEB_CONTENT_API_KEY": "",
            "APP_DEPENDENCY_SEED": str(tmp_path / "seed"),
            "SOURCE_REVISION": revision,
            "SOURCE_DATE_EPOCH": "1",
            "VERSION": "1.0.0",
            "RELEASE": "1",
            "FIXTURE_CONTAINERS": str(tmp_path / "container-count"),
            "FIXTURE_TEST_FAILURE": "1" if test_failure else "0",
        }
        result = subprocess.run(
            [
                "bash",
                str(tools / "build_linux_container.sh"),
                "--output",
                str(output),
                *mode,
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
        )
        transcript = result.stdout + result.stderr
        (tmp_path / "last-driver.log").write_text(transcript)
        assert result.returncode == (17 if test_failure else 0), transcript
        if test_failure:
            assert "fixture runner failed before writing service results" in transcript
        return output

    return run


def assert_current_package(output):
    package = output / "packages" / PACKAGE
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    assert (
        package.with_name(PACKAGE + ".sha256")
    ).read_text() == f"{digest}  {PACKAGE}\n"
    with tarfile.open(package) as archive:
        assert archive.extractfile("open-foresight/current").read() == b"second"
        assert archive.extractfile("open-foresight/revision").read() == b"b" * 40
        assert "open-foresight/removed" not in archive.getnames()


def test_repeated_build_replaces_owned_packages(driver):
    output = driver({"current": "first", "removed": "old"}, "a" * 40, ["--build-only"])
    (output / "packages/obsolete.tar.gz").write_bytes(b"old version")
    driver({"current": "second"}, "b" * 40, ["--build-only"])
    assert_current_package(output)
    assert sorted(path.name for path in (output / "packages").iterdir()) == [
        PACKAGE,
        PACKAGE + ".sha256",
    ]
    assert (output / "handoff/revision").read_text() == "b" * 40


def test_repeated_all_mode_extracts_into_fresh_dist(driver):
    output = driver({"current": "first", "removed": "old"}, "a" * 40, [])
    assert (output / "dist/open-foresight/removed").read_text() == "old"
    # A fresh producer artifact isolates the host's extraction from the separate
    # repeated container-export regression above. Keep its existing host dist.
    shutil.rmtree(output / "packages")
    driver({"current": "second"}, "b" * 40, [])
    assert_current_package(output)
    assert (output / "dist/open-foresight/current").read_text() == "second"
    assert (output / "dist/open-foresight/revision").read_text() == "b" * 40
    assert not (output / "dist/open-foresight/removed").exists()
    assert (output / "evidence/tested").read_text() == "b" * 40


def test_failed_test_only_keeps_new_diagnostics_without_old_passing_evidence(driver):
    output = driver({"current": "first"}, "a" * 40, [])
    assert (output / "evidence/test-results/service/results.xml").is_file()
    handoff = {
        path.relative_to(output / "handoff"): path.read_bytes()
        for path in (output / "handoff").rglob("*")
        if path.is_file()
    }
    driver({}, "a" * 40, ["--test-only"], test_failure=True)
    assert not (output / "evidence/test-results/service/results.xml").exists()
    assert not (output / "evidence/tested").exists()
    assert (output / "evidence/runner.log").read_text() == (
        "fixture runner failed before writing service results"
    )
    assert {
        path.relative_to(output / "handoff"): path.read_bytes()
        for path in (output / "handoff").rglob("*")
        if path.is_file()
    } == handoff
