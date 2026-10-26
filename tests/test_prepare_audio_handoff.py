"""Audio reuses qualified source bytes instead of compiling a substitute."""

import importlib.util
import json
from pathlib import Path
from unittest.mock import Mock

import pytest


@pytest.fixture
def subject(monkeypatch, tmp_path):
    path = Path(__file__).parents[1] / "tools/prepare_audio_handoff.py"
    spec = importlib.util.spec_from_file_location("audio_handoff", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/pins.json").write_text('{"ubuntu_snapshot":"20261001T000000Z"}')
    monkeypatch.setattr(module.ci_app_dependency_seed, "prepare", Mock())
    monkeypatch.setattr(module.ci_app_dependency_seed, "verify_existing", Mock())
    monkeypatch.setattr(
        module.subprocess,
        "check_output",
        Mock(return_value="sha256:" + "a" * 64 + "\n"),
    )
    monkeypatch.setattr(
        module.ci_tooling_image, "identity", Mock(return_value={"identity": "expected"})
    )
    monkeypatch.setattr(
        module.ci_linux_handoff,
        "input_identity",
        Mock(return_value={"identity": "independent"}),
    )
    return module


def test_derives_expected_inputs_from_actual_sdk_seed_and_producer_recipe(
    subject, tmp_path
):
    seed, output, cache = (tmp_path / name for name in ("seed", "control", "cache"))
    subject.prepare("sdk:qualified", output, seed, cache, tmp_path)
    subject.ci_app_dependency_seed.prepare.assert_called_once_with(
        "sdk:qualified", seed, cache, tmp_path
    )
    subject.ci_app_dependency_seed.verify_existing.assert_not_called()
    subject.ci_tooling_image.identity.assert_called_once_with(
        "sha256:" + "a" * 64, "20261001T000000Z", tmp_path
    )
    subject.ci_linux_handoff.input_identity.assert_called_once_with(
        "sdk:qualified",
        seed / "qualification.json",
        tmp_path / "packaging/build.Dockerfile",
        "20261001T000000Z",
        output / "expected-tooling-inputs.json",
    )
    assert json.loads((output / "ci-inputs.json").read_text()) == {
        "identity": "independent"
    }
    assert json.loads((output / "expected-tooling-inputs.json").read_text()) == {
        "inputs": {"identity": "expected"}
    }


def test_existing_dependency_seed_is_reverified(subject, tmp_path):
    seed = tmp_path / "seed"
    seed.mkdir()
    subject.prepare("sdk", tmp_path / "control", seed, tmp_path / "cache", tmp_path)
    subject.ci_app_dependency_seed.prepare.assert_not_called()
    subject.ci_app_dependency_seed.verify_existing.assert_called_once()


@pytest.mark.parametrize("provider", ["seed", "tooling", "inputs"])
def test_refusal_never_publishes_consumer_inputs(subject, tmp_path, provider):
    target = {
        "seed": subject.ci_app_dependency_seed.prepare,
        "tooling": subject.ci_tooling_image.identity,
        "inputs": subject.ci_linux_handoff.input_identity,
    }[provider]
    target.side_effect = ValueError("qualified inputs differ")
    with pytest.raises(ValueError, match="qualified inputs differ"):
        subject.prepare(
            "sdk", tmp_path / "control", tmp_path / "seed", tmp_path / "cache", tmp_path
        )
    assert not (tmp_path / "control/ci-inputs.json").exists()


def test_audio_restores_before_readonly_portable_mount_and_does_not_build_app():
    root = Path(__file__).parents[1]
    script = (root / "tools/linux_acceptance.sh").read_text()
    assert script.index(
        "/handoff-control/tools/ci_linux_handoff.py restore --root /src"
    ) < script.index("--suite virtual-audio --bundle /portable")
    assert '-v "$task_audio_volume:/src"' in script
    assert '-v "$PWD/build/portable/dist/open-foresight:/portable:ro"' in script
    assert 'chown "$2:$3" /src' in script
    assert script.index(
        "--workspace /src --flutter-root /opt/flutter --"
    ) < script.index("dbus-run-session -- python3 tools/integration_gates.py")
    assert "build_diagnostic_worker" not in script
    assert "build.sh" not in script
    workflow = (
        (root / ".github/workflows/macos.yml")
        .read_text()
        .split("  acceptance-audio:", 1)[1]
    )
    assert "needs.linux-build.outputs.handoff_id" in workflow
    assert "needs.linux-build.outputs.handoff_digest" in workflow
    assert '--run-id "$GITHUB_RUN_ID" --attempt "$PRODUCER_ATTEMPT"' in workflow
