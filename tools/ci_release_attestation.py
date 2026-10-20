"""Verify installer signatures and certificate-bound release invocation identity."""

import json
from pathlib import Path
import re
import subprocess
import sys

from tools.ci_artifacts import digest

ISSUER = "https://token.actions.githubusercontent.com"
PREDICATE = "https://slsa.dev/provenance/v1"
SIGNERS = {
    "linux": ".github/workflows/linux-packages.yml",
    "macos": ".github/workflows/macos-release.yml",
}


def verify(path, repository, platform, run, attempt):
    """Use gh's cryptographic verification, then inspect certificate claims only.

    JSON fields follow gh 2.102.0 and sigstore-go 1.3.0 certificate.Summary.
    The SLSA predicate's invocation is user-controlled and is not an identity.
    """
    if (
        platform not in SIGNERS
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        or type(run.get("id")) is not int
        or run["id"] < 1
        or type(attempt) is not int
        or attempt < 1
        or run.get("path") != ".github/workflows/release.yml"
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != "main"
        or (run.get("repository") or {}).get("full_name") != repository
        or not re.fullmatch(r"[a-f0-9]{40}", run.get("head_sha", ""))
    ):
        raise ValueError("Invalid installer attestation release invocation")
    workflow = SIGNERS[platform]
    identity = f"https://github.com/{repository}/{workflow}@refs/heads/main"
    try:
        output = subprocess.check_output(
            [
                "gh",
                "attestation",
                "verify",
                str(path),
                "--repo",
                repository,
                "--signer-workflow",
                repository + "/" + workflow,
                "--cert-oidc-issuer",
                ISSUER,
                "--source-ref",
                "refs/heads/main",
                "--source-digest",
                run["head_sha"],
                "--signer-digest",
                run["head_sha"],
                "--deny-self-hosted-runners",
                "--predicate-type",
                PREDICATE,
                "--format",
                "json",
            ],
            text=True,
            stderr=subprocess.PIPE,
            timeout=300,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        # Captured diagnostics must survive in the failed CI step, including
        # timeout output; keep the original exception and fail closed.
        for value in (error.stdout, error.stderr):
            if value:
                message = (
                    value.decode(errors="replace")
                    if isinstance(value, bytes)
                    else value
                )
                print(
                    message, file=sys.stderr, end="" if message.endswith("\n") else "\n"
                )
        raise
    results = json.loads(output)
    if not isinstance(results, list):
        raise ValueError("Invalid gh attestation verification output")
    invocation = (
        f"https://github.com/{repository}/actions/runs/{run['id']}/attempts/{attempt}"
    )
    coordinator = (
        f"https://github.com/{repository}/.github/workflows/release.yml@refs/heads/main"
    )
    checksum = digest(Path(path))
    for result in results:
        verification = (
            result.get("verificationResult", {}) if isinstance(result, dict) else {}
        )
        certificate = (verification.get("signature") or {}).get("certificate") or {}
        statement = verification.get("statement") or {}
        if (
            certificate.get("issuer") == ISSUER
            and certificate.get("subjectAlternativeName") == identity
            and certificate.get("sourceRepositoryURI")
            == f"https://github.com/{repository}"
            and certificate.get("sourceRepositoryRef") == "refs/heads/main"
            and certificate.get("sourceRepositoryDigest") == run["head_sha"]
            and certificate.get("buildSignerDigest") == run["head_sha"]
            and certificate.get("buildConfigURI") == coordinator
            and certificate.get("runInvocationURI") == invocation
            and statement.get("predicateType") == PREDICATE
            and any(
                subject.get("digest", {}).get("sha256") == checksum
                for subject in statement.get("subject", [])
            )
        ):
            return {"sha256": checksum, "signer": identity, "invocation": invocation}
    raise ValueError(
        "No verified installer certificate names the original release run/attempt"
    )
