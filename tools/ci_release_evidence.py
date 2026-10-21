#!/usr/bin/env python3
"""Record T5 locators and re-verify original release evidence before publication."""

import argparse
import importlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from tools import ci_artifacts as artifacts
from tools import ci_release_attestation as attestations
from tools.github_release import release_for_tag
from tools.release_acceptance_report import require_publication, SUITE_VERSION
from tools.release_asset_acceptance import named_asset, select_asset, source_revision

INDEX = "release-evidence-v2.json"
KINDS = {
    "deb": "linux-app",
    "rpm": "linux-app",
    "arch": "linux-app",
    "dmg": "macos-app",
}
api = artifacts.api


def candidates():
    return importlib.import_module("tools.ci_release_candidates")


def package_receipt(prefix, installer, kind, tag):
    """Bind the actual retrieved candidate and packaged installer, without builds."""
    if kind not in KINDS or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Invalid packaging receipt kind/tag")
    qualification = prefix / "source-qualification.json"
    if qualification.is_symlink():
        raise ValueError("Candidate qualification must be a regular file")
    original = json.loads(qualification.read_text())
    receipt = original["source_receipt"]
    checksum = artifacts.digest(installer)
    metadata = json.loads(Path(str(installer) + ".build.json").read_text())
    source = source_revision(metadata, kind, tag, checksum)
    if (
        receipt.get("component") != KINDS[kind]
        or receipt.get("source_commit") != source
        or receipt.get("identity") != source
        or receipt.get("label") not in (None, "")
        or receipt.get("tier") not in (None, "release")
        or receipt.get("distribution")
        != artifacts.application_distribution(prefix, KINDS[kind], source)
        or not re.fullmatch(r"[a-f0-9]{64}", receipt.get("sha256", ""))
    ):
        raise ValueError("Installer does not bind its actual stable candidate")
    return {
        "schema": 1,
        "source": source,
        "tag": tag,
        "format": kind,
        "asset": installer.name,
        "sha256": checksum,
        "candidate": {
            "run": original["producer_run"],
            "artifact_id": original["artifact_id"],
            "artifact_digest": original["artifact_digest"],
            "payload_sha256": receipt["sha256"],
        },
        "producer_run": int(os.environ["GITHUB_RUN_ID"]),
        "producer_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "producer_job": os.environ["GITHUB_JOB"],
    }


def release_run(repository, run_id):
    record = api(repository, f"actions/runs/{run_id}")
    if (
        type(run_id) is not int
        or run_id < 1
        or record.get("id") != run_id
        or record.get("path") != ".github/workflows/release.yml"
        or record.get("event") != "workflow_dispatch"
        or record.get("head_branch") != "main"
        or (record.get("repository") or {}).get("full_name") != repository
        or (record.get("head_repository") or {}).get("full_name") != repository
        or not re.fullmatch(r"[a-f0-9]{40}", record.get("head_sha", ""))
    ):
        raise ValueError("Evidence must name an original reviewed release coordinator")
    return record


def proof(repository, run, job_name, artifact_name, member, *, attempt_scoped=False):
    reader = candidates()
    jobs = reader.original_jobs(repository, run)
    job = reader.latest(jobs, job_name)
    items = reader.pages(repository, f"actions/runs/{run['id']}/artifacts", "artifacts")
    if attempt_scoped:
        artifact_name += "-" + str(job["run_attempt"])
    artifact = reader.original(items, artifact_name, run, job)
    record = reader.read_json(repository, artifact, member)
    return {
        "run": run["id"],
        "job": job["id"],
        "attempt": job["run_attempt"],
        "artifact": artifact["id"],
        "digest": artifact["digest"],
    }, record


def package_proof(repository, run, kind):
    job = "macos / dmg" if kind == "dmg" else f"linux / packages ({kind})"
    return proof(
        repository, run, job, "release-packaging-" + kind, "package-receipt.json"
    )


def acceptance_proof(repository, run_id, *, expected=None, seen=()):
    if type(run_id) is not int or run_id < 1 or run_id in seen or len(seen) >= 16:
        raise ValueError("Invalid or cyclic original acceptance reference")
    run = api(repository, f"actions/runs/{run_id}")
    if (
        run.get("id") != run_id
        or run.get("event") != "workflow_dispatch"
        or run.get("path")
        not in (
            ".github/workflows/release.yml",
            ".github/workflows/release-acceptance.yml",
        )
        or run.get("head_branch") != "main"
        or (run.get("repository") or {}).get("full_name") != repository
        or (run.get("head_repository") or {}).get("full_name") != repository
    ):
        raise ValueError("Unqualified installer acceptance run")
    job = (
        "acceptance / acceptance"
        if run["path"].endswith("/release.yml")
        else "acceptance"
    )
    locator, report = proof(
        repository,
        run,
        job,
        "release-acceptance-summary",
        "release-acceptance.json",
        attempt_scoped=True,
    )
    if expected is not None and locator != expected:
        raise ValueError(
            "Original acceptance reference differs from its latest successful job"
        )
    if report.get("suite_version") != SUITE_VERSION or report.get("status") not in (
        "passed",
        "automated_passed_manual_pending",
    ):
        raise ValueError("Original automated acceptance is incomplete or obsolete")
    previous = report.get("reused_validation_from")
    if previous is not None:
        if not isinstance(previous, dict) or set(previous) != set(locator):
            raise ValueError("Invalid immutable original acceptance reference")
        original, upstream = acceptance_proof(
            repository, previous["run"], expected=previous, seen=(*seen, run_id)
        )
        # A forwarder may add installer-bound manual GPU evidence, but cannot
        # replace the original automated acceptance/upgrade result or its bytes.
        for field in (
            "tag",
            "source_commit",
            "suite_version",
            "installers",
            "validation_artifacts",
        ):
            if report.get(field) != upstream.get(field):
                raise ValueError(
                    "Forwarded acceptance differs from its original automated proof"
                )
        return original, report
    return locator, report


def download_asset(repository, asset, directory):
    name = asset.get("name", "")
    if Path(name).name != name or not re.fullmatch(r"[A-Za-z0-9._+-]+", name):
        raise ValueError("Unsafe release evidence asset")
    path = directory / name
    with path.open("wb") as stream:
        subprocess.run(
            [
                "gh",
                "api",
                "-H",
                "Accept: application/octet-stream",
                f"repos/{repository}/releases/assets/{asset['id']}",
            ],
            stdout=stream,
            check=True,
            timeout=300,
        )
    checksum = artifacts.digest(path)
    if path.stat().st_size != asset.get("size") or (
        asset.get("digest") not in (None, "", "sha256:" + checksum)
    ):
        raise ValueError("Release asset bytes differ from API metadata")
    return path


def accepted(report, source, tag, installers):
    if (
        report.get("tag") != tag
        or report.get("source_commit") != source
        or report.get("suite_version") != SUITE_VERSION
        or report.get("status") not in ("passed", "automated_passed_manual_pending")
        or sorted(report.get("installers", []), key=lambda item: item["asset"])
        != sorted(installers, key=lambda item: item["asset"])
    ):
        raise ValueError("Missing current complete installer/upgrade acceptance")


def verify(
    repository,
    tag,
    index,
    *,
    current_run=0,
    publication_report=None,
    skip_gpu_validation=False,
):
    """The draft index supplies locators only; APIs and verified bytes decide."""
    if (
        type(index.get("schema")) is not int
        or index.get("schema") != 1
        or index.get("tag") != tag
        or index.get("suite_version") != SUITE_VERSION
        or set(index.get("installers", {})) != set(KINDS)
    ):
        raise ValueError("Missing or invalid release evidence index")
    source = api(repository, f"commits/{tag}")["sha"]
    release = release_for_tag(repository, tag, request=api)
    if (
        not release.get("draft")
        or release.get("target_commitish") != source
        or index.get("source") != source
    ):
        raise ValueError("Evidence source differs from the immutable draft/tag")
    evidence = candidates().verified_evidence(
        repository, source, index["candidate_runs"], current_run=current_run
    )
    if (
        index.get("source_floor") != evidence["source_floor"]
        or index.get("candidate_mode") != evidence["mode"]
    ):
        raise ValueError("Candidate evidence policy changed")
    installers = []
    with tempfile.TemporaryDirectory(
        prefix="release-publish-verification-"
    ) as temporary:
        directory = Path(temporary)
        for kind, component in KINDS.items():
            locator = index["installers"][kind]
            run = release_run(repository, locator["run"])
            observed, receipt = package_proof(repository, run, kind)
            if observed != locator:
                raise ValueError(
                    "Packaging locator is stale relative to its latest job"
                )
            asset = select_asset(release, kind)
            candidate = evidence["components"][component]
            expected = {
                "run": evidence["candidate_runs"][component],
                "artifact_id": candidate["artifact_id"],
                "artifact_digest": candidate["artifact_digest"],
                "payload_sha256": candidate["payload_sha256"],
            }
            path = download_asset(repository, asset, directory)
            checksum = artifacts.digest(path)
            if (
                type(receipt.get("schema")) is not int
                or receipt.get("schema") != 1
                or receipt.get("source") != source
                or receipt.get("tag") != tag
                or receipt.get("format") != kind
                or receipt.get("asset") != asset["name"]
                or receipt.get("sha256") != checksum
                or receipt.get("candidate") != expected
                or receipt.get("producer_run") != run["id"]
                or receipt.get("producer_attempt") != observed["attempt"]
                or receipt.get("producer_job")
                != ("dmg" if kind == "dmg" else "packages")
            ):
                raise ValueError(
                    "Packaging receipt does not bind the verified candidate/installer"
                )
            attestations.verify(
                path,
                repository,
                "macos" if kind == "dmg" else "linux",
                run,
                observed["attempt"],
            )
            installers.append(
                {
                    "asset": asset["name"],
                    "sha256": checksum,
                    "platform": "macos" if kind == "dmg" else "linux",
                }
            )
    observed, report = acceptance_proof(repository, index["acceptance"]["run"])
    if observed != index["acceptance"]:
        raise ValueError("Acceptance locator is stale relative to its latest job")
    accepted(report, source, tag, installers)
    if publication_report is not None:
        accepted(publication_report, source, tag, installers)
        require_publication(
            publication_report, tag, skip_gpu_validation=skip_gpu_validation
        )
    return {
        "source": source,
        "candidate_evidence": evidence,
        "installers": installers,
        "acceptance": observed,
    }


def record(
    repository,
    tag,
    platform_runs,
    packaging_run,
    acceptance_run,
    *,
    current_run=0,
    upload=False,
):
    source = api(repository, f"commits/{tag}")["sha"]
    release = release_for_tag(repository, tag, request=api)
    previous = [item for item in release["assets"] if item["name"] == INDEX]
    if previous:
        with tempfile.TemporaryDirectory(prefix="release-evidence-index-") as temporary:
            path = download_asset(
                repository, named_asset(release, INDEX), Path(temporary)
            )
            index = json.loads(path.read_text())
        try:
            verify(repository, tag, index, current_run=current_run)
        except ValueError:
            # The locator can become stale after a successful original-job rerun.
            # Reconstruct and fully verify current proofs below; a failed latest
            # job, changed installer or invalid candidate still cannot pass.
            pass
        else:
            if upload:
                _upload_verified_index(repository, tag, index)
            return index
    evidence = candidates().verified_evidence(
        repository, source, platform_runs, current_run=current_run
    )
    run = release_run(repository, packaging_run)
    try:
        installers = {kind: package_proof(repository, run, kind)[0] for kind in KINDS}
    except ValueError as error:
        raise ValueError(
            f"{error}. Preserve the existing installers; locate their original release.yml "
            "run and retry its failed jobs with gh run rerun ORIGINAL_RUN --failed. "
            "Standalone packaging or a fresh partial coordinator cannot replace original "
            "packaging proof; publication-only needs an existing qualified evidence index. "
            "A retry uses original tooling, not a later merged fix; if that code cannot "
            "produce valid proof, hold publication for reviewed recovery."
        ) from error
    index = {
        "schema": 1,
        "tag": tag,
        "source": source,
        "suite_version": SUITE_VERSION,
        "source_floor": evidence["source_floor"],
        "candidate_mode": evidence["mode"],
        "candidate_runs": evidence["candidate_runs"],
        "installers": installers,
        "acceptance": acceptance_proof(repository, acceptance_run)[0],
    }
    verify(repository, tag, index, current_run=current_run)
    if upload:
        _upload_verified_index(repository, tag, index)
    return index


def upload_index(repository, tag, index, *, current_run=0):
    """Refresh only the locator asset, after requalifying every original byte/job."""
    verify(repository, tag, index, current_run=current_run)
    return _upload_verified_index(repository, tag, index)


def _upload_verified_index(repository, tag, index):
    # record() also reaches this boundary only after full verification. Preserve
    # the verified local result instead of downloading every large installer twice.
    release = release_for_tag(repository, tag, request=api)
    previous = [asset for asset in release["assets"] if asset["name"] == INDEX]
    with tempfile.TemporaryDirectory(prefix="release-evidence-upload-") as temporary:
        directory = Path(temporary)
        if previous:
            old = download_asset(repository, named_asset(release, INDEX), directory)
            if json.loads(old.read_text()) == index:
                return False
        path = directory / INDEX
        path.write_text(json.dumps(index, sort_keys=True, indent=2) + "\n")
        # This exception is limited to one metadata filename. Installers and
        # their immutable attestations/checksums never enter this command.
        subprocess.run(
            [
                "gh",
                "release",
                "upload",
                tag,
                str(path),
                "--repo",
                repository,
                "--clobber",
            ],
            check=True,
            timeout=300,
        )
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("package", "record", "verify"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--installer", type=Path)
    parser.add_argument("--format", choices=tuple(KINDS))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--platform-runs", default="{}")
    parser.add_argument("--acceptance-run", type=int, default=0)
    parser.add_argument("--publication-report", type=Path)
    parser.add_argument("--skip-gpu-validation", action="store_true")
    parser.add_argument("--upload-index", action="store_true")
    args = parser.parse_args()
    if args.upload_index and args.command != "record":
        parser.error("Only record may upload the fixed evidence metadata index")
    repository = os.environ["GITHUB_REPOSITORY"]
    current_run = int(os.environ["GITHUB_RUN_ID"])
    if args.command == "package":
        if args.directory is None or args.installer is None or args.format is None:
            parser.error("package needs --directory, --installer and --format")
        result = package_receipt(args.directory, args.installer, args.format, args.tag)
    elif args.command == "record":
        result = record(
            repository,
            args.tag,
            {key: int(value) for key, value in json.loads(args.platform_runs).items()},
            current_run,
            args.acceptance_run or current_run,
            current_run=current_run,
            upload=args.upload_index,
        )
    else:
        if args.publication_report is None:
            parser.error(
                "verify needs --publication-report with complete installer acceptance"
            )
        release = release_for_tag(repository, args.tag, request=api)
        try:
            asset = named_asset(release, INDEX)
        except ValueError as error:
            raise ValueError(
                "Publication requires an existing qualified release evidence index. "
                "Preserve installers and retry failed jobs in their original release.yml "
                "run (gh run rerun ORIGINAL_RUN --failed) to finish acceptance/evidence; "
                "a new publication-only run cannot reconstruct missing packaging proof. "
                "Retries use original tooling; if that code cannot produce valid proof, "
                "hold publication for reviewed recovery."
            ) from error
        with tempfile.TemporaryDirectory(prefix="release-evidence-index-") as temporary:
            path = download_asset(repository, asset, Path(temporary))
            result = verify(
                repository,
                args.tag,
                json.loads(path.read_text()),
                current_run=current_run,
                publication_report=json.loads(args.publication_report.read_text()),
                skip_gpu_validation=args.skip_gpu_validation,
            )
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
