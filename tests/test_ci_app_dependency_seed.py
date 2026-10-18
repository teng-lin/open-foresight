"""Immutable main objects can migrate without executing old code or compiling."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "app_seed", ROOT / "tools/ci_app_dependency_seed.py"
)
seed = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = seed
SPEC.loader.exec_module(seed)
PREFIX = "src/build/_deps/flatbuffers-build"


def archive(path, entries):
    with tarfile.open(path, "w:gz") as target:
        for name, data, kind, link in entries:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.linkname = link
            member.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
            member.pax_headers = {"mtime": "1234567890.123456789"}
            member.size = len(data) if kind == tarfile.REGTYPE else 0
            target.addfile(
                member, io.BytesIO(data) if kind == tarfile.REGTYPE else None
            )
    return path


def file(name, data=b"object"):
    return name, data, tarfile.REGTYPE, ""


def test_shared_recipe_and_root_keep_original_dependency_settings():
    seed.validate_recipe(ROOT)


@pytest.mark.parametrize("change", ["pin", "flag", "root"])
def test_changed_dependency_contract_requires_requalification(tmp_path, change):
    for name in [
        "cmake/ForesightInferenceDependencies.cmake",
        "packaging/app-dependencies/CMakeLists.txt",
    ]:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text((ROOT / name).read_text())
    target = tmp_path / (
        "packaging/app-dependencies/CMakeLists.txt"
        if change == "root"
        else "cmake/ForesightInferenceDependencies.cmake"
    )
    value = target.read_text()
    if change == "pin":
        value = value.replace("31646a467d2051eb904e0b45de3a73e91fe1c1e3", "a" * 40)
    elif change == "flag":
        value = value.replace("SPM_ENABLE_SHARED OFF", "SPM_ENABLE_SHARED ON")
    else:
        value = value.replace("CMAKE_CXX_STANDARD 20", "CMAKE_CXX_STANDARD 17")
    target.write_text(value)
    with pytest.raises(ValueError, match="changed"):
        seed.validate_recipe(tmp_path)


def profile():
    image = {
        "Architecture": "amd64",
        "Os": "linux",
        "Config": {"Env": ["PATH=/usr/bin"]},
    }
    status = "\n\n".join(
        f"Package: {name}\nStatus: install ok installed\nArchitecture: amd64\nVersion: {version}"
        for name, version in [
            ("gcc-13", seed.COMPILER),
            ("g++-13", seed.COMPILER),
            ("libstdc++-13-dev", seed.COMPILER),
            ("libc6", "2.39-0ubuntu8.6"),
            ("cmake", "3.28.3-1build7"),
        ]
    )
    return image, status, 'ID=ubuntu\nVERSION_ID="24.04"\n'


def test_sdk_compatibility_uses_actual_compiler_not_whole_sdk_identity():
    image, status, release = profile()
    image["Id"] = "sha256:" + "b" * 64
    result = seed.validate_sdk_profile(image, status, release)
    assert result["compiler_package"] == seed.COMPILER
    assert result["platform"] == "linux/amd64"


@pytest.mark.parametrize(
    "change", ["arch", "os", "compiler", "stdlib", "glibc", "cmake", "env"]
)
def test_incompatible_compiler_or_abi_never_silently_rebuilds(change):
    image, status, release = profile()
    if change == "arch":
        image["Architecture"] = "arm64"
    elif change == "os":
        release = 'ID=debian\nVERSION_ID="12"\n'
    elif change == "compiler":
        status = status.replace(seed.COMPILER, "14.2.0", 1)
    elif change == "stdlib":
        status = status.replace("Package: libstdc++-13-dev", "Package: other")
    elif change == "glibc":
        status = status.replace("2.39-", "2.38-")
    elif change == "cmake":
        status = status.replace("3.28.3", "3.29.0")
    else:
        image["Config"]["Env"].append("CXXFLAGS=-march=native")
    with pytest.raises(ValueError):
        seed.validate_sdk_profile(image, status, release)


def test_layer_overlay_preserves_objects_modes_nanoseconds_and_scoped_whiteouts(
    tmp_path,
):
    first = archive(
        tmp_path / "1.gz",
        [
            (PREFIX, b"", tarfile.DIRTYPE, ""),
            file(PREFIX + "/keep.o"),
            file(PREFIX + "/gone.o"),
            file("etc/passwd", b"ignored"),
        ],
    )
    second = archive(
        tmp_path / "2.gz",
        [file(PREFIX + "/.wh.gone.o", b""), file(PREFIX + "/new.o", b"new")],
    )
    output = tmp_path / "seed"
    output.mkdir()
    seed.apply_layers([first, second], output)
    assert (output / PREFIX / "keep.o").read_bytes() == b"object"
    assert not (output / PREFIX / "gone.o").exists()
    assert not (output / "etc").exists()
    assert (output / PREFIX / "new.o").stat().st_mtime_ns == 1234567890123456789
    assert (output / PREFIX).stat().st_mtime_ns == 1234567890123456789
    assert (output / PREFIX / "new.o").stat().st_mode & 0o777 == 0o644


def test_opaque_parent_whiteout_only_removes_allowlisted_trees(tmp_path):
    first = archive(tmp_path / "1.gz", [file(PREFIX + "/old.o")])
    second = archive(
        tmp_path / "2.gz",
        [file("src/build/_deps/.wh..wh..opq", b""), file(PREFIX + "/new.o")],
    )
    output = tmp_path / "seed"
    output.mkdir()
    seed.apply_layers([first, second], output)
    assert not (output / PREFIX / "old.o").exists()
    assert (output / PREFIX / "new.o").is_file()


@pytest.mark.parametrize(
    "entries",
    [
        [file("/tmp/escape")],
        [file(PREFIX + "/../../escape")],
        [(PREFIX + "/escape", b"", tarfile.SYMTYPE, "/tmp")],
        [(PREFIX + "/escape", b"", tarfile.SYMTYPE, "../../../../outside")],
        [(PREFIX + "/device", b"", tarfile.CHRTYPE, "")],
        [(PREFIX + "/hard", b"", tarfile.LNKTYPE, "etc/passwd")],
    ],
)
def test_unsafe_paths_links_and_devices_rejected(tmp_path, entries):
    layer = archive(tmp_path / "bad.gz", entries)
    output = tmp_path / "out"
    output.mkdir()
    with pytest.raises(ValueError):
        seed.apply_layers([layer], output)


def test_safe_relative_source_symlink_kept_without_following_it(tmp_path):
    base = "src/build/_deps/flatbuffers-src"
    layer = archive(
        tmp_path / "good.gz",
        [
            file(base + "/LICENSE"),
            (base + "/nested/link", b"", tarfile.SYMTYPE, "../LICENSE"),
        ],
    )
    output = tmp_path / "out"
    output.mkdir()
    seed.apply_layers([layer], output)
    assert (output / base / "nested/link").is_symlink()
    assert (output / base / "nested/link").read_bytes() == b"object"


def test_materialization_checks_output_hash_and_preserves_existing_output(tmp_path):
    layer = archive(tmp_path / "data.gz", [file(PREFIX + "/flatc", b"compiler")])
    output = tmp_path / "seed"
    with patch.object(
        seed, "REQUIRED", {PREFIX + "/flatc": hashlib.sha256(b"compiler").hexdigest()}
    ):
        seed.materialize([layer], output, {"image_id": "trusted"})
    evidence = json.loads((output / "qualification.json").read_text())
    assert evidence["source_commit"] == seed.SOURCE
    assert evidence["original_sdk"] == seed.SDK
    assert evidence["consumer_sdk"] == {"image_id": "trusted"}
    with pytest.raises(ValueError, match="existing successful"):
        seed.materialize([layer], output, {})
    assert (output / PREFIX / "flatc").read_bytes() == b"compiler"
    with pytest.raises(ValueError, match="missing or changed"):
        seed.materialize([layer], tmp_path / "bad", {})
    assert not (tmp_path / "bad").exists()


def test_successful_exact_main_producer_required():
    run = {
        "repository": {"full_name": seed.REPOSITORY},
        "head_sha": seed.SOURCE,
        "head_branch": "main",
        "event": "push",
        "path": ".github/workflows/macos.yml",
        "status": "completed",
        "conclusion": "success",
    }
    job = {
        "run_id": seed.RUN,
        "run_attempt": 1,
        "name": "linux-bundle",
        "conclusion": "success",
    }

    def request(command, **kwargs):
        assert kwargs["timeout"] > 0
        return json.dumps(job if "/jobs/" in command[-1] else run)

    seed.verify_producer(request)
    for obj, key, value in [
        (run, "head_sha", "a" * 40),
        (run, "event", "pull_request"),
        (run, "head_branch", "other"),
        (run, "path", ".github/workflows/other.yml"),
        (job, "run_attempt", 2),
        (job, "conclusion", "failure"),
    ]:
        old = obj[key]
        obj[key] = value
        with pytest.raises(ValueError):
            seed.verify_producer(request)
        obj[key] = old


def test_corrupt_cached_blob_fails_without_deleting_it(tmp_path):
    path = tmp_path / ("a" * 64)
    path.write_bytes(b"bad")
    with pytest.raises(ValueError, match="Invalid preserved"):
        seed.fetch(tmp_path, "a" * 64, 3, "unused", "secret")
    assert path.read_bytes() == b"bad"


def tar_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as target:
        for name, value in entries.items():
            member = tarfile.TarInfo(name)
            member.size = len(value)
            target.addfile(member, io.BytesIO(value))
    return output.getvalue()


def test_reviewed_exact_toolchain_proof_is_bound_to_old_main_producer(tmp_path):
    proof = seed.toolchain_proof()
    assert len(proof["headers"]) == 421
    assert len(proof["files"]) == 489
    assert "/usr/libexec/gcc/x86_64-linux-gnu/13/cc1plus" in proof["files"]
    assert proof["provenance"]["object_dependency_files"] == 93
    assert proof["provenance"]["producer_job"] == seed.JOB
    path = tmp_path / "tools/ubuntu_app_dependency_seed.json"
    path.parent.mkdir()
    path.write_text(json.dumps(proof) + " ")
    with pytest.raises(ValueError, match="proof changed"):
        seed.toolchain_proof(tmp_path)


def test_only_consumed_header_hashes_are_compared_and_runtime_changes_fail():
    files = {
        "/usr/include/consumed.h": b"header",
        "/usr/libexec/gcc/cc1plus": b"compiler",
        "/usr/lib/libc.so": b"runtime",
    }
    proof = {
        "files": {
            name: hashlib.sha256(data).hexdigest() for name, data in files.items()
        }
    }
    calls = []

    def request(command, **kwargs):
        assert kwargs["timeout"] > 0
        assert command[1] == "cp"
        calls.append(command)
        source = command[-2].split(":", 1)[1]
        if source == "/usr/include":
            return tar_bytes(
                {
                    "include/consumed.h": files["/usr/include/consumed.h"],
                    "include/unrelated.h": b"unrelated header may change",
                }
            )
        return tar_bytes({Path(source).name: files[source]})

    assert seed.verify_toolchain_files("a" * 64, proof, request)["matched_files"] == 3
    assert len(calls) == 3  # One batched header copy and two explicitly consumed files.
    files["/usr/lib/libc.so"] = b"new ABI bytes"
    with pytest.raises(ValueError, match="not permission to rebuild"):
        seed.verify_toolchain_files("a" * 64, proof, request)


def test_sdk_inspection_never_starts_or_executes_container(tmp_path):
    image, status, release = profile()
    image["Id"] = "sha256:" + "c" * 64
    commands = []

    def request(command, **kwargs):
        commands.append(command)
        if command[1:3] == ["image", "inspect"]:
            return json.dumps(image)
        if command[1] == "create":
            assert (
                command[-1] == image["Id"]
            )  # Inspect immutable image, not a mutable tag.
            return "d" * 64
        if command[1] == "cp":
            destination = Path(command[-1])
            if command[-2].endswith("/status"):
                destination.write_text(status)
            elif "-L" in command:
                destination.write_text(release)
            else:
                # The pinned Ubuntu base contains this exact relative symlink.
                # Docker cp preserves it unless --follow-link is requested.
                destination.symlink_to("../usr/lib/os-release")
        return b""

    with (
        patch.object(seed, "toolchain_proof", return_value={}),
        patch.object(
            seed, "verify_toolchain_files", return_value={"matched_files": 489}
        ),
    ):
        result = seed.sdk_profile("qualified-sdk:local", request)
    assert result["matched_files"] == 489
    assert commands[-1] == ["docker", "rm", "d" * 64]
    assert all(command[1] not in ("run", "exec", "build") for command in commands)


def test_failed_sdk_proof_still_removes_only_disposable_unstarted_container():
    image, status, release = profile()
    image["Id"] = "sha256:" + "c" * 64
    commands = []

    def request(command, **kwargs):
        commands.append(command)
        if command[1] == "image":
            return json.dumps(image)
        if command[1] == "create":
            return "d" * 64
        if command[1] == "cp":
            Path(command[-1]).write_text(
                status if command[-2].endswith("/status") else release
            )
        return b""

    with (
        patch.object(seed, "toolchain_proof", side_effect=ValueError("bad proof")),
        pytest.raises(ValueError, match="bad proof"),
    ):
        seed.sdk_profile("qualified-sdk:local", request)
    assert commands[-1] == ["docker", "rm", "d" * 64]


def test_verified_blob_is_reused_without_another_download(tmp_path):
    payload = b"verified layer"
    identity = hashlib.sha256(payload).hexdigest()
    with patch.object(
        seed.urllib.request, "urlopen", return_value=io.BytesIO(payload)
    ) as opened:
        result = seed.fetch(
            tmp_path, identity, len(payload), "blobs/sha256:" + identity, "token"
        )
        assert result.read_bytes() == payload
        assert opened.call_args.args[0].full_url.startswith(seed.REGISTRY)
        assert opened.call_args.kwargs["timeout"] == 120
    with patch.object(
        seed.urllib.request,
        "urlopen",
        side_effect=AssertionError("cache should be warm"),
    ):
        assert seed.fetch(tmp_path, identity, len(payload), "unused", "token") == result


@pytest.mark.parametrize("failure", ["digest", "oversize", "network"])
def test_download_failure_never_becomes_a_compile_or_deletes_other_blobs(
    tmp_path, failure
):
    preserved = tmp_path / "existing-successful-layer"
    preserved.write_bytes(b"preserve")
    identity = hashlib.sha256(b"wanted").hexdigest()
    value = b"wrong!" if failure == "digest" else b"too many bytes"
    options = (
        {"side_effect": OSError("network unavailable")}
        if failure == "network"
        else {"return_value": io.BytesIO(value)}
    )
    with (
        patch.object(seed.urllib.request, "urlopen", **options),
        pytest.raises((ValueError, OSError)),
    ):
        seed.fetch(tmp_path, identity, 6, "blobs/sha256:" + identity, "token")
    assert not (tmp_path / identity).exists()
    assert preserved.read_bytes() == b"preserve"
    assert sorted(path.name for path in tmp_path.iterdir()) == [preserved.name]


def inspect_recorded_toolchain_changes(monkeypatch, changes):
    """Exercise policy with previously verified file hashes, without Docker/ELF execution.

    Tar decoding and byte hashing have separate real tar-stream regressions above.
    This fixture represents the independent 489-file inspection, including the
    exact three current archive hashes rather than a matching SONAME alone.
    """
    proof = seed.toolchain_proof()
    actual = {**proof["files"], **changes}

    def request(command, **kwargs):
        assert command[:2] == ["docker", "cp"]
        assert kwargs["timeout"] > 0
        source = command[-2].split(":", 1)[1]
        if source in ("/usr/include", "/usr/lib/gcc/x86_64-linux-gnu/13/include"):
            values = {
                path: digest
                for path, digest in actual.items()
                if path.startswith(source + "/")
            }
        else:
            values = {source: actual[source]}
        return json.dumps(values).encode()

    monkeypatch.setattr(seed, "copied_hashes", lambda data, *args: json.loads(data))
    return seed.verify_toolchain_files("a" * 64, proof, request)


def test_exact_three_cmake_runtime_revisions_requalify_without_changing_compiler(
    monkeypatch,
):
    compatibility = seed.tool_runtime_compatibility()
    replacements = compatibility["replacements"]
    actual = {path: record["consumer_sha256"] for path, record in replacements.items()}
    result = inspect_recorded_toolchain_changes(monkeypatch, actual)
    assert result["matched_files"] == 486
    assert result["compatibility_proof_sha256"] == seed.TOOL_RUNTIME_COMPATIBILITY
    assert set(result["compatible_cmake_runtime_files"]) == seed.CMAKE_RUNTIME_PATHS
    assert (
        seed.toolchain_proof()["files"]["/usr/bin/cmake"]
        == compatibility["consumer"]["sha256"]
    )
    for path, record in replacements.items():
        assert record["original_sha256"] == seed.toolchain_proof()["files"][path]
        assert record["original_sha256"] != record["consumer_sha256"]
        assert record["abi"]["soname"] == Path(path).name
        assert record["abi"]["elf_class"] == "ELF64"
        assert record["abi"]["export_count"] > 0


@pytest.mark.parametrize(
    "extra",
    [
        {"/usr/include/assert.h": "f" * 64},
        {"/usr/bin/c++": "f" * 64},
        {"/usr/bin/cmake": "f" * 64},
        {"/usr/lib/x86_64-linux-gnu/libc.so.6": "f" * 64},
        {"/usr/lib/x86_64-linux-gnu/libarchive.so.13": "f" * 64},
    ],
)
def test_runtime_migration_never_authorizes_other_bytes_or_future_revisions(
    monkeypatch, extra
):
    actual = {
        path: record["consumer_sha256"]
        for path, record in seed.tool_runtime_compatibility()["replacements"].items()
    }
    actual.update(extra)
    with pytest.raises(ValueError, match="not permission to rebuild"):
        inspect_recorded_toolchain_changes(monkeypatch, actual)


def test_unchanged_toolchain_does_not_require_runtime_exception(monkeypatch):
    result = inspect_recorded_toolchain_changes(monkeypatch, {})
    assert result == {"proof_sha256": seed.TOOLCHAIN_PROOF, "matched_files": 489}


def test_runtime_compatibility_record_keeps_verified_archive_and_original_receipt():
    record = seed.tool_runtime_compatibility()
    original = next(
        entry
        for entry in json.loads(
            (seed.ROOT / "tools/sdk_approved_legacy.json").read_text()
        )["entries"]
        if entry["component"] == "linux-sdk"
    )
    provenance = record["provenance"]
    assert provenance["artifact_id"] == original["artifact_id"]
    assert provenance["artifact_digest"] == original["artifact_digest"]
    assert provenance["original_source_receipt"] == original["source_receipt"]
    assert provenance["producer_source"] == original["producer_source"]
    assert (
        provenance["archive_sha256"]
        == "649516536799db378d232b3db260e50ddb449bf1d63a4f77945644b1a155c88b"
    )
    assert "flatc" in record["consumer"]["excluded_consumer_roots"]
    assert record["original_toolchain_proof_sha256"] == seed.TOOLCHAIN_PROOF


def test_runtime_compatibility_record_tampering_requires_review(tmp_path):
    target = tmp_path / "tools/ubuntu_app_dependency_runtime_compatibility.json"
    target.parent.mkdir()
    original = (
        seed.ROOT / "tools/ubuntu_app_dependency_runtime_compatibility.json"
    ).read_bytes()
    target.write_bytes(original + b" ")
    with pytest.raises(ValueError, match="changed without review"):
        seed.tool_runtime_compatibility(tmp_path)
