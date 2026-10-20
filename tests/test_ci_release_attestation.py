"""Cryptographic CLI policy and certificate invocation cannot substitute for each other."""

import json
import subprocess
import sys
from unittest.mock import Mock

import pytest

from tools import ci_release_attestation as attestation

REPO = "owner/repo"
HEAD = "b" * 40


@pytest.fixture
def signed(tmp_path, monkeypatch):
    path = tmp_path / "installer.deb"
    path.write_bytes(b"the same immutable installer bytes")
    run = {
        "id": 42,
        "path": ".github/workflows/release.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": HEAD,
        "repository": {"full_name": REPO},
    }
    certificate = {
        "issuer": attestation.ISSUER,
        "subjectAlternativeName": f"https://github.com/{REPO}/.github/workflows/linux-packages.yml@refs/heads/main",
        "sourceRepositoryURI": f"https://github.com/{REPO}",
        "sourceRepositoryRef": "refs/heads/main",
        "sourceRepositoryDigest": HEAD,
        "buildSignerDigest": HEAD,
        "buildConfigURI": f"https://github.com/{REPO}/.github/workflows/release.yml@refs/heads/main",
        "runInvocationURI": f"https://github.com/{REPO}/actions/runs/42/attempts/2",
    }
    statement = {
        "predicateType": attestation.PREDICATE,
        "subject": [{"digest": {"sha256": attestation.digest(path)}}],
        "predicate": {
            "runDetails": {
                "metadata": {"invocationId": certificate["runInvocationURI"]}
            }
        },
    }
    result = {
        "verificationResult": {
            "signature": {"certificate": certificate},
            "statement": statement,
        }
    }
    command = Mock(side_effect=lambda *args, **kw: json.dumps([result]))
    monkeypatch.setattr(attestation.subprocess, "check_output", command)
    return path, run, certificate, statement, command


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_expected_reusable_signer_and_caller_invocation_are_both_required(
    signed, platform
):
    path, run, certificate, statement, command = signed
    certificate["subjectAlternativeName"] = (
        f"https://github.com/{REPO}/{attestation.SIGNERS[platform]}@refs/heads/main"
    )
    result = attestation.verify(path, REPO, platform, run, 2)
    assert result["sha256"] == attestation.digest(path)
    args = command.call_args.args[0]
    for option, value in (
        ("--signer-workflow", REPO + "/" + attestation.SIGNERS[platform]),
        ("--source-digest", HEAD),
        ("--signer-digest", HEAD),
        ("--source-ref", "refs/heads/main"),
        ("--predicate-type", attestation.PREDICATE),
    ):
        assert args[args.index(option) + 1] == value
    # gh2.102 signer selectors are mutually exclusive; exact SAN remains a
    # required check of the verified certificate below, not a second selector.
    assert not {"--cert-identity", "--cert-identity-regex", "--signer-repo"} & set(args)
    assert "--deny-self-hosted-runners" in args
    assert command.call_args.kwargs["timeout"] == 300


@pytest.mark.parametrize(
    "field,value",
    [
        ("issuer", "https://other.example"),
        (
            "subjectAlternativeName",
            f"https://github.com/{REPO}/.github/workflows/release.yml@refs/heads/main",
        ),
        ("sourceRepositoryURI", "https://github.com/foreign/repo"),
        ("sourceRepositoryRef", "refs/tags/v1.2.3"),
        ("sourceRepositoryDigest", "c" * 40),
        ("buildSignerDigest", "c" * 40),
        (
            "buildConfigURI",
            f"https://github.com/{REPO}/.github/workflows/preview-packages.yml@refs/heads/main",
        ),
        ("runInvocationURI", f"https://github.com/{REPO}/actions/runs/43/attempts/2"),
        ("runInvocationURI", f"https://github.com/{REPO}/actions/runs/42/attempts/1"),
    ],
)
def test_valid_signature_with_wrong_certificate_identity_cannot_publish(
    signed, field, value
):
    path, run, certificate, statement, command = signed
    certificate[field] = value
    with pytest.raises(ValueError, match="certificate"):
        attestation.verify(path, REPO, "linux", run, 2)


def test_slsa_predicate_invocation_is_not_a_certificate_identity(signed):
    path, run, certificate, statement, command = signed
    certificate.pop("runInvocationURI")
    with pytest.raises(ValueError, match="certificate"):
        attestation.verify(path, REPO, "linux", run, 2)


@pytest.mark.parametrize(
    "invalid",
    ["predicate", "subject", "changed-bytes", "empty", "invalid-json", "signature"],
)
def test_unverified_or_mismatched_bytes_fail_closed(signed, invalid):
    path, run, certificate, statement, command = signed
    if invalid == "predicate":
        statement["predicateType"] = "other"
    elif invalid == "subject":
        statement["subject"] = []
    elif invalid == "changed-bytes":
        path.write_bytes(b"changed after release")
    elif invalid == "empty":
        command.side_effect = lambda *args, **kwargs: "{}"
    elif invalid == "invalid-json":
        command.side_effect = lambda *args, **kwargs: "{"
    else:
        command.side_effect = subprocess.CalledProcessError(
            1, ["gh"], stderr="signature rejected"
        )
    with pytest.raises((ValueError, subprocess.CalledProcessError)):
        attestation.verify(path, REPO, "linux", run, 2)


@pytest.mark.parametrize(
    "field,value",
    [
        ("id", 0),
        ("path", ".github/workflows/other.yml"),
        ("event", "pull_request"),
        ("head_branch", "topic"),
        ("repository", {"full_name": "other/repo"}),
        ("head_sha", "short"),
    ],
)
def test_unqualified_coordinator_is_rejected_before_attestation_lookup(
    signed, field, value
):
    path, run, certificate, statement, command = signed
    run[field] = value
    with pytest.raises(ValueError, match="invocation"):
        attestation.verify(path, REPO, "linux", run, 2)
    command.assert_not_called()


def test_actual_failing_attestation_cli_preserves_captured_output(
    tmp_path, monkeypatch, capsys
):
    binary = tmp_path / "bin"
    binary.mkdir()
    command = binary / "gh"
    command.write_text(
        "#!/fixture-python\nimport sys\n"
        "print('captured attestation output')\n"
        "print('certificate authority unavailable', file=sys.stderr)\n"
        "sys.exit(17)\n".replace("/fixture-python", sys.executable, 1)
    )
    command.chmod(0o755)
    monkeypatch.setenv("PATH", str(binary))
    path = tmp_path / "installer.deb"
    path.write_bytes(b"immutable installer")
    run = {
        "id": 42,
        "path": ".github/workflows/release.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": HEAD,
        "repository": {"full_name": REPO},
    }
    with pytest.raises(subprocess.CalledProcessError) as error:
        attestation.verify(path, REPO, "linux", run, 2)
    assert error.value.returncode == 17
    captured = capsys.readouterr()
    assert "captured attestation output" in captured.err
    assert "certificate authority unavailable" in captured.err


def test_attestation_timeout_preserves_partial_output(signed, capsys):
    path, run, certificate, statement, command = signed
    command.side_effect = subprocess.TimeoutExpired(
        ["gh"],
        300,
        output=b"partial verifier output\n",
        stderr=b"transparency log timed out\n",
    )
    with pytest.raises(subprocess.TimeoutExpired):
        attestation.verify(path, REPO, "linux", run, 2)
    captured = capsys.readouterr()
    assert "partial verifier output" in captured.err
    assert "transparency log timed out" in captured.err
