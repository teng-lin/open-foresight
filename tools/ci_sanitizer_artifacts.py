#!/usr/bin/env python3
"""Qualify installed sanitizer SDKs; a cache miss never grants build permission."""

import argparse
import ast
import builtins
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import symtable
import sys
import tarfile
import tempfile
import zipfile

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.ci_git import ensure_commit  # noqa: E402
from tools.sanitizer_runtime import address_runtime  # noqa: E402
from tools.ci_producer_trust import PRODUCERS  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = PRODUCERS["sanitizer-sdk"].workflows[0]
FILES = (
    "tools/build_sanitizer_sdk.py",
    "tools/sanitizer_runtime.py",
    "packaging/sanitizer-grpc.cmake",
    "packaging/minimal-grpc.cmake",
)
IMPORTED = (
    "GRPC_COMMIT",
    "PROTOBUF_COMMIT",
    "MODULES",
    "checkout",
    "require_clean_sources",
    "run",
)
JOBS = {kind: jobs[0] for kind, jobs in PRODUCERS["sanitizer-sdk"].jobs.items()}
INSTALL = {
    "address": "Install the native compiler and test dependencies",
    "thread": "Install the separate TSan toolchain",
}
BUILD = {
    "address": "Build the pinned instrumented gRPC and protobuf closure",
    "thread": "Build the separately instrumented TSan SDK",
}
REQUIRED = (
    "bin/protoc",
    "bin/grpc_cpp_plugin",
    "lib/cmake/grpc/gRPCConfig.cmake",
    "lib/libprotobufd.so",
    "lib/libgrpc++.so",
)
HEX = r"[a-f0-9]{64}"
MAX_BYTES = 2 * 1024**3


class CacheProducerNotFound(ValueError):
    """A cache may contain copied SDK bytes without an original compile step."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_source(root, name, source=None):
    if source is None:
        return (root / name).read_bytes()
    return subprocess.check_output(
        ["git", "show", f"{source}:{name}"], cwd=root, timeout=30
    )


def macos_projection(data):
    """Hash only imported definitions and their strict, transitive globals."""
    text = data.decode()
    tree = ast.parse(text)
    symbols = symtable.symtable(text, "<sdk>", "exec")
    definitions: dict[str, ast.AST] = {}
    imports: dict[str, ast.AST] = {}
    allowed = {
        "argparse",
        "json",
        "os",
        "pathlib",
        "platform",
        "shutil",
        "subprocess",
        "sys",
        "tempfile",
    }
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            names = [item.name for item in node.names]
            modules = names if isinstance(node, ast.Import) else [node.module]
            if any(module not in allowed for module in modules):
                raise ValueError("Unsupported imported SDK module")
            for item in node.names:
                imports[item.asname or item.name] = node
        elif isinstance(node, ast.FunctionDef):
            if node.decorator_list:
                raise ValueError("Unsupported imported SDK decorator")
            for value in (
                *node.args.defaults,
                *[v for v in node.args.kw_defaults if v is not None],
            ):
                ast.literal_eval(value)
            if node.returns is not None or any(
                arg.annotation is not None
                for arg in (
                    *node.args.posonlyargs,
                    *node.args.args,
                    *node.args.kwonlyargs,
                )
            ):
                raise ValueError("Unsupported imported SDK annotations")
            definitions[node.name] = node
        elif (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
        ):
            name = node.targets[0].id
            if name != "ROOT":
                ast.literal_eval(node.value)
            elif ast.dump(node.value) != ast.dump(
                ast.parse("Path(__file__).resolve().parents[1]", mode="eval").body
            ):
                raise ValueError("Unsupported imported SDK root")
            definitions[name] = node
        elif (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            continue
        elif isinstance(node, ast.If) and ast.dump(node.test) == ast.dump(
            ast.parse('__name__ == "__main__"', mode="eval").body
        ):
            continue
        else:
            raise ValueError("Unsupported imported SDK top-level behavior")
    bindings: list[str] = []
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            bindings.extend(alias.asname or alias.name for alias in node.names)
        elif isinstance(node, ast.FunctionDef):
            bindings.append(node.name)
        elif isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            bindings.append(node.targets[0].id)
    if len(bindings) != len(set(bindings)) or any(
        name in vars(builtins) for name in bindings
    ):
        raise ValueError("Duplicate or builtin-shadowing imported SDK binding")
    result = {}
    pending = list(IMPORTED)
    while pending:
        name = pending.pop()
        if name in result or name in vars(builtins):
            continue
        node = definitions.get(name, imports.get(name))
        if node is None:
            raise ValueError("Unqualified imported SDK global: " + name)
        result[name] = ast.dump(node, include_attributes=False)
        if isinstance(node, ast.FunctionDef):
            if any(
                isinstance(
                    child,
                    (ast.Lambda, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef),
                )
                for statement in node.body
                for child in ast.walk(statement)
            ):
                raise ValueError("Unsupported nested imported SDK definition")
            if any(
                isinstance(child, ast.Name)
                and child.id
                in {
                    "eval",
                    "exec",
                    "globals",
                    "locals",
                    "getattr",
                    "setattr",
                    "delattr",
                    "vars",
                    "__import__",
                    "compile",
                    "open",
                }
                for child in ast.walk(node)
            ):
                raise ValueError("Opaque imported SDK global access")
            scope = symbols.lookup(name).get_namespace()
            pending.extend(
                symbol.get_name()
                for symbol in scope.get_symbols()
                if symbol.is_global()
            )
    return result


def recipe(root, kind, source=None):
    def read(name):
        return read_source(root, name, source)

    workflow = yaml.safe_load(read(WORKFLOW))
    job = workflow["jobs"][JOBS[kind]]
    install = [
        step["run"] for step in job["steps"] if step.get("name") == INSTALL[kind]
    ]
    build = [step["run"] for step in job["steps"] if step.get("name") == BUILD[kind]]
    if len(install) != 1 or len(build) != 1:
        raise ValueError("Missing sanitizer build recipe steps")
    return {
        "schema": 1,
        "kind": kind,
        "files": {name: sha(read(name)) for name in FILES},
        "imported_sdk": macos_projection(read("tools/build_macos_sdk.py")),
        "runner": job["runs-on"],
        "container": job.get("container"),
        "install": install[0],
        "build": build[0],
        "workflow_environment": workflow.get("env", {}),
        "job_environment": job.get("env", {}),
        "defaults": [workflow.get("defaults", {}), job.get("defaults", {})],
        "build_environment": next(
            step.get("env", {})
            for step in job["steps"]
            if step.get("name") == BUILD[kind]
        ),
        "install_environment": next(
            step.get("env", {})
            for step in job["steps"]
            if step.get("name") == INSTALL[kind]
        ),
    }


def expected_stamp(root, kind, compiler):
    tree = ast.parse((root / "tools/build_macos_sdk.py").read_text())
    constants = {
        node.targets[0].id: ast.literal_eval(node.value)
        for node in tree.body
        if isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id in IMPORTED[:3]
    }
    builder = ast.parse((root / FILES[0]).read_text())
    flags = next(
        ast.literal_eval(node.value)
        for node in builder.body
        if isinstance(node, ast.Assign)
        and any(
            isinstance(target, ast.Name) and target.id == "FLAGS"
            for target in node.targets
        )
    )
    return {
        "grpc_commit": constants["GRPC_COMMIT"],
        "protobuf_commit": constants["PROTOBUF_COMMIT"],
        "compiler": compiler.splitlines()[0],
        "flags": flags
        if kind == "address"
        else "-O1 -g -shared-libsan -fsanitize=thread -fno-omit-frame-pointer",
        "sanitizer": kind,
        "recipe_sha256": sha(b"".join((root / name).read_bytes() for name in FILES)),
    }


def environment(kind, prefix):
    if any(
        os.environ.get(name)
        for name in (
            "CC",
            "CXX",
            "CFLAGS",
            "CXXFLAGS",
            "CPPFLAGS",
            "LDFLAGS",
            "CPATH",
            "CPLUS_INCLUDE_PATH",
            "LIBRARY_PATH",
            "CMAKE_PREFIX_PATH",
            "CMAKE_TOOLCHAIN_FILE",
            "CMAKE_GENERATOR",
            "CMAKE_PROJECT_INCLUDE",
            "CMAKE_PROJECT_INCLUDE_BEFORE",
        )
    ):
        raise ValueError("Unqualified sanitizer compiler environment override")

    def output(*command):
        return subprocess.check_output(command, text=True, timeout=30).strip()

    compiler = output("clang++", "--version")
    cxx, cc = shutil.which("clang++"), shutil.which("clang")
    if not cxx or not cc:
        raise FileNotFoundError("Both sanitizer compilers must be installed")
    runtime = address_runtime(kind=kind)
    if shutil.which("pacman"):
        packages = output("pacman", "-Q").splitlines()
        names = {
            "gcc",
            "gcc-libs",
            "glibc",
            "openssl",
            "zlib",
            "clang",
            "compiler-rt",
            "llvm",
            "llvm-libs",
            "binutils",
            "cmake",
            "ninja",
        }
        packages = [row for row in packages if row.split()[0] in names]
    else:
        packages = output("dpkg-query", "-W", "-f=${Package} ${Version}\n").splitlines()
        packages = [
            row
            for row in packages
            if re.match(
                r"^(clang|libclang|llvm|libllvm|libc6|libstdc\+\+|libgcc|binutils|libssl|zlib|cmake|ninja-build)",
                row,
            )
        ]
    return {
        "system": platform.system(),
        "machine": platform.machine(),
        "target": output("clang++", "-dumpmachine"),
        "prefix": str(prefix.resolve()),
        "compiler": compiler,
        "compiler_sha256": artifacts.digest(Path(cxx)),
        "c_compiler_sha256": artifacts.digest(Path(cc)),
        "runtime": str(runtime),
        "runtime_sha256": artifacts.digest(runtime),
        "packages": sorted(packages),
    }


def identity(inputs, abi):
    return sha(
        json.dumps({"recipe": inputs, "environment": abi}, sort_keys=True).encode()
    )


def verify_environment_profile(root, kind, prefix):
    """Preserve the published SDK's actual compiler/ABI while freezing repos.

    Repository selection is qualification plumbing, not a new SDK build input:
    compare every recorded environment field before allowing existing SDK use.
    """
    profiles = json.loads(
        (root / "tools/sanitizer_toolchain_profiles.json").read_text()
    )
    if profiles.get("schema") != 1:
        raise ValueError("Unsupported sanitizer toolchain profile")
    profile = profiles["profiles"][kind]
    workflow = yaml.safe_load((root / WORKFLOW).read_bytes())
    steps = workflow["jobs"][JOBS[kind]]["steps"]
    selections = [
        step.get("run")
        for step in steps
        if step.get("name", "").startswith("Select the verified ")
    ]
    if selections != [profile["repository_setup"]]:
        raise ValueError(
            "Sanitizer repository selection differs from its verified profile"
        )
    actual = environment(kind, prefix)
    changed = sorted(
        key
        for key in set(actual) | set(profile["environment"])
        if actual.get(key) != profile["environment"].get(key)
    )
    if changed:
        raise RuntimeError(
            "Sanitizer compiler/ABI environment differs from preserved successful SDK "
            f"artifact {profile['qualified_sdk']['artifact_id']}: {', '.join(changed)}. "
            "Preserve existing SDKs; qualify the runner/package change before replacing "
            "this profile. This mismatch does not authorize an SDK rebuild."
        )
    return {
        "verified_environment_artifact": profile["qualified_sdk"]["artifact_id"],
        "repository_snapshot": profile["snapshot"],
    }


def inventory(prefix):
    result = {}
    for path in sorted(prefix.rglob("*")):
        name = path.relative_to(prefix).as_posix()
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve(
                strict=True
            ).is_relative_to(prefix.resolve()):
                raise ValueError("SDK link escapes installed prefix: " + name)
            result[name] = {"mode": mode, "link": target}
        elif path.is_file():
            result[name] = {"mode": mode, "sha256": artifacts.digest(path)}
        elif not path.is_dir():
            raise ValueError("Special file in installed SDK")
    return result


def verify_installed(root, kind, prefix, abi):
    if prefix.is_symlink() or not prefix.is_dir():
        raise ValueError("Installed sanitizer prefix is absent")
    stamp = prefix / "sanitizer-sdk.json"
    if stamp.is_symlink() or json.loads(stamp.read_text()) != expected_stamp(
        root, kind, abi["compiler"]
    ):
        raise ValueError("Installed sanitizer SDK recipe/compiler/flags mismatch")
    for name in REQUIRED:
        path = prefix / name
        if not path.is_file() or not path.resolve().is_relative_to(prefix.resolve()):
            raise ValueError("Incomplete sanitizer prefix: " + name)
    inventory(prefix)
    runtime = str(Path(abi["runtime"]).parent)
    env = {
        **os.environ,
        "LD_LIBRARY_PATH": f"{runtime}:{prefix}/lib",
        "ASAN_OPTIONS": "detect_leaks=0:halt_on_error=1",
        "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
    }
    subprocess.run(
        [str(prefix / "bin/protoc"), "--version"], env=env, check=True, timeout=30
    )


def trusted(repository, run, own_pr, root=ROOT, kind="address"):
    if (
        not PRODUCERS["sanitizer-sdk"].matches_run(run)
        or (run.get("head_repository") or {}).get("full_name") != repository
    ):
        return False
    if run.get("event") == "push" and run.get("head_branch") == "main":
        return True
    if (
        run.get("event") == "pull_request"
        and own_pr > 0
        and any(pr.get("number") == own_pr for pr in run.get("pull_requests", []))
    ):
        return True
    return run.get("event") in (
        "pull_request",
        "workflow_dispatch",
    ) and (
        artifacts.merged_source(repository, run)
        or approved_final(repository, run, root, kind)
    )


def control_closure(root, source=None):
    """Bind all local executable producer controls, preserving irrelevant Mac code."""
    if source:
        ensure_commit(root, source)
        rows = subprocess.check_output(
            ["git", "ls-tree", "-r", "-z", source], cwd=root, timeout=30
        ).split(b"\0")
        names = [row.split(b"\t", 1)[1].decode() for row in rows if row]
    else:
        names = (
            subprocess.check_output(
                ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                cwd=root,
                timeout=30,
            )
            .decode()
            .split("\0")
        )
    result = {}
    for name in names:
        if not (
            name.startswith(("tools/", ".github/", "packaging/"))
            or name.startswith("requirements-")
            or name == "tests/test_sanitizer_runtime.py"
        ):
            continue
        data = read_source(root, name, source)
        result[name] = (
            macos_projection(data) if name == "tools/build_macos_sdk.py" else sha(data)
        )
    return result


def approved_final(repository, run, root, kind):
    """An intermediate producer may inherit only unchanged reviewed final controls."""
    producer = run.get("head_sha")
    for final in artifacts.final_approval.approved_final_heads(
        repository,
        run,
        workflow=WORKFLOW,
        api=artifacts.api,
        merged_source=artifacts.merged_source,
    ):
        ensure_commit(root, producer)
        ensure_commit(root, final)
        if recipe(root, kind, producer) == recipe(
            root, kind, final
        ) and control_closure(root, producer) == control_closure(root, final):
            return True
    return False


def cache_origin(root, kind, repository, own_pr, cache_key, abi):
    """Recover work only from an exact cache upload's successful SDK steps.

    Application failure after cache-save does not invalidate compiled work. The
    new qualifying artifact job must still succeed before cross-PR consumption.
    """
    from urllib.parse import urlencode
    from datetime import datetime, timedelta

    compiler_hash = sha((abi["compiler"] + "\n").encode())
    if compiler_hash not in cache_key or not re.fullmatch(
        r"(?:sanitizer-sdk-clang-[0-9.]+|thread-sdk)-" + HEX + "-" + HEX, cache_key
    ):
        raise ValueError("Scoped cache key does not bind the current compiler")
    scope = os.environ.get("GITHUB_REF") or (
        f"refs/pull/{own_pr}/merge" if own_pr else "refs/heads/main"
    )
    selected = []
    for reference in dict.fromkeys((scope, "refs/heads/main")):
        response = artifacts.api(
            repository,
            "actions/caches?"
            + urlencode({"key": cache_key, "ref": reference, "per_page": 100}),
        )
        selected = [
            item
            for item in response["actions_caches"]
            if item.get("key") == cache_key and item.get("ref") == reference
        ]
        if selected:
            break
    if len(selected) != 1:
        raise ValueError(
            "Cannot uniquely bind restored cache to its original upload; preserve it for inspection"
        )
    cache = selected[0]
    expected = recipe(root, kind)
    for page in range(1, 11):
        batch = artifacts.api(
            repository,
            f"actions/workflows/native-sanitizers.yml/runs?per_page=100&page={page}",
        )["workflow_runs"]
        for run in batch:
            if (
                not PRODUCERS["sanitizer-sdk"].matches_run(run)
                or (run.get("head_repository") or {}).get("full_name") != repository
            ):
                continue
            if cache["ref"].startswith("refs/pull/"):
                number = int(cache["ref"].split("/")[2])
                if run.get("event") != "pull_request" or not any(
                    pr.get("number") == number for pr in run.get("pull_requests", [])
                ):
                    continue
            elif run.get("head_branch") != "main" or run.get("event") not in (
                "push",
                "workflow_dispatch",
            ):
                continue
            for job in artifacts.dependency_jobs(repository, run["id"]):
                if job.get("name") != JOBS[kind] or job.get("status") != "completed":
                    continue
                build = [
                    step
                    for step in job.get("steps", [])
                    if step.get("name") == BUILD[kind]
                    and step.get("conclusion") == "success"
                ]
                saves = [
                    step
                    for step in job.get("steps", [])
                    if step.get("conclusion") == "success"
                    and (
                        step.get("name")
                        == "Save the validated SDK before application checks"
                        or step.get("name", "").startswith("Run actions/cache/save@")
                    )
                ]
                if len(build) != 1 or len(saves) != 1:
                    continue

                def parse(value):
                    return datetime.fromisoformat(value.replace("Z", "+00:00"))

                if not (
                    parse(build[0]["completed_at"])
                    <= parse(saves[0]["started_at"])
                    <= parse(cache["created_at"])
                    < parse(saves[0]["completed_at"]) + timedelta(seconds=1)
                ):
                    continue
                source = run.get("head_sha", "")
                ensure_commit(root, source)
                if recipe(root, kind, source) != expected:
                    raise ValueError("Original scoped cache SDK build inputs differ")
                # Frozen migration for the already running PR119 producers. Its
                # old workflow has no artifact wrapper; never execute that source.
                legacy = (
                    run["id"] == 39167769695
                    and source == "2c083383ae9fad6f016a90bc9aee1cd8284f19c0"
                    and sha(read_source(root, WORKFLOW, source))
                    == "329bf8bd60647babdad99cbc8008dd88b74693ace1322fba1c5752dfb489bbc9"
                    and all(
                        read_source(root, name, source) == read_source(root, name)
                        for name in (*FILES, "tools/build_macos_sdk.py")
                    )
                )
                if (
                    not legacy
                    and control_closure(root, source) != control_closure(root)
                    and not (
                        (
                            run.get("event") == "push"
                            and run.get("head_branch") == "main"
                        )
                        or artifacts.merged_source(repository, run)
                        or approved_final(repository, run, root, kind)
                    )
                ):
                    raise ValueError(
                        "Scoped cache producer controls need an explicit reviewed migration"
                    )
                help_text = subprocess.check_output(
                    ["gh", "api", "--help"], text=True, timeout=30
                )
                options = (
                    ["--allow-escape-sequences"]
                    if "--allow-escape-sequences" in help_text
                    else []
                )
                log = subprocess.check_output(
                    [
                        "gh",
                        "api",
                        *options,
                        f"repos/{repository}/actions/jobs/{job['id']}/logs",
                    ],
                    text=True,
                    timeout=120,
                )
                commits = re.findall(
                    r"git log -1 --format=%H\r?\n\S+\s+([a-f0-9]{40})(?:\s|$)", log
                )
                if len(commits) != 1:
                    raise ValueError(
                        "Cannot identify the original cache builder checkout"
                    )
                checkout = commits[0]
                ensure_commit(root, checkout)
                if recipe(root, kind, checkout) != recipe(
                    root, kind, source
                ) or control_closure(root, checkout) != control_closure(root, source):
                    raise ValueError(
                        "Original cache checkout differs from its reviewed SDK/control source"
                    )
                return {
                    "kind": "compiled-sdk-scoped-cache",
                    "cache_id": cache["id"],
                    "cache_key": cache_key,
                    "cache_ref": cache["ref"],
                    "cache_created_at": cache["created_at"],
                    "cache_version": cache.get("version"),
                    "source_commit": checkout,
                    "reviewed_run_head": source,
                    "run_id": run["id"],
                    "job_id": job["id"],
                    "run_attempt": job["run_attempt"],
                    "job_conclusion": job.get("conclusion"),
                    "sdk_build_step": build[0],
                    "cache_save_step": saves[0],
                    "legacy_migration": legacy,
                }
        if len(batch) < 100:
            break
    raise CacheProducerNotFound(
        "Restored cache has no independently verified successful SDK-build/cache-save producer; preserve it, do not rebuild"
    )


def unpack_verified(source, destination, receipt):
    archive = source / "payload.tar.gz"
    if artifacts.digest(archive) != receipt["sha256"]:
        raise ValueError("Sanitizer payload digest mismatch")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Preserve existing sanitizer prefix")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        with tarfile.open(archive) as stream:
            members = stream.getmembers()
            if (
                sum(member.size for member in members) > MAX_BYTES
                or len(members) > 100000
            ):
                raise ValueError("Sanitizer payload exceeds extraction budget")
            if any(
                not (member.name == "payload" or member.name.startswith("payload/"))
                for member in members
            ):
                raise ValueError("Unexpected sanitizer archive root")
            stream.extractall(temporary, filter="data")
        prefix = Path(temporary) / "payload"
        if inventory(prefix) != receipt["files"]:
            raise ValueError("Sanitizer prefix file manifest mismatch")
        prefix.rename(destination)


def find(repository, kind, inputs, abi, root, own_pr, prefix, *, verify_existing=False):
    expected = identity(inputs, abi)
    wanted = f"ci-sanitizer-{kind}-{expected}-attempt-"
    page = 1
    while True:
        batch = artifacts.api(
            repository, f"actions/artifacts?per_page=100&page={page}"
        )["artifacts"]
        for artifact in batch:
            if artifact.get("expired") or not artifact.get("name", "").startswith(
                wanted
            ):
                continue
            run = artifacts.api(
                repository, f"actions/runs/{artifact['workflow_run']['id']}"
            )
            if run.get("repository", {}).get("full_name") != repository or not trusted(
                repository, run, own_pr, root, kind
            ):
                continue
            jobs = [
                job
                for job in artifacts.dependency_jobs(repository, run["id"])
                if job.get("name") == JOBS[kind]
                and job.get("conclusion") == "success"
                and artifacts.in_producer_attempt(artifact, job)
            ]
            if not jobs:
                continue
            source = run.get("head_sha", "")
            ensure_commit(root, source)
            if recipe(root, kind, source) != inputs:
                continue
            controls_match = control_closure(root, source) == control_closure(root)
            if not controls_match and not (
                (run.get("event") == "push" and run.get("head_branch") == "main")
                or artifacts.merged_source(repository, run)
                or approved_final(repository, run, root, kind)
            ):
                continue
            # API/auth/protocol/download errors propagate; none authorizes a build.
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                archive = directory / "artifact.zip"
                artifacts.download_zip(repository, artifact, archive)
                with zipfile.ZipFile(archive) as stream:
                    if sorted(stream.namelist()) != ["identity.json", "payload.tar.gz"]:
                        raise ValueError("Unexpected sanitizer artifact members")
                    if stream.getinfo("identity.json").file_size > 32 * 1024**2:
                        raise ValueError("Oversized sanitizer receipt")
                    if stream.getinfo("payload.tar.gz").file_size > MAX_BYTES:
                        raise ValueError("Oversized sanitizer payload")
                    receipt = json.loads(stream.read("identity.json"))
                    expected_fields = {
                        "schema": 1,
                        "kind": kind,
                        "identity": expected,
                        "source_commit": source,
                        "recipe": inputs,
                        "environment": abi,
                    }
                    if not PRODUCERS["sanitizer-sdk"].matches_receipt(receipt) or any(
                        receipt.get(key) != value
                        for key, value in expected_fields.items()
                    ):
                        raise ValueError("Sanitizer producer receipt mismatch")
                    if not any(
                        type(receipt.get("source_run_attempt")) is int
                        and receipt["source_run_attempt"] == job.get("run_attempt", 1)
                        for job in jobs
                    ):
                        raise ValueError("Sanitizer artifact from unsuccessful attempt")
                    if not re.fullmatch(HEX, receipt.get("sha256", "")):
                        raise ValueError("Invalid sanitizer payload digest")
                    with (directory / "payload.tar.gz").open("wb") as output:
                        with stream.open("payload.tar.gz") as payload:
                            shutil.copyfileobj(payload, output)
                if verify_existing:
                    # A main cache can be saved after restoring an artifact, so
                    # it has no successful compile step of its own. Bind every
                    # cached byte/mode/link to the independently verified producer
                    # instead; never execute or replace an unqualified prefix.
                    if (
                        artifacts.digest(directory / "payload.tar.gz")
                        != receipt["sha256"]
                    ):
                        raise ValueError("Sanitizer payload digest mismatch")
                    if inventory(prefix) != receipt["files"]:
                        raise ValueError(
                            "Restored sanitizer cache differs from verified artifact"
                        )
                else:
                    unpack_verified(directory, prefix, receipt)
            return {
                "kind": "verified-artifact",
                "run_id": run["id"],
                "artifact_id": artifact["id"],
                "source_commit": source,
                "compiled_from": receipt["compiled_from"],
            }
        if len(batch) < 100:
            return None
        page += 1


def restore(
    root,
    kind,
    prefix,
    repository,
    own_pr,
    cache_key,
    allow_build=False,
    reason="",
    cache_hit="false",
):
    if prefix.is_symlink() or prefix.parent.resolve() != prefix.parent.absolute():
        raise ValueError("Sanitizer prefix must not traverse directory symlinks")
    inputs = recipe(root, kind)
    abi = environment(kind, prefix)
    if prefix.exists() or prefix.is_symlink():
        if cache_hit != "true":
            raise ValueError(
                "Existing prefix was not restored by an exact scoped-cache hit"
            )
        try:
            compiled = cache_origin(root, kind, repository, own_pr, cache_key, abi)
        except CacheProducerNotFound:
            origin = find(
                repository,
                kind,
                inputs,
                abi,
                root,
                own_pr,
                prefix,
                verify_existing=True,
            )
            if origin is None:
                raise
            origin = {**origin, "kind": "existing-cache-verified-against-artifact"}
        else:
            origin = {"kind": "existing-scoped-cache", "compiled_from": compiled}
        verify_installed(root, kind, prefix, abi)
    else:
        origin = find(repository, kind, inputs, abi, root, own_pr, prefix)
        if origin:
            verify_installed(root, kind, prefix, abi)
        elif allow_build and reason.strip():
            origin = {
                "kind": "explicitly-justified-build",
                "reason": reason.strip(),
                "compiled_from": {
                    "kind": "explicit-build",
                    "source_commit": subprocess.check_output(
                        ["git", "rev-parse", "HEAD"], cwd=root, text=True, timeout=30
                    ).strip(),
                    "run_id": os.environ.get("GITHUB_RUN_ID"),
                    "run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                    "job": JOBS[kind],
                    "reason": reason.strip(),
                },
            }
            print("Sanitizer SDK replacement explicitly justified: " + reason.strip())
        else:
            raise RuntimeError(
                "No verified compatible sanitizer prefix is available in this scope or shared artifacts. Preserve running producers and existing caches; qualify/recover them before building. A replacement requires manual allow_sdk_build and a concrete sdk_rebuild_reason."
            )
    prefix.parent.mkdir(parents=True, exist_ok=True)
    state = prefix.parent / (prefix.name + "-qualification.json")
    state.write_text(
        json.dumps({"recipe": inputs, "environment": abi, "origin": origin}, indent=2)
        + "\n"
    )
    return {"identity": identity(inputs, abi), "qualification": str(state)}


def pack(root, kind, prefix, output):
    state = json.loads(
        (prefix.parent / (prefix.name + "-qualification.json")).read_text()
    )
    inputs, abi = recipe(root, kind), environment(kind, prefix)
    if inputs != state["recipe"] or abi != state["environment"]:
        raise ValueError("Sanitizer inputs changed after qualification")
    verify_installed(root, kind, prefix, abi)
    if output.exists():
        raise ValueError("Choose absent sanitizer artifact output")
    output.mkdir(parents=True)
    archive = output / "payload.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as stream:
        stream.add(prefix, arcname="payload")
    receipt = {
        "schema": 1,
        "kind": kind,
        "identity": identity(inputs, abi),
        "recipe": inputs,
        "environment": abi,
        "sha256": artifacts.digest(archive),
        "files": inventory(prefix),
        "source_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True, timeout=30
        ).strip(),
        "source_run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
        "qualified_from": state["origin"],
        "compiled_from": state["origin"]["compiled_from"],
    }
    (output / "identity.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return {
        "artifact_name": f"ci-sanitizer-{kind}-{receipt['identity']}-attempt-{receipt['source_run_attempt']}"
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("restore", "pack", "verify-environment"))
    parser.add_argument("--kind", choices=JOBS, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--cache-key", default="")
    parser.add_argument("--cache-hit", default="false")
    parser.add_argument("--allow-build", action="store_true")
    parser.add_argument("--reason", default="")
    args = parser.parse_args()
    if args.action == "verify-environment":
        result = verify_environment_profile(ROOT, args.kind, args.prefix.absolute())
    elif args.action == "restore":
        result = restore(
            ROOT,
            args.kind,
            args.prefix.absolute(),
            args.repository,
            args.own_pr,
            args.cache_key,
            args.allow_build,
            args.reason,
            args.cache_hit,
        )
    else:
        if args.output is None:
            parser.error("--output is required for pack")
        result = pack(ROOT, args.kind, args.prefix.absolute(), args.output)
    for key, value in result.items():
        if destination := os.environ.get("GITHUB_OUTPUT"):
            with open(destination, "a") as stream:
                stream.write(f"{key}={value}\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
