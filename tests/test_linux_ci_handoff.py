"""The shadow runners retain exact bytes/timestamps and never rebuild dependencies."""

import json
import os
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch

import pytest

from tests.test_core_coverage_benchmark import gate as gate, run as run_gate

from tools import ci_linux_handoff as handoff
from tools import verify_application_no_build as idle


@pytest.fixture
def compiled(tmp_path):
    root = tmp_path / "src"
    dep = root / "build/_deps/vendor-src"
    dep.mkdir(parents=True)
    (dep / "dep.c").write_text("int dep(void) { return 0; }\n")
    (dep / "CMakeLists.txt").write_text("add_library(dep STATIC dep.c)\n")
    (root / "main.c").write_text("int dep(void); int main(void) { return dep(); }\n")
    (root / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\nproject(handoff C)\n"
        'add_subdirectory("${CMAKE_BINARY_DIR}/_deps/vendor-src" "${CMAKE_BINARY_DIR}/_deps/vendor-build")\n'
        "add_executable(app main.c)\ntarget_link_libraries(app PRIVATE dep)\n"
        "enable_testing()\nadd_test(NAME native COMMAND app)\n"
    )
    subprocess.run(
        ["cmake", "-G", "Unix Makefiles", "-S", str(root), "-B", str(root / "build")],
        check=True,
        capture_output=True,
        timeout=60,
    )
    subprocess.run(
        ["cmake", "--build", str(root / "build")],
        check=True,
        capture_output=True,
        timeout=60,
    )
    inputs = tmp_path / "inputs.json"
    inputs.write_text(json.dumps({"identity": "verified"}))
    return root, inputs


def test_real_make_handoff_between_runner_filesystems_is_idle(compiled, tmp_path):
    root, inputs = compiled
    original = root / "build/app"
    checksum = handoff.digest(original)
    stamp = original.stat().st_mtime_ns
    (root / "native-link").symlink_to("build/app")
    (root / ".git").mkdir()
    (root / ".git/config").write_text("not exported")
    seed = tmp_path / "verified-seed"
    shutil.copytree(root / "build/_deps", seed, copy_function=shutil.copy2)
    archive = tmp_path / "handoff"
    manifest = handoff.pack(root, archive, "a" * 40, inputs)
    assert not any(
        name.startswith((".git", "build/_deps")) for name in manifest["files"]
    )
    # Both isolated runners mount their independent tree at /src. Replace this
    # entire filesystem with the dependency-only image, preserving that path.
    shutil.rmtree(root)
    shutil.copytree(seed, root / "build/_deps", copy_function=shutil.copy2)
    retained = handoff.digest(root / "build/_deps/vendor-build/libdep.a")
    handoff.restore(archive, root, "a" * 40, inputs)
    assert handoff.digest(original) == checksum
    assert original.stat().st_mtime_ns == stamp
    assert handoff.digest(root / "build/_deps/vendor-build/libdep.a") == retained
    assert (root / "native-link").readlink() == Path("build/app")
    idle.verify(root / "build")
    subprocess.run(
        ["ctest", "--test-dir", str(root / "build"), "--output-on-failure"],
        check=True,
        capture_output=True,
        timeout=30,
    )
    (root / "main.c").write_text("int main(void) { return 1; }\n")
    # GNU Make 3.81 on macOS compares whole seconds. Force a real later edit
    # without sleeping or changing the unchanged-output restoration assertion.
    changed_stamp = (
        max(original.stat().st_mtime_ns, (root / "main.c").stat().st_mtime_ns)
        + 2_000_000_000
    )
    os.utime(root / "main.c", ns=(changed_stamp, changed_stamp))
    with pytest.raises(ValueError, match="not idle"):
        idle.verify(root / "build")
    assert "main.c" in (root / "build/application-no-build-plan.log").read_text()
    assert handoff.digest(root / "build/_deps/vendor-build/libdep.a") == retained


@pytest.mark.parametrize("change", ["archive", "source", "inputs"])
def test_handoff_mismatches_preserve_the_seed(compiled, tmp_path, change):
    root, inputs = compiled
    directory = tmp_path / "handoff"
    handoff.pack(root, directory, "a" * 40, inputs)
    if change == "archive":
        with (directory / "source-build.tar.gz").open("ab") as stream:
            stream.write(b"invalid")
    elif change == "inputs":
        inputs.write_text('{"identity":"other"}')
    retained = handoff.digest(root / "build/_deps/vendor-build/libdep.a")
    with pytest.raises(ValueError, match="mismatch"):
        handoff.restore(
            directory, root, "b" * 40 if change == "source" else "a" * 40, inputs
        )
    assert handoff.digest(root / "build/_deps/vendor-build/libdep.a") == retained


@pytest.mark.parametrize(
    "target", ["/etc/passwd", "../../outside", "/opt/../etc/passwd"]
)
def test_archive_rejects_untrusted_source_links(tmp_path, target):
    root = tmp_path / "src"
    root.mkdir()
    (root / "link").symlink_to(target)
    inputs = tmp_path / "inputs"
    inputs.write_text("{}")
    with pytest.raises(ValueError, match="link"):
        handoff.pack(root, tmp_path / "out", "a" * 40, inputs)


def test_ci_identity_is_input_based_and_does_not_hash_a_rebuilt_ci_image(tmp_path):
    recipe = tmp_path / "Dockerfile"
    recipe.write_text(
        "FROM sdk AS application-base\nFROM application-base AS application-dependencies\nFROM application-dependencies AS ci\nRUN tools\nFROM application-dependencies AS tested\nRUN app\n"
    )
    qualification = tmp_path / "qualification.json"
    qualification.write_text('{"original_producer":42}')
    with patch.object(
        handoff.subprocess, "check_output", return_value="sha256:" + "a" * 64
    ):
        first = handoff.input_identity(
            "verified-sdk", qualification, recipe, "20261001T000000Z"
        )
        recipe.write_text(recipe.read_text().replace("RUN app", "RUN different app"))
        assert (
            handoff.input_identity(
                "verified-sdk", qualification, recipe, "20261001T000000Z"
            )
            == first
        )
        recipe.write_text(recipe.read_text().replace("RUN tools", "RUN new tools"))
        assert (
            handoff.input_identity(
                "verified-sdk", qualification, recipe, "20261001T000000Z"
            )
            != first
        )


@pytest.mark.parametrize(
    "output",
    [
        "cc -c native.c -o native.o",
        "/usr/bin/cmake -E touch generated.h",
        "protoc schema.proto",
        "ninja: error: failed",
    ],
)
def test_idle_guard_rejects_all_planned_generation_compilation_and_failure(output):
    assert idle.planned_work(output) == output


@pytest.mark.parametrize("mode", ["build-only", "test-only"])
@pytest.mark.parametrize("stage", ["core", "desktop"])
@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_language_build_and_test_modes_do_not_repeat_compilation_or_suites(
    gate, mode, stage, platform
):
    root, _ = gate
    coverage = root / "apps/desktop/coverage"
    coverage.mkdir()
    (coverage / "lcov.info").write_text("SF:lib/app.dart\nDA:1,1\nend_of_record\n")
    result, commands = run_gate(
        gate, stage=stage, platform=platform, FORESIGHT_BUILD_MODE=mode
    )
    assert result.returncode == 0, result.stdout + result.stderr
    args = [command["args"] for command in commands]
    compiled = [item for item in args if item[0] in ("compile", "build")]
    tests = [item for item in args if item[0] == "test"]
    assert bool(compiled) == (mode == "build-only")
    assert bool(tests) == (mode == "test-only")
    assert any(item[0] == "analyze" for item in args) == (mode == "test-only")
    assert any(item[0] == "pub" for item in args) == (mode == "build-only")
    if stage == "desktop" and tests:
        assert ("--coverage" in tests[0]) == (platform == "linux")


@pytest.fixture
def qualified_handoff(tmp_path, monkeypatch):
    import zipfile
    from tools import ci_artifacts as artifacts

    for key, value in {
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_RUN_ID": "41",
        "GITHUB_RUN_ATTEMPT": "2",
    }.items():
        monkeypatch.setenv(key, value)
    source = tmp_path / "source"
    source.mkdir()
    (source / "compiled").write_bytes(b"compiled bytes")
    inputs = tmp_path / "inputs"
    inputs.write_text("{}")
    upload = tmp_path / "upload"
    handoff.pack(source, upload, "a" * 40, inputs)
    archive = tmp_path / "artifact.zip"
    with zipfile.ZipFile(archive, "w") as stream:
        for name in ("source-build.json", "source-build.tar.gz"):
            stream.write(upload / name, name)
    checksum = handoff.digest(archive)
    run = {
        "id": 41,
        "event": "pull_request",
        "head_sha": "a" * 40,
        "path": ".github/workflows/macos.yml",
        "repository": {"full_name": "owner/repo"},
    }
    artifact = {
        "id": 51,
        "name": "linux-src-build-41-2",
        "expired": False,
        "workflow_run": {"id": 41},
        "digest": "sha256:" + checksum,
        "created_at": "2026-10-19T10:00:30Z",
    }
    job = {
        "id": 61,
        "run_id": 41,
        "run_attempt": 2,
        "head_sha": "a" * 40,
        "name": "linux-build",
        "conclusion": "success",
        "status": "completed",
        "started_at": "2026-10-19T10:00:00Z",
        "completed_at": "2026-10-19T10:01:00Z",
    }

    def api(repository, route):
        assert repository == "owner/repo"
        assert route in ("actions/runs/41", "actions/artifacts/51")
        return run if route.endswith("41") else artifact

    def download(command, **kwargs):
        assert command == ["gh", "api", "repos/owner/repo/actions/artifacts/51/zip"]
        kwargs["stdout"].write(archive.read_bytes())
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(artifacts, "api", api)
    monkeypatch.setattr(artifacts, "dependency_jobs", lambda *args: [job])
    monkeypatch.setattr(artifacts.subprocess, "run", download)
    return {
        "output": tmp_path / "download",
        "source": "a" * 40,
        "run": run,
        "artifact": artifact,
        "job": job,
        "checksum": checksum,
    }


def qualify_fixture(value):
    from tools import integration_application

    # Missing producer fixtures fail at the visibility deadline; do not wait a
    # wall-clock minute for jobs that this fixture deliberately omitted.
    with patch.object(integration_application.time, "monotonic", side_effect=[0, 1000]):
        return handoff.qualify(
            value["output"], value["source"], 41, 2, 51, value["checksum"], "owner/repo"
        )


def test_handoff_verifies_original_successful_job_attempt_and_downloaded_zip(
    qualified_handoff,
):
    qualify_fixture(qualified_handoff)
    assert (qualified_handoff["output"] / "source-build.tar.gz").is_file()


@pytest.mark.parametrize(
    "section,field,value",
    [
        ("run", "path", ".github/workflows/quality.yml"),
        ("run", "head_sha", "b" * 40),
        ("run", "repository", {"full_name": "other/repo"}),
        ("artifact", "expired", True),
        ("artifact", "name", "linux-src-build-41-1"),
        ("artifact", "workflow_run", {"id": 42}),
        ("artifact", "digest", "sha256:" + "b" * 64),
        ("artifact", "created_at", "2026-10-19T09:59:00Z"),
        ("job", "conclusion", "failure"),
        ("job", "run_attempt", 1),
        ("job", "name", "linux-bundle"),
    ],
)
def test_handoff_rejects_wrong_provenance_before_execution(
    qualified_handoff, section, field, value
):
    qualified_handoff[section][field] = value
    with pytest.raises(ValueError):
        qualify_fixture(qualified_handoff)
    assert not qualified_handoff["output"].exists()


def test_handoff_rejects_actual_zip_corruption_even_if_api_metadata_still_matches(
    qualified_handoff, monkeypatch
):
    from tools import ci_artifacts as artifacts

    def corrupt(command, **kwargs):
        kwargs["stdout"].write(b"different downloaded bytes")

    monkeypatch.setattr(artifacts.subprocess, "run", corrupt)
    with pytest.raises(ValueError, match="ZIP digest"):
        qualify_fixture(qualified_handoff)
    assert not qualified_handoff["output"].exists()


@pytest.mark.parametrize("change", [None, "object", "header", "timestamp", "receipt"])
def test_reusing_a_seed_checks_every_retained_byte_and_timestamp_without_replacing_it(
    tmp_path, monkeypatch, change
):
    from tools import ci_app_dependency_seed as seed

    def prepare(image, output, cache, root):
        assert image == "verified-sdk"
        directory = output / "src/build/_deps/vendor-build"
        directory.mkdir(parents=True)
        for name in ("archive.a", "header.h"):
            path = directory / name
            path.write_text("verified " + name)
            os.utime(path, ns=(123456789000, 123456789000))
        os.utime(directory, ns=(123456789000, 123456789000))
        (output / "qualification.json").write_text('{"original_producer":42}')

    import os

    monkeypatch.setattr(seed, "prepare", prepare)
    output = tmp_path / "retained"
    prepare("verified-sdk", output, tmp_path / "cache", tmp_path)
    target = output / "src/build/_deps/vendor-build/archive.a"
    initial = target.read_bytes()
    if change in ("object", "header"):
        (target if change == "object" else target.with_name("header.h")).write_text(
            "tampered"
        )
    elif change == "timestamp":
        os.utime(target, ns=(999999999999, 999999999999))
    elif change == "receipt":
        (output / "qualification.json").write_text('{"original_producer":43}')
    before = target.read_bytes()
    if change is None:
        seed.verify_existing("verified-sdk", output, tmp_path / "cache", tmp_path)
        assert before == initial
    else:
        with pytest.raises(ValueError, match="differs"):
            seed.verify_existing("verified-sdk", output, tmp_path / "cache", tmp_path)
    assert target.read_bytes() == before


@pytest.mark.parametrize(
    "case",
    [
        "reuse",
        "main-missing",
        "fork",
        "race",
        "ordinary-race",
        "race-missing",
        "network",
    ],
)
def test_shadow_sdk_reuses_before_component_scoped_fallback(
    tmp_path, case, monkeypatch
):
    from tools import ci_linux_shadow_sdk as shadow

    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    prefix = tmp_path / "sdk/verified"
    reference = {
        "producer_run": 91,
        "artifact_id": 92,
        "artifact_digest": "sha256:" + "d" * 64,
    }
    calls = []

    def materialize(reused):
        prefix.mkdir(parents=True)
        (prefix / "image.tar").write_bytes(b"verified image")
        if reused:
            (prefix / "source-qualification.json").write_text(json.dumps(reference))

    def fetch(*args, **kwargs):
        calls.append((args, kwargs))
        if case == "network":
            raise RuntimeError("network")
        found = case == "reuse" or (case == "race" and len(calls) > 1)
        if found:
            materialize(True)
        return found

    def produce(*args, **kwargs):
        assert kwargs == {"retain_payload": prefix}
        if case in ("race", "race-missing"):
            return "approved-original"
        materialize(case == "ordinary-race")
        return "reused" if case == "ordinary-race" else "built"

    with (
        patch.object(shadow.waiter, "fetch", side_effect=fetch),
        patch.object(shadow.sdk, "produce", side_effect=produce) as producer,
        patch.object(shadow.sdk, "resolve", return_value="verified-image") as resolve,
        patch.object(shadow.sdk, "write_outputs") as write,
        patch.object(shadow.application, "save_sdk") as save,
    ):
        if case in ("main-missing", "race-missing", "network"):
            with pytest.raises(RuntimeError):
                shadow.prepare(
                    "owner/repo", "a" * 40, 42, case != "main-missing", tmp_path / "sdk"
                )
            if case in ("main-missing", "network"):
                producer.assert_not_called()
            save.assert_not_called()
            return
        assert shadow.prepare("owner/repo", "a" * 40, 42, True, tmp_path / "sdk") == (
            case == "fork"
        )
        assert calls[0][0][5] == 1800
        assert calls[0][1] == {"optional": True}
        resolve.assert_called_once_with(prefix, load_registry=True)
        write.assert_called_once_with("verified-image")
        if case == "fork":
            producer.assert_called_once()
            save.assert_called_once_with(
                "a" * 40,
                "verified-image",
                tmp_path / "sdk/in-run",
                shadow=True,
                source_prefix=prefix,
                reuse_archive=True,
            )
            assert not prefix.exists()
            assert output.read_text() == "in_run=true\n"
        else:
            save.assert_not_called()
            assert (
                output.read_text()
                == "producer_run=91\nproducer_artifact_id=92\nproducer_artifact_digest=sha256:"
                + "d" * 64
                + "\n"
            )
            assert not (prefix / "image.tar").exists()


def test_shadow_sdk_transport_preserves_original_reuse_provenance(tmp_path):
    from tools import integration_application as application

    original = {"source_receipt": {"source_commit": "b" * 40}, "producer_run": 91}
    prefix = tmp_path / "verified"
    prefix.mkdir()
    (prefix / "source-qualification.json").write_text(json.dumps(original))

    def save(args):
        Path(args[4]).write_bytes(b"saved exact fixture image")

    with (
        patch.object(
            application.artifacts.subprocess,
            "check_output",
            return_value="a" * 40 + "\n",
        ),
        patch.object(application.sdk, "inspect", return_value="sha256:" + "c" * 64),
        patch.object(application.sdk, "run", side_effect=save),
    ):
        application.save_sdk(
            "a" * 40,
            "verified-image",
            tmp_path / "artifact",
            shadow=True,
            source_prefix=prefix,
        )
    receipt = json.loads((tmp_path / "artifact/identity.json").read_text())
    assert receipt["reused_from"] == original
    assert receipt["tier"] == "pr"
    restored = tmp_path / "restored"
    application.artifacts.unpack(
        "linux-sdk",
        application.artifacts.fingerprint("linux-sdk"),
        tmp_path / "artifact",
        restored,
    )
    assert json.loads((restored / "source-qualification.json").read_text()) == original
    (prefix / "source-qualification.json").unlink()
    (prefix / "source-qualification.json").symlink_to(tmp_path / "missing")
    with (
        patch.object(
            application.artifacts.subprocess,
            "check_output",
            return_value="a" * 40 + "\n",
        ),
        patch.object(application.sdk, "inspect", return_value="sha256:" + "c" * 64),
        patch.object(application.sdk, "run", side_effect=save),
        pytest.raises(ValueError, match="regular"),
    ):
        application.save_sdk(
            "a" * 40,
            "verified-image",
            tmp_path / "invalid",
            shadow=True,
            source_prefix=prefix,
        )


def test_hardlinked_pub_packages_survive_exact_runner_handoff(tmp_path):
    root = tmp_path / "src"
    package = root / ".pub-cache/hosted/pub.dev/fixture-1.0.0/lib"
    package.mkdir(parents=True)
    (package / "fixture.dart").write_text("int answer() => 42;\n")
    os.link(package / "fixture.dart", package / "hardlink.dart")
    config = root / ".dart_tool/package_config.json"
    config.parent.mkdir()
    config.write_text(
        json.dumps(
            {
                "configVersion": 2,
                "packages": [
                    {
                        "name": "fixture",
                        "rootUri": (package.parent).as_uri(),
                        "packageUri": "lib/",
                        "languageVersion": "3.0",
                    }
                ],
            }
        )
    )
    (root / "package-link").symlink_to(".pub-cache/hosted/pub.dev/fixture-1.0.0")
    inputs = tmp_path / "inputs.json"
    inputs.write_text("{}")
    archive = tmp_path / "handoff"
    handoff.pack(root, archive, "a" * 40, inputs)
    shutil.rmtree(root)
    handoff.restore(archive, root, "a" * 40, inputs)
    from urllib.parse import urlparse

    resolved = Path(
        urlparse(json.loads(config.read_text())["packages"][0]["rootUri"]).path
    )
    assert (resolved / "lib/fixture.dart").read_text() == "int answer() => 42;\n"
    assert (resolved / "lib/hardlink.dart").read_bytes() == (
        resolved / "lib/fixture.dart"
    ).read_bytes()
    assert (root / "package-link/lib/fixture.dart").read_bytes() == (
        package / "fixture.dart"
    ).read_bytes()
    with pytest.raises(ValueError, match="Untrusted absolute"):
        handoff.safe_link("old-cache", "/root/.pub-cache/package")


def test_source_copy_preserves_root_configuration_and_nested_source_names(tmp_path):
    source, destination = tmp_path / "checkout", tmp_path / "src"
    source.mkdir()
    destination.mkdir()
    retained = [
        ".coveragerc",
        "source/dist/data",
        "source/coverage/data",
        "source/test-results/data",
        "source/.venv/data",
        "source/.env.example",
    ]
    excluded = [
        ".git/config",
        "build/old",
        "dist/old",
        ".venv/cache",
        ".env",
        ".coverage",
        ".coverage.parallel",
        ".pub-cache/local",
        "source/build/old",
        "source/.dart_tool/old",
        "source/__pycache__/old",
    ]
    for name in retained + excluded:
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(name)
    subprocess.run(
        [
            "bash",
            str(Path(__file__).resolve().parents[1] / "tools/copy_linux_source.sh"),
            str(source),
            str(destination),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    assert {
        p.relative_to(destination).as_posix()
        for p in destination.rglob("*")
        if p.is_file()
    } == set(retained)


@pytest.mark.parametrize("change", ["valid", "corrupt", "different-image"])
def test_saved_shadow_sdk_reuses_verified_archive_without_docker_save(tmp_path, change):
    from tools import integration_application as application
    from tests.test_linux_sdk_artifacts import write_archive, IMAGE_ID

    prefix = tmp_path / "verified"
    write_archive(prefix)
    original = (prefix / "image.tar").read_bytes()
    if change == "corrupt":
        (prefix / "image.tar").write_bytes(b"changed")
    image = "sha256:" + "e" * 64 if change == "different-image" else IMAGE_ID
    output = tmp_path / "in-run"
    with (
        patch.object(application.subprocess, "check_output", return_value="a" * 40),
        patch.object(application.sdk, "inspect", return_value=image),
        patch.object(application.sdk, "run") as docker,
    ):
        if change != "valid":
            with pytest.raises(ValueError):
                application.save_sdk(
                    "a" * 40,
                    "verified-image",
                    output,
                    shadow=True,
                    source_prefix=prefix,
                    reuse_archive=True,
                )
            assert not output.exists()
        else:
            application.save_sdk(
                "a" * 40,
                "verified-image",
                output,
                shadow=True,
                source_prefix=prefix,
                reuse_archive=True,
            )
            restored = tmp_path / "restored"
            application.artifacts.unpack(
                "linux-sdk",
                application.artifacts.fingerprint("linux-sdk"),
                output,
                restored,
            )
            assert (restored / "image.tar").read_bytes() == original
        docker.assert_not_called()


@pytest.mark.parametrize("reused", [False, True])
def test_retained_sdk_producer_saves_and_compresses_only_once(
    tmp_path, monkeypatch, reused
):
    from tools import integration_application as application
    from tools import linux_sdk_artifacts as sdk
    from tests.test_linux_sdk_artifacts import (
        write_archive,
        docker_output,
        REPOSITORY,
        REGISTRY_IMAGE,
    )

    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    monkeypatch.setenv("GITHUB_RUN_ID", "41")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    qualification = {
        "source_receipt": {"component": "linux-sdk", "source_commit": "b" * 40},
        "producer_run": 91,
        "artifact_id": 92,
        "artifact_digest": "sha256:" + "d" * 64,
    }
    commands = []

    def pull(repository, component, identity, prefix, **kwargs):
        if component == "linux-sdk":
            if not reused:
                return False
            prefix.mkdir()
            (prefix / "image.json").write_text(json.dumps({"image": REGISTRY_IMAGE}))
            (prefix / "source-qualification.json").write_text(json.dumps(qualification))
        else:
            write_archive(prefix, component)
        return True

    def docker(command, **kwargs):
        commands.append(command)
        if command[:3] == ["docker", "image", "save"]:
            Path(command[command.index("--output") + 1]).write_bytes(b"saved once")

    prefix = tmp_path / "verified"
    with (
        patch.object(sdk.artifacts, "pull", side_effect=pull),
        patch.object(
            sdk.sdk_build_transport, "prepare", return_value=["docker", "build"]
        ),
        patch.object(sdk, "run", side_effect=docker),
        patch.object(sdk.subprocess, "check_output", side_effect=docker_output),
    ):
        result = sdk.produce(
            "linux-sdk", tmp_path / "unused-packed", REPOSITORY, retain_payload=prefix
        )
        assert result == ("reused" if reused else "built")
        assert not (tmp_path / "unused-packed").exists()
        if reused:
            assert (
                json.loads((prefix / "source-qualification.json").read_text())
                == qualification
            )
            assert commands == []
        else:
            application.save_sdk(
                "a" * 40,
                "verified-image",
                tmp_path / "in-run",
                shadow=True,
                source_prefix=prefix,
                reuse_archive=True,
            )
            restored = tmp_path / "restored"
            application.artifacts.unpack(
                "linux-sdk",
                sdk.artifacts.fingerprint("linux-sdk"),
                tmp_path / "in-run",
                restored,
            )
            assert (restored / "image.tar").read_bytes() == b"saved once"
            assert (
                len([cmd for cmd in commands if cmd[:3] == ["docker", "image", "save"]])
                == 1
            )
            assert len([cmd for cmd in commands if cmd[:2] == ["docker", "build"]]) == 1
