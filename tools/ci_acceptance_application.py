#!/usr/bin/env python3
"""Recover a same-PR application after later acceptance infrastructure fails.

The successful build/export/archive/upload steps qualify the original product,
not the later acceptance result. Recovery retains its source and attempt. Only
this consumer, its tests, and acceptance-workflow plumbing may differ; original
application and SDK inputs must otherwise be byte-identical.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.ci_stage_cache import ensure_commit, git  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ".github/workflows/integration-acceptance.yml"
PLUMBING = {
    WORKFLOW,
    "tools/ci_acceptance_application.py",
    "tests/test_ci_acceptance_application.py",
    "tests/test_linux_stage_workflows.py",
    "tests/test_pull_request_workflows.py",
}
BUILD_STEPS = (
    "Fetch verified Linux SDK descriptor",
    "Restore qualified application dependency outputs without compilation",
    "Build the shared Ubuntu 24.04 application and acceptance image",
)
PRODUCER_STEPS = BUILD_STEPS + (
    "Package version",
    "Export the exact Ubuntu acceptance application for packaging",
    "Archive the original application before acceptance setup",
    "Retain the original application independently of acceptance results",
)
RECOVERY_NAME = "Recover the original PR application before compiling"
RECOVERY_STEP = """      - name: Recover the original PR application before compiling
        if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
        id: retained
        env:
          GH_TOKEN: ${{ github.token }}
          OWN_HEAD: ${{ github.event.pull_request.head.sha }}
          OWN_PR: ${{ github.event.pull_request.number }}
          OWN_BRANCH: ${{ github.head_ref }}
          WORKFLOW_SOURCE: ${{ github.workflow_sha }}
        run: python tools/ci_acceptance_application.py --head "$OWN_HEAD" --pr "$OWN_PR" --branch "$OWN_BRANCH" --workflow-source "$WORKFLOW_SOURCE"
"""


def build_controls(text):
    """Freeze the complete build/export/archive/upload path and environment."""
    jobs = re.search(r"^jobs:\n", text, re.M)
    if not jobs:
        raise ValueError("Missing workflow job section")
    if re.search(r"^[\w-]+:", text[jobs.end() :], re.M):
        raise ValueError("Unchecked workflow keys after jobs; preserve the application")
    match = re.search(
        r"^  ubuntu-package:\n(.*?)(?=^  [\w-]+:\n|\Z)", text, re.M | re.S
    )
    if not match:
        raise ValueError("Missing original application producer job")
    job = match[1]
    if len(re.findall(r"^  ubuntu-package:\n", text, re.M)) != 1:
        raise ValueError("Ambiguous application producer job")
    steps = re.search(r"^    steps:\n", job, re.M)
    if not steps or re.search(r"^    [\w-]+:", job[steps.end() :], re.M):
        raise ValueError(
            "Unchecked producer job keys after steps; preserve the application"
        )
    build = re.search(
        r"^      - name: " + re.escape(PRODUCER_STEPS[-1]) + r"\n.*?(?=^      - |\Z)",
        job,
        re.M | re.S,
    )
    if not build:
        raise ValueError("Missing original application build control")
    prefix = job[: build.end()]
    recoveries = re.findall(
        r"^      - name: " + re.escape(RECOVERY_NAME) + r"\n.*?(?=^      - |\Z)",
        prefix,
        re.M | re.S,
    )
    if recoveries and recoveries != [RECOVERY_STEP]:
        raise ValueError("Recovery step differs from its verified read-only contract")
    prefix = prefix.replace(RECOVERY_STEP, "")
    lines = []
    step = ""
    original_if = "        if: github.event_name == 'pull_request'"
    for line in prefix.splitlines(keepends=True):
        if line.startswith("      - name: "):
            step = line.removeprefix("      - name: ").strip()
        if (
            step in BUILD_STEPS[1:] + PRODUCER_STEPS[4:]
            and line == original_if + " && steps.retained.outputs.hit != 'true'\n"
        ):
            line = original_if + "\n"
        if step == "Package version":
            if (
                line
                == "          RETAINED_EPOCH: ${{ steps.retained.outputs.epoch }}\n"
            ):
                continue
            line = line.replace(
                "epoch = os.environ['RETAINED_EPOCH'] or subprocess.check_output(",
                "epoch = subprocess.check_output(",
            )
        lines.append(line)
    controls = text[: jobs.start()] + "".join(lines)
    if re.search(r"(?:^|[\s:\[,])(?:&(?=[^&\s])|\*(?=\S))", controls, re.M):
        raise ValueError("Unverified YAML anchors or aliases in producer controls")
    return controls


def compatible(root, source, head, workflow_source=None, producer_workflow_source=None):
    ensure_commit(root, source)
    ensure_commit(root, head)
    workflow_source = workflow_source or head
    ensure_commit(root, workflow_source)
    changed = set(git(root, "diff", "--name-only", source, head).decode().splitlines())
    if changed - PLUMBING:
        return False
    producer_workflow_source = producer_workflow_source or source
    ensure_commit(root, producer_workflow_source)
    workflow = git(root, "show", producer_workflow_source + ":" + WORKFLOW).decode()
    if RECOVERY_NAME in workflow and git(
        root, "show", source + ":tools/ci_acceptance_application.py"
    ) != git(root, "show", head + ":tools/ci_acceptance_application.py"):
        return False
    original = build_controls(workflow)
    return all(
        original == build_controls(git(root, "show", ref + ":" + WORKFLOW).decode())
        for ref in (head, workflow_source)
    )


def pages(repository, route, key):
    """Finish the history search instead of treating a full page as a cache miss."""
    seen = set()
    page = 1
    while True:
        batch = artifacts.api(repository, route + f"&page={page}")[key]
        fresh = [item for item in batch if item["id"] not in seen]
        if batch and not fresh:
            raise ValueError(
                "Repeated history page; preserve retained application outputs"
            )
        for item in fresh:
            seen.add(item["id"])
            yield item
        if len(batch) < 100:
            return
        page += 1


def producer_workflow_head(repository, run):
    """Read the immutable head-file record; main history proves merge bindings."""
    query = "query($id:ID!){node(id:$id){... on WorkflowRun{databaseId file{path repositoryName repositoryFileUrl}}}}"
    result = json.loads(
        subprocess.check_output(
            [
                "gh",
                "api",
                "graphql",
                "-f",
                "query=" + query,
                "-f",
                "id=" + run["node_id"],
            ],
            timeout=300,
        )
    )
    node = (result.get("data") or {}).get("node") or {}
    file = node.get("file") or {}
    url = file.get("repositoryFileUrl")
    match = (
        re.fullmatch(
            r"https://github\.com/"
            + re.escape(repository)
            + r"/blob/([a-f0-9]{40})/"
            + re.escape(WORKFLOW),
            url,
        )
        if isinstance(url, str)
        else None
    )
    if (
        result.get("errors")
        or node.get("databaseId") != run["id"]
        or file.get("repositoryName") != repository
        or file.get("path") != WORKFLOW
        or not match
        or match[1] != run["head_sha"]
    ):
        raise ValueError(
            "Original workflow head-file cannot be verified; preserve the retained application"
        )
    return match[1]


def main_history(repository, root, source, head):
    """Prove merge-ref controls using this repository's protected linear main.

    Every main revision since the source's fork point must keep the same build
    controls. Checking intermediate revisions detects a change followed by a
    revert; a head-file link alone does not establish the executed merge recipe.
    """
    base = artifacts.api(repository, "commits/main")["sha"]
    if not isinstance(base, str) or not re.fullmatch(r"[a-f0-9]{40}", base):
        raise ValueError("Invalid reviewed-main identity; preserve the application")
    for commit in (source, head, base):
        ensure_commit(root, commit)
    if git(root, "rev-parse", "--is-shallow-repository").strip() == b"true":
        # Only missing source history is fetched, never SDKs or dependencies.
        subprocess.run(
            ["git", "fetch", "--no-tags", "--unshallow", "origin", source, head, base],
            cwd=root,
            check=True,
            timeout=300,
        )
    common = git(root, "merge-base", source, base).decode().strip()
    baseline = build_controls(git(root, "show", common + ":" + WORKFLOW).decode())
    commits = (
        git(root, "rev-list", "--first-parent", common + ".." + base)
        .decode()
        .splitlines()
    )
    for commit in commits:
        if (
            build_controls(git(root, "show", commit + ":" + WORKFLOW).decode())
            != baseline
        ):
            raise ValueError(
                "Main changed original merge-ref build controls; preserve the application and require a producer with verified workflow provenance"
            )
    return {"main_history_tip": base, "main_history_merge_base": common}


def qualified_job(repository, run, artifact, attempt):
    jobs = pages(
        repository,
        f"actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100",
        "jobs",
    )
    for job in jobs:
        if (
            job.get("name") != "ubuntu-package"
            or job.get("run_id") != run["id"]
            or job.get("run_attempt") != attempt
            or job.get("head_sha") != run["head_sha"]
            or job.get("status") != "completed"
            or not artifacts.in_producer_attempt(artifact, job)
        ):
            continue
        steps = {step["name"]: step for step in job.get("steps", [])}
        if not all(
            steps.get(name, {}).get("conclusion") == "success"
            for name in PRODUCER_STEPS
        ):
            continue
        upload = steps[PRODUCER_STEPS[-1]]
        if artifacts.in_producer_attempt(artifact, upload):
            return job
    return None


def restore(repository, artifact, source, destination, bundle):
    """Verify ZIP, original archive/receipt, safe extraction and every bundle file."""
    archive = destination.parent / "retained-application" / f"{artifact['id']}.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        if artifact.get("digest") != "sha256:" + artifacts.digest(archive):
            raise ValueError("Retained application cached ZIP digest mismatch")
    else:
        artifacts.download_zip(repository, artifact, archive)
    with tempfile.TemporaryDirectory(prefix="of-acceptance-reuse-") as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(archive) as zipped:
            names = zipped.namelist()
            payloads = [name for name in names if name.endswith(".tar.gz")]
            if len(payloads) != 1:
                raise ValueError("Ambiguous retained application archive")
            name = payloads[0]
            if (
                Path(name).name != name
                or set(names)
                != {name, name + ".sha256", name + ".build.json", "abi.json"}
                or len(names) != 4
            ):
                raise ValueError(
                    f"Unexpected retained application ZIP contents: {names!r}"
                )
            if (
                zipped.getinfo(name + ".build.json").file_size > 65536
                or zipped.getinfo(name + ".sha256").file_size > 1024
                or zipped.getinfo("abi.json").file_size > 16 * 1024 * 1024
            ):
                raise ValueError("Oversized retained application metadata")
            for entry in names:
                with (
                    zipped.open(entry) as incoming,
                    (root / entry).open("wb") as outgoing,
                ):
                    shutil.copyfileobj(incoming, outgoing)
        receipt = json.loads((root / (name + ".build.json")).read_text())
        abi = json.loads((root / "abi.json").read_text())
        if (
            abi.get("passed") is not True
            or abi.get("failures") != []
            or abi.get("max_glibc") != "2.39"
            or abi.get("max_glibcxx") != "3.4.33"
        ):
            raise ValueError(
                "Retained application ABI audit did not pass the required baseline"
            )
        digest = artifacts.digest(root / name)
        if (
            receipt.get("revision") != source
            or receipt.get("format") != "tar"
            or receipt.get("sha256") != digest
            or (root / (name + ".sha256")).read_text().strip() != f"{digest}  {name}"
        ):
            raise ValueError("Retained application receipt/checksum/source mismatch")
        unpacked = root / "unpacked"
        unpacked.mkdir()
        with tarfile.open(root / name) as tar:
            if any(
                not (
                    member.name == "open-foresight"
                    or member.name.startswith("open-foresight/")
                )
                for member in tar
            ):
                raise ValueError("Unexpected retained application archive root")
            tar.extractall(unpacked, filter="data")
        spec = importlib.util.spec_from_file_location(
            "acceptance_package_linux", ROOT / "packaging/package_linux.py"
        )
        if spec is None or spec.loader is None:
            raise ValueError("Current application package validator is unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = module.validate(unpacked / "open-foresight")
        if (
            manifest.get("revision") != source
            or manifest.get("version") != receipt.get("version")
            or manifest.get("build_number") != receipt.get("build_number")
        ):
            raise ValueError(
                "Retained application manifest differs from original receipt"
            )
        if bundle.exists():
            raise ValueError("Refusing to overwrite an existing application bundle")
        if (
            type(receipt.get("source_date_epoch")) is not int
            or receipt["source_date_epoch"] <= 0
        ):
            raise ValueError("Retained application has no original source timestamp")
        for entry in names:
            target = destination / entry
            if target.exists() and artifacts.digest(target) != artifacts.digest(
                root / entry
            ):
                raise ValueError(
                    "Conflicting retained application bytes; preserve both outputs"
                )
        destination.mkdir(parents=True, exist_ok=True)
        bundle.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(unpacked / "open-foresight", bundle)
        for entry in names:
            shutil.copyfile(root / entry, destination / entry)
        return {
            "version": receipt["version"],
            "epoch": str(receipt["source_date_epoch"]),
        }


def retrieve(
    repository, head, pr, branch, destination, bundle, workflow_source, root=ROOT
):
    if not re.fullmatch(r"[a-f0-9]{40}", head) or type(pr) is not int or pr <= 0:
        raise ValueError("Recovery requires an exact same-repository PR head")
    pull = artifacts.api(repository, f"pulls/{pr}")
    if (
        pull.get("head", {}).get("sha") != head
        or pull.get("head", {}).get("ref") != branch
        or pull.get("base", {}).get("ref") != "main"
        or any(
            pull.get(side, {}).get("repo", {}).get("full_name") != repository
            for side in ("head", "base")
        )
    ):
        raise ValueError("Recovery PR repository/head does not match")
    if not re.fullmatch(r"[a-f0-9]{40}", workflow_source):
        raise ValueError("Recovery requires the actual executed workflow commit")
    query = urlencode(
        {
            "event": "pull_request",
            "branch": branch,
            "created": ">=" + pull["created_at"],
            "per_page": 100,
        }
    )
    runs = pages(
        repository,
        "actions/workflows/integration-acceptance.yml/runs?" + query,
        "workflow_runs",
    )
    for run in runs:
        source = run.get("head_sha", "")
        if (
            run.get("path") != WORKFLOW
            or run.get("event") != "pull_request"
            or (run.get("head_repository") or {}).get("full_name") != repository
            or (run.get("repository") or {}).get("full_name") != repository
            or not any(
                item.get("number") == pr for item in run.get("pull_requests", [])
            )
            or not re.fullmatch(r"[a-f0-9]{40}", source)
        ):
            continue
        items = pages(
            repository, f"actions/runs/{run['id']}/artifacts?per_page=100", "artifacts"
        )
        retained = [
            item
            for item in items
            if re.fullmatch(
                "ubuntu-acceptance-application-" + source + r"-[1-9][0-9]*",
                item.get("name", ""),
            )
            and not item.get("expired")
        ]
        if not retained:
            continue
        comparison = artifacts.optional_api(repository, f"compare/{source}...{head}")
        if comparison is None:
            print(
                f"Historical source {source} is unavailable; preserve its original artifact and inspect other eligible producers",
                file=sys.stderr,
            )
            continue
        if comparison["status"] not in ("ahead", "identical"):
            continue
        original_workflow = producer_workflow_head(repository, run)
        if not compatible(root, source, head, workflow_source, original_workflow):
            continue
        for artifact in retained:
            attempt = int(artifact["name"].rsplit("-", 1)[1])
            if (
                attempt > run.get("run_attempt", 0)
                or artifact.get("workflow_run", {}).get("id") != run["id"]
                or not qualified_job(repository, run, artifact, attempt)
            ):
                raise ValueError(
                    "Retained PR application has no successful original build/export/upload steps"
                )
            proof = main_history(repository, root, source, head)
            values = restore(repository, artifact, source, destination, bundle)
            return {
                "hit": "true",
                "source": source,
                "producer_run": str(run["id"]),
                "producer_attempt": str(attempt),
                "artifact_id": str(artifact["id"]),
                "artifact_digest": artifact["digest"],
                "producer_workflow_head": original_workflow,
                "producer_workflow_control_proof": "head-plus-protected-main-history",
                "consumer_workflow_source": workflow_source,
                **proof,
                **values,
            }
    return {"hit": "false"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", required=True)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--workflow-source", required=True)
    args = parser.parse_args()
    try:
        values = retrieve(
            os.environ["GITHUB_REPOSITORY"],
            args.head,
            args.pr,
            args.branch,
            Path("dist/packages"),
            Path("build/portable/dist/open-foresight"),
            args.workflow_source,
        )
    except subprocess.CalledProcessError as error:
        for output in (error.output, error.stderr):
            if output:
                print(
                    output.decode(errors="replace")
                    if isinstance(output, bytes)
                    else output,
                    file=sys.stderr,
                )
        raise
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")
    Path("test-results").mkdir(exist_ok=True)
    Path("test-results/application-reuse.json").write_text(
        json.dumps(values, indent=2) + "\n"
    )
    print(json.dumps(values))


if __name__ == "__main__":
    main()
