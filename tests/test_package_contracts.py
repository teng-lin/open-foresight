"""Package contracts consume the current run's verified original bundle."""

import json
from pathlib import Path
import tarfile

import pytest
import yaml

from tests.test_integration_application import producer as producer, restore, SOURCE

ROOT = Path(__file__).resolve().parents[1]


def workflow():
    return yaml.safe_load(
        (ROOT / ".github/workflows/package-contracts.yml")
        .read_text()
        .replace("\non:", "\n'on':", 1)
    )


def metadata_step():
    step = next(
        item
        for item in workflow()["jobs"]["linux"]["steps"]
        if item.get("id") == "bundle"
    )
    return step["run"].split("python - <<'PYCODE'\n", 1)[1].rsplit("\nPYCODE", 1)[0]


@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", None])
def test_own_pr_bundle_preserves_original_checksums_provenance_and_package_version(
    tmp_path, producer, monkeypatch, ref
):
    if ref is None:
        monkeypatch.delenv("GITHUB_REF", raising=False)
        monkeypatch.delenv("GITHUB_REF_NAME", raising=False)
    else:
        monkeypatch.setenv("GITHUB_REF", ref)
        monkeypatch.setenv("GITHUB_REF_NAME", ref.removeprefix("refs/"))
    monkeypatch.setenv("GITHUB_HEAD_REF", "unrelated-inherited-pr")
    original, restored, qualification = restore(
        tmp_path, producer, purpose="package-contract"
    )
    assert qualification["producer_run"] == 100
    assert qualification["producer_attempt"] == 1
    assert qualification["source_receipt"]["source_run_attempt"] == 1
    assert qualification["source_receipt"]["tier"] == "pr"
    assert qualification["artifact_digest"] == "sha256:" + producer[2]
    assert (restored / "application.tar.gz").read_bytes() == (
        original / "application.tar.gz"
    ).read_bytes()
    if (original / "source-qualification.json").exists():
        assert qualification["source_receipt"]["reused_from"] == json.loads(
            (original / "source-qualification.json").read_text()
        )
    # Reuse the exact verified portable archive; packaging does not compile it.
    with tarfile.open(restored / "application.tar.gz") as archive:
        member = archive.getmember("open-foresight/executable")
        assert member.mode == 0o755
        assert archive.extractfile(member).read() == b"immutable original application"
    restored.rename(tmp_path / "artifacts")
    monkeypatch.chdir(tmp_path)
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setenv("SOURCE", SOURCE)
    monkeypatch.setenv("BUNDLE_TIER", "pr")
    exec(compile(metadata_step(), "package-contracts.yml", "exec"), {})  # noqa: S102 - Exercise the checked-in workflow's actual Python step.
    assert output.read_text() == "version=0.1.2\n"
    assert not (tmp_path / ".git").exists()


@pytest.mark.parametrize(
    "invalid",
    [
        "old-main-name",
        "old-main-job",
        "different-source",
        "foreign-run",
        "upload-window",
        "corrupt-zip",
    ],
)
def test_package_contract_cannot_fall_back_to_old_or_unqualified_bytes(
    tmp_path, producer, invalid
):
    if invalid == "old-main-name":
        producer[4]["name"] = "ci-linux-app-" + SOURCE
    elif invalid == "old-main-job":
        producer[5]["name"] = "linux-bundle"
    elif invalid == "different-source":
        producer[3]["head_sha"] = "b" * 40
    elif invalid == "foreign-run":
        producer[4]["workflow_run"]["id"] = 999
    elif invalid == "upload-window":
        producer[5]["completed_at"] = "2024-12-31T23:59:59Z"
    else:
        producer[1].write_bytes(producer[1].read_bytes() + b"corrupt")
    with pytest.raises(ValueError):
        restore(tmp_path, producer, purpose="package-contract")
    assert not (tmp_path / "restored").exists()


def test_declared_tier_must_match_qualified_receipt_before_packaging(
    tmp_path, producer, monkeypatch
):
    _, restored, _ = restore(tmp_path, producer, purpose="package-contract")
    restored.rename(tmp_path / "artifacts")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("SOURCE", SOURCE)
    monkeypatch.setenv("BUNDLE_TIER", "release")
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    with pytest.raises(ValueError, match="tier differs"):
        exec(compile(metadata_step(), "package-contracts.yml", "exec"), {})  # noqa: S102 - Actual workflow metadata boundary.
    assert not output.exists()


def test_preview_contract_keeps_qualified_label_in_native_package_version(
    tmp_path, producer, monkeypatch
):
    _, restored, qualification = restore(tmp_path, producer, purpose="package-contract")
    restored.rename(tmp_path / "artifacts")
    # The private qualification comes from the shared reader; that reader owns
    # the preview-source, original receipt and distribution-stamp checks.
    qualification["source_receipt"].update(tier="preview", label="nightly.20261019.3")
    (tmp_path / "artifacts/source-qualification.json").write_text(
        json.dumps(qualification)
    )
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("SOURCE", SOURCE)
    monkeypatch.setenv("BUNDLE_TIER", "preview")
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    exec(compile(metadata_step(), "package-contracts.yml", "exec"), {})  # noqa: S102 - Actual workflow metadata boundary.
    assert output.read_text() == "version=0.1.2~nightly.20261019.3\n"


def test_reusable_contract_preserves_native_lifecycles_debian_cross_install_and_dmg():
    config = workflow()
    inputs = config["on"]["workflow_call"]["inputs"]
    assert inputs["source"]["required"] is True
    assert inputs["head_repository"]["required"] is True
    assert inputs["linux_enabled"] == {"type": "boolean", "default": True}
    linux, dmg = config["jobs"]["linux"], config["jobs"]["dmg"]
    assert linux["if"] == "inputs.linux_enabled"
    assert "if" not in dmg
    assert {row["format"] for row in linux["strategy"]["matrix"]["include"]} == {
        "deb",
        "rpm",
        "arch",
    }
    steps = linux["steps"]
    bundle = next(item for item in steps if item.get("id") == "bundle")
    assert bundle["env"]["ARTIFACT_ID"] == "${{ inputs.bundle_id }}"
    assert bundle["env"]["PRODUCER_ATTEMPT"] == "${{ inputs.producer_attempt }}"
    assert "--purpose package-contract" in bundle["run"]
    assert "--main-candidate" not in bundle["run"]
    commands = "\n".join(item.get("run", "") for item in steps)
    assert commands.index("tools.integration_application") < commands.index(
        "package-and-test.sh"
    )
    for phase in ("prepare", "build", "test"):
        assert f'"$FORMAT" "$VERSION" 1 {phase}' in commands
    assert "test_rpm_scriptlets.py" in commands
    assert "test_nlohmann_notice_is_listed_in_arch_package" in commands
    debian = next(item for item in steps if item.get("if") == "matrix.format == 'deb'")
    assert "sha256sum --check ./*.deb.sha256" in debian["run"]
    assert '"$PWD/dist/packages:/packages:ro"' in debian["run"]
    assert "debian:13@sha256:" in debian["run"]
    assert "packaging/ci/test-debian.sh" in debian["run"]
    assert "test_dmg_contract.py" in str(dmg)
    for job in (linux, dmg):
        checkout = next(
            item for item in job["steps"] if "checkout@" in item.get("uses", "")
        )
        assert checkout["with"]["ref"] == "${{ inputs.source }}"
    assert config["permissions"] == {"contents": "read", "actions": "read"}
    assert "release_upload" not in commands
    assert "build_linux_sdk" not in commands
    assert "build.sh" not in commands
    assert not (ROOT / "tools/package_contract_candidate.py").exists()
    for step in steps:
        if "upload-artifact@" in step.get("uses", ""):
            assert step["with"]["overwrite"] is True
            assert not step["with"]["name"].startswith("ci-")
