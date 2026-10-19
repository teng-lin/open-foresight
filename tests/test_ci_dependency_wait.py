"""Consumer waits preserve SDK bytes and fail closed without rebuilding."""

from unittest.mock import Mock

import pytest

from tools import ci_dependency_wait as waiter


@pytest.mark.parametrize("wait", [-1, 0, 40, 9000])
def test_absent_artifact_wait_is_bounded_and_never_changes_producer_inputs(
    monkeypatch, tmp_path, wait
):
    now = [0]
    pull = Mock(return_value=False)
    monkeypatch.setattr(waiter.artifacts, "fingerprint", lambda component: "identity")
    monkeypatch.setattr(waiter.artifacts, "pull", pull)
    monkeypatch.setattr(waiter, "waiting_producers", Mock(return_value=[71]))
    monkeypatch.setattr(waiter.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(
        waiter.time, "sleep", lambda seconds: now.__setitem__(0, now[0] + seconds)
    )
    with pytest.raises(RuntimeError, match="Verified linux-sdk identity"):
        waiter.fetch("owner/repo", "linux-sdk", tmp_path, "a" * 40, 23, wait)
    assert now[0] == max(0, min(wait, 1800))
    assert all(
        call.args == ("owner/repo", "linux-sdk", "identity", tmp_path)
        and call.kwargs == {"own_head": "a" * 40, "own_pr": 23}
        for call in pull.call_args_list
    )


def test_requeries_original_verified_artifact_after_wait(monkeypatch, tmp_path):
    pull = Mock(side_effect=[False, True])
    waiting = Mock(return_value=[71])
    sleep = Mock()
    monkeypatch.setattr(waiter.artifacts, "fingerprint", lambda component: "identity")
    monkeypatch.setattr(waiter.artifacts, "pull", pull)
    monkeypatch.setattr(waiter, "waiting_producers", waiting)
    monkeypatch.setattr(waiter.time, "sleep", sleep)
    monkeypatch.setattr(waiter.time, "monotonic", lambda: 0)
    waiter.fetch("owner/repo", "linux-sdk", tmp_path, "a" * 40, 23)
    assert pull.call_count == 2
    waiting.assert_called_once_with("owner/repo", "linux-sdk", "a" * 40, 23)
    sleep.assert_called_once_with(20)


@pytest.mark.parametrize("failure", ["transport", "provenance", "no-producer"])
def test_unresolved_or_missing_producer_never_authorizes_a_build(
    monkeypatch, tmp_path, failure
):
    monkeypatch.setattr(waiter.artifacts, "fingerprint", lambda component: "identity")
    monkeypatch.setattr(
        waiter.artifacts,
        "pull",
        Mock(side_effect=RuntimeError(failure))
        if failure != "no-producer"
        else Mock(return_value=False),
    )
    waiting = Mock(return_value=[])
    sleep = Mock()
    monkeypatch.setattr(waiter, "waiting_producers", waiting)
    monkeypatch.setattr(waiter.time, "sleep", sleep)
    with pytest.raises(RuntimeError):
        waiter.fetch("owner/repo", "linux-sdk", tmp_path, "a" * 40, 23)
    assert waiting.call_count == (1 if failure == "no-producer" else 0)
    sleep.assert_not_called()


def test_cli_forwards_explicit_consumer_context(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setattr(
        "sys.argv",
        [
            "ci_dependency_wait.py",
            "--component",
            "linux-sdk",
            "--prefix",
            str(tmp_path),
            "--own-head",
            "a" * 40,
            "--own-pr",
            "23",
            "--wait",
            "60",
        ],
    )
    fetch = Mock()
    monkeypatch.setattr(waiter, "fetch", fetch)
    waiter.main()
    fetch.assert_called_once_with("owner/repo", "linux-sdk", tmp_path, "a" * 40, 23, 60)
