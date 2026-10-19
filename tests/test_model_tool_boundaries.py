"""Model acquisition and evaluation reject corrupt inputs and invalid results."""

import hashlib
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import download_embeddinggemma2 as download
import evaluate_embeddinggemma2 as evaluate
import verify_preview_cloud as cloud


@pytest.fixture
def pinned_download(tmp_path, monkeypatch):
    content = b"tiny pinned model\n"
    monkeypatch.setattr(download, "SIZE", len(content))
    monkeypatch.setattr(download, "SHA256", hashlib.sha256(content).hexdigest())
    monkeypatch.setattr(sys, "argv", ["download", "--destination", str(tmp_path)])
    opening = Mock(return_value=io.BytesIO(content))
    monkeypatch.setattr(download.urllib.request, "urlopen", opening)
    return content, opening


def test_download_checks_pin_and_reuses_existing_model(tmp_path, pinned_download):
    content, opening = pinned_download
    download.main()
    target = tmp_path / download.FILENAME
    assert target.read_bytes() == content
    receipt = json.loads((tmp_path / "asset-provenance.json").read_text())
    assert receipt["sha256"] == hashlib.sha256(content).hexdigest()
    assert receipt["bytes"] == len(content)
    assert download.REVISION in opening.call_args.args[0]
    assert opening.call_args.kwargs["timeout"] == 30
    download.main()
    opening.assert_called_once()
    assert not list(tmp_path.glob("*.part"))


@pytest.mark.parametrize("corruption", [b"short", b"x" * len(b"tiny pinned model\n")])
def test_download_preserves_corrupt_existing_file_without_replacing_it(
    tmp_path, pinned_download, corruption
):
    _, opening = pinned_download
    target = tmp_path / download.FILENAME
    target.write_bytes(corruption)
    with pytest.raises(RuntimeError, match="preserved"):
        download.main()
    assert target.read_bytes() == corruption
    opening.assert_not_called()
    assert not (tmp_path / "asset-provenance.json").exists()


@pytest.mark.parametrize("failure", ["size", "hash", "network", "race"])
def test_failed_download_cleans_partial_and_never_publishes_unverified_receipt(
    tmp_path, monkeypatch, pinned_download, failure
):
    content, opening = pinned_download
    if failure == "size":
        opening.return_value = io.BytesIO(b"short")
    elif failure == "hash":
        opening.return_value = io.BytesIO(b"x" * len(content))
    elif failure == "network":
        opening.side_effect = OSError("network failed")
    else:

        def competing_link(source, target):
            target.write_bytes(b"other writer")
            raise FileExistsError("concurrent writer")

        monkeypatch.setattr(download.os, "link", competing_link)
    with pytest.raises((RuntimeError, OSError)):
        download.main()
    assert not list(tmp_path.glob("*.part"))
    assert not (tmp_path / "asset-provenance.json").exists()
    target = tmp_path / download.FILENAME
    if failure == "race":
        assert target.read_bytes() == b"other writer"
    else:
        assert not target.exists()


@pytest.mark.parametrize("backend", ["cpu", "gpu"])
@pytest.mark.parametrize(
    "failure", [None, "dimension", "nan", "norm", "ranking", "compute"]
)
def test_embedding_evaluation_checks_vectors_rankings_and_closes_engine(
    tmp_path, monkeypatch, backend, failure
):
    model = tmp_path / "model"
    model.write_bytes(b"model bytes")
    report = tmp_path / "reports/evaluation.json"
    monkeypatch.setattr(evaluate, "SIZE", model.stat().st_size)
    monkeypatch.setattr(evaluate, "SHA256", download.file_hash(model))
    monkeypatch.setattr(
        evaluate.importlib.metadata, "version", lambda name: "fixture-runtime"
    )
    vectors = []
    for index in range(6):
        vector = [0.0] * 768
        vector[(index % 3) if failure != "ranking" else 0] = 1.0
        vectors.append(vector)
    if failure == "dimension":
        vectors[0] = [1.0]
    elif failure == "nan":
        vectors[0][0] = float("nan")
    elif failure == "norm":
        vectors[0][0] = 2.0
    responses = iter(vectors)
    engine = SimpleNamespace(
        compute_embedding=Mock(
            side_effect=RuntimeError("compute failed")
            if failure == "compute"
            else lambda *a, **kw: SimpleNamespace(embedding=next(responses))
        ),
        close=Mock(),
    )
    runtime = SimpleNamespace(
        Backend=SimpleNamespace(
            GPU=Mock(return_value="gpu"), CPU=Mock(return_value="cpu")
        ),
        EmbeddingEngine=Mock(return_value=engine),
        EmbeddingOptions=Mock(return_value="options"),
        InputOverflowStrategy=SimpleNamespace(ERROR="error"),
    )
    monkeypatch.setitem(sys.modules, "litert_lm", runtime)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "evaluate",
            "--model",
            str(model),
            "--report",
            str(report),
            "--backend",
            backend,
        ],
    )
    if failure:
        with pytest.raises(RuntimeError):
            evaluate.main()
        assert not report.exists()
    else:
        evaluate.main()
        data = json.loads(report.read_text())
        assert data["all_vectors_finite"] is True
        assert data["all_vectors_l2_normalized"] is True
        assert len(data["embedding_seconds"]) == 6
        assert [r["ranking"][0] for r in data["independent_query_rankings"]] == [
            0,
            1,
            2,
        ]
        assert data["runtime_version"] == "fixture-runtime"
        assert (
            engine.compute_embedding.call_args_list[0]
            .args[0]
            .startswith("title: none | text:")
        )
        assert (
            engine.compute_embedding.call_args_list[3]
            .args[0]
            .startswith("task: search result | query:")
        )
    engine.close.assert_called_once()
    assert runtime.EmbeddingEngine.call_args.kwargs["backend"] == backend
    runtime.EmbeddingOptions.assert_called_once_with(
        normalize=True, output_size=768, input_overflow_strategy="error"
    )


def test_evaluation_rejects_wrong_model_before_loading_runtime(tmp_path, monkeypatch):
    model = tmp_path / "model"
    model.write_bytes(b"untrusted")
    monkeypatch.setattr(sys, "argv", ["evaluate", "--model", str(model)])
    with pytest.raises(ValueError, match="pinned"):
        evaluate.main()


@pytest.mark.parametrize("app", [False, True])
def test_cloud_acceptance_uses_bundle_config_and_discards_inherited_keys(
    tmp_path, monkeypatch, app
):
    bundle = tmp_path / ("Bundle.app" if app else "bundle")
    if app:
        resources = bundle / "Contents/Resources"
        resources.mkdir(parents=True)
        (resources / "runtime.json").write_text(
            json.dumps(dict.fromkeys(cloud.KEYS, "bundle value"))
        )
    else:
        bundle.mkdir()
        (bundle / "open-foresight").write_text(
            "\n".join(f"export {key}='bundle value'" for key in cloud.KEYS)
        )
    for key in (*cloud.KEYS, "FORESIGHT_RESOURCES"):
        monkeypatch.setenv(key, "inherited secret")

    def run(command, **kwargs):
        if command[1] == "run":
            env = kwargs["env"]
            if app:
                assert not any(key in env for key in cloud.KEYS)
                assert env["FORESIGHT_RESOURCES"] == str(resources.resolve())
            else:
                assert all(env[key] == "bundle value" for key in cloud.KEYS)
                assert "FORESIGHT_RESOURCES" not in env
            kwargs["stdout"].write(b"acceptance evidence")

    monkeypatch.setattr(cloud.subprocess, "run", run)
    report = tmp_path / "reports/cloud.log"
    cloud.verify(bundle, report)
    assert report.read_bytes() == b"acceptance evidence"


@pytest.mark.parametrize("value", ["", "one two"])
def test_cloud_config_rejects_missing_or_malformed_values(tmp_path, value):
    (tmp_path / "open-foresight").write_text(
        "\n".join(f"export {key}={value}" for key in cloud.KEYS)
    )
    with pytest.raises(ValueError):
        cloud.configuration(tmp_path)
    bundle = tmp_path / "Bad.app/Contents/Resources"
    bundle.mkdir(parents=True)
    (bundle / "runtime.json").write_text("{}")
    with pytest.raises(ValueError, match="distribution"):
        cloud.configuration(tmp_path / "Bad.app")
