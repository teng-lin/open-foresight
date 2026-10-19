"""Bad source qualification cannot hide a later verified SDK candidate."""

import io
import json
import subprocess
import zipfile

import pytest

from tools import ci_artifacts as artifacts
from tools import ci_macos_dependencies as macos

COMPONENT = "linux-sdk"
IDENTITY = "a" * 64


@pytest.fixture
def candidates(tmp_path, monkeypatch):
    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "retained").write_text("verified SDK fixture")
    packed = tmp_path / "packed"

    def revision(command, **kwargs):
        assert command == ["git", "rev-parse", "HEAD"]
        assert kwargs == {"cwd": artifacts.ROOT, "text": True, "timeout": 30}
        return "9" * 40 + "\n"

    with monkeypatch.context() as packing:
        packing.setattr(artifacts.subprocess, "check_output", revision)
        artifacts.pack(COMPONENT, IDENTITY, payload, packed)
    receipt = json.loads((packed / "identity.json").read_text())
    archives = {}
    payloads, sidecars = [], []

    def archive(members):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as stream:
            for name, data in members.items():
                stream.writestr(name, data)
        return buffer.getvalue()

    for number in (1, 2):
        common = {
            "expired": False,
            "workflow_run": {"id": number},
            "created_at": "2026-01-01T00:05:00Z",
            "expires_at": "2099-01-01T00:00:00Z",
        }
        item = {
            **common,
            "id": number,
            "name": artifacts.name(COMPONENT, IDENTITY),
            "digest": "sha256:" + "b" * 64,
        }
        payloads.append(item)
        sidecars.append(
            {
                **common,
                "id": number + 10,
                "name": artifacts.receipt_name(COMPONENT, IDENTITY),
                "size_in_bytes": 1000,
            }
        )
        archives[number] = archive(
            {
                name: (packed / name).read_bytes()
                for name in ("identity.json", "payload.tar.gz")
            }
        )
        archives[number + 10] = archive(
            {
                "receipt.json": json.dumps(
                    {
                        "schema": 1,
                        "component": COMPONENT,
                        "identity": IDENTITY,
                        "artifact_id": number,
                        "artifact_digest": item["digest"],
                        "source_receipt": receipt,
                    }
                )
            }
        )

    state = {"all_bad": False, "error": None, "seen": [], "lists": 0}

    def api(repository, route):
        if route.startswith("actions/artifacts?"):
            state["lists"] += 1
            return {"artifacts": sidecars if "name=receipt-" in route else payloads}
        if route.startswith("actions/artifacts/"):
            return payloads[int(route.rsplit("/", 1)[1]) - 1]
        number = int(route.rsplit("/", 1)[1])
        return {"id": number, "head_sha": receipt["source_commit"]}

    def verify(repository, run, *args, **kwargs):
        state["seen"].append(run["id"])
        if state["error"]:
            raise state["error"]
        if run["id"] == 1 or state["all_bad"]:
            raise ValueError("Producer controls require requalification")
        return True

    monkeypatch.setattr(artifacts, "api", api)
    monkeypatch.setattr(artifacts, "approved_original", lambda *args: None)
    monkeypatch.setattr(artifacts, "eligible_run", lambda *args: True)
    monkeypatch.setattr(
        artifacts,
        "dependency_jobs",
        lambda *args: [
            {
                "name": artifacts.JOBS[COMPONENT],
                "conclusion": "success",
                "run_attempt": 1,
                "started_at": "2026-01-01T00:00:00Z",
                "completed_at": "2026-01-01T00:10:00Z",
            }
        ],
    )
    monkeypatch.setattr(
        artifacts,
        "download_zip",
        lambda repo, item, path: path.write_bytes(archives[item["id"]]),
    )
    monkeypatch.setattr(artifacts.producer_trust, "verify_producer_source", verify)
    state["destination"] = tmp_path / "restored"
    return state


def lookup(mode, state, **kwargs):
    if mode == "probe":
        return artifacts.probe("owner/repo", COMPONENT, IDENTITY)
    return artifacts.pull(
        "owner/repo", COMPONENT, IDENTITY, state["destination"], **kwargs
    )


@pytest.mark.parametrize("mode", ["probe", "pull"])
def test_unqualified_first_candidate_does_not_hide_later_valid_candidate(
    candidates, mode
):
    assert lookup(mode, candidates)
    assert candidates["seen"] == [1, 2]


@pytest.mark.parametrize("mode", ["probe", "pull"])
def test_only_unqualified_candidates_raise_instead_of_becoming_cache_miss(
    candidates, mode
):
    candidates["all_bad"] = True
    with pytest.raises(ValueError, match="require requalification"):
        lookup(mode, candidates)
    assert candidates["seen"] == [1, 2]


@pytest.mark.parametrize("mode", ["probe", "pull"])
@pytest.mark.parametrize(
    "error",
    [
        subprocess.CalledProcessError(1, "gh"),
        json.JSONDecodeError("Invalid API response", "", 0),
    ],
)
def test_api_failures_propagate_without_searching_or_compiling(candidates, mode, error):
    candidates["error"] = error
    with pytest.raises(type(error)):
        lookup(mode, candidates)
    assert candidates["seen"] == [1]


def test_pull_retries_until_deadline_before_raising_qualification_error(
    candidates, monkeypatch
):
    candidates["all_bad"] = True
    clock = iter([0, 0, 0, 2])
    monkeypatch.setattr(artifacts.time, "monotonic", lambda: next(clock))
    monkeypatch.setattr(artifacts.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(artifacts, "waiting_for_dependency", lambda *args: [71])
    with pytest.raises(ValueError, match="require requalification"):
        lookup("pull", candidates, wait=1)
    assert candidates["lists"] == 2


def test_only_bad_artifacts_never_reach_local_compilation(candidates, monkeypatch):
    candidates["all_bad"] = True
    monkeypatch.setattr(macos, "fingerprint", lambda *args: IDENTITY)
    monkeypatch.setattr(macos, "pull", artifacts.pull)
    monkeypatch.setattr(
        macos.subprocess, "run", lambda *args, **kwargs: pytest.fail("Must not compile")
    )
    with pytest.raises(ValueError, match="require requalification"):
        macos.ensure(COMPONENT, candidates["destination"], "owner/repo", wait=0)


def test_other_head_producer_is_ignored_when_current_head_has_a_live_producer(
    monkeypatch,
):
    runs = [
        {"id": number, "head_sha": str(number) * 40, "status": "in_progress"}
        for number in (1, 2)
    ]
    monkeypatch.setattr(macos, "api", lambda *args: {"workflow_runs": runs})
    monkeypatch.setattr(macos, "trusted_run", lambda *args: True)
    monkeypatch.setattr(macos, "dependency_jobs", lambda *args: [])
    monkeypatch.setattr(macos, "fingerprint", lambda *args: IDENTITY)

    def source(repo, sha, *args, **kwargs):
        if sha.startswith("1"):
            raise ValueError("Older workflow lacks supported recipe markers")
        return IDENTITY

    monkeypatch.setattr(macos, "source_fingerprint", source)
    assert macos.waiting_producers("owner/repo", "macos-sdk", "2" * 40, 112) == [2]


@pytest.mark.parametrize(
    "error",
    [
        subprocess.CalledProcessError(1, "gh"),
        json.JSONDecodeError("Invalid API response", "", 0),
    ],
)
def test_running_source_api_failure_does_not_become_incompatible_miss(
    monkeypatch, error
):
    monkeypatch.setattr(
        macos,
        "api",
        lambda *args: {
            "workflow_runs": [{"id": 1, "head_sha": "1" * 40, "status": "in_progress"}]
        },
    )
    monkeypatch.setattr(macos, "trusted_run", lambda *args: True)
    monkeypatch.setattr(macos, "dependency_jobs", lambda *args: [])
    monkeypatch.setattr(macos, "fingerprint", lambda *args: IDENTITY)

    def source(*args, **kwargs):
        raise error

    monkeypatch.setattr(macos, "source_fingerprint", source)
    with pytest.raises(type(error)):
        macos.waiting_producers("owner/repo", "macos-sdk", "1" * 40, 112)
