"""Relevant recipe changes invalidate their closure; CI transport edits do not."""

import json

import pytest
import yaml

from tools import ci_artifacts as artifacts
from tools import sdk_build_recipe
from tools.sdk_workflow_recipe import JOBS


@pytest.fixture
def source(tmp_path):
    for files in artifacts.FILES.values():
        for name in files:
            path = tmp_path / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((artifacts.ROOT / name).read_bytes())
    return tmp_path


def identities(root):
    return {name: artifacts.fingerprint(name, root) for name in artifacts.FILES}


@pytest.mark.parametrize(
    "key",
    ["dart", "flutter", "litert_linux_wheel", "ubuntu_snapshot", "ubuntu_bootstrap_ca"],
)
def test_unconsumed_pin_metadata_preserves_all_recipe_identities(source, key):
    before = identities(source)
    path = source / "tools/pins.json"
    pins = json.loads(path.read_text())
    pins[key] = "unrelated metadata change"
    path.write_text(json.dumps(pins, indent=1))
    assert identities(source) == before


def test_litert_version_changes_only_its_two_platform_closures(source):
    before = identities(source)
    path = source / "tools/pins.json"
    pins = json.loads(path.read_text())
    pins["litert_lm"] = "new-runtime-version"
    path.write_text(json.dumps(pins))
    assert {
        name
        for name, identity in identities(source).items()
        if identity != before[name]
    } == {"linux-litert", "linux-sdk", "macos-vendor", "macos-runtime"}


@pytest.mark.parametrize(
    "old,new,affected",
    [
        ("--jobs 3", "--jobs 2", {"macos-sdk", "macos-vendor", "macos-runtime"}),
        (
            "runs-on: ubuntu-24.04",
            "runs-on: ubuntu-26.04",
            {"linux-core", "linux-litert", "linux-whisper", "linux-sdk"},
        ),
        (
            "MACOSX_DEPLOYMENT_TARGET: '15.0'",
            "MACOSX_DEPLOYMENT_TARGET: '16.0'",
            {"macos-sdk", "macos-vendor", "macos-runtime"},
        ),
        (
            "file: packaging/sdk-litert.Dockerfile",
            "file: packaging/changed.Dockerfile",
            {"linux-litert", "linux-sdk"},
        ),
        (
            "build-args: CORE_IMAGE=${{ needs.core.outputs.image }}",
            "build-args: CORE_IMAGE=changed-parent",
            {"linux-litert", "linux-whisper", "linux-sdk"},
        ),
    ],
)
def test_actual_workflow_build_settings_invalidate_matching_closure(
    source, old, new, affected
):
    before = identities(source)
    path = source / artifacts.WORKFLOW
    assert old in path.read_text()
    path.write_text(path.read_text().replace(old, new))
    assert {
        name
        for name, identity in identities(source).items()
        if identity != before[name]
    } == affected


@pytest.mark.parametrize(
    "old,new",
    [
        ("timeout-minutes: 120", "timeout-minutes: 121"),
        ("retention-days: 90", "retention-days: 60"),
        ("compression-level: 0", "compression-level: 1"),
    ],
)
def test_transport_and_job_budget_changes_preserve_every_identity(source, old, new):
    before = identities(source)
    path = source / artifacts.WORKFLOW
    assert old in path.read_text()
    path.write_text(path.read_text().replace(old, new))
    assert identities(source) == before


def test_promotion_implementation_and_app_code_are_not_recipe_inputs(source):
    before = identities(source)
    for name in (
        "tools/ci_artifacts.py",
        "tools/linux_sdk_artifacts.py",
        "tools/sdk_final_approval.py",
        "tools/ci_stage_cache.py",
        "tools/ci_sanitizer_artifacts.py",
        "apps/desktop/lib/main.dart",
    ):
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("changed promotion, logging or application code")
    assert identities(source) == before


@pytest.mark.parametrize(
    "addition",
    [
        "    - name: New compiler invocation\n      run: cmake --build build\n",
        '    - name: Retain small cache receipt\n      run: echo MALICIOUS=1 >> "$GITHUB_ENV"\n',
        "    - name: Retain small cache receipt\n      run: printf altered > tools/build_macos_sdk.py\n",
    ],
)
def test_unmarked_new_build_behavior_fails_closed(source, addition):
    path = source / artifacts.WORKFLOW
    path.write_text(
        path.read_text()
        .replace(
            "    - name: Build or verify SDK\n",
            addition + "    - name: Build or verify SDK\n",
        )
        .replace(
            "    # sdk-recipe: macos-sdk begin\n" + addition,
            addition + "    # sdk-recipe: macos-sdk begin\n",
        )
    )
    with pytest.raises(ValueError, match="Unaccounted"):
        identities(source)


@pytest.mark.parametrize(
    "setting", ["defaults:\n  run:\n    shell: sh\n", "env:\n  CXXFLAGS: changed\n"]
)
def test_unaccounted_global_build_settings_fail_closed(source, setting):
    path = source / artifacts.WORKFLOW
    path.write_text(setting + path.read_text())
    with pytest.raises(ValueError, match="Global SDK build settings"):
        identities(source)


def test_removed_recipe_marker_fails_closed(source):
    path = source / artifacts.WORKFLOW
    path.write_text(
        path.read_text().replace("    # sdk-recipe: macos-sdk begin\n", "", 1)
    )
    with pytest.raises(ValueError):
        identities(source)


def test_yaml_parser_agrees_with_bootstrap_job_step_projection():
    workflow = yaml.safe_load((artifacts.ROOT / artifacts.WORKFLOW).read_text())
    for job, owners in JOBS.items():
        for owner in owners:
            fields = []
            steps = []
            for region in artifacts.recipe_regions(
                artifacts.ROOT / artifacts.WORKFLOW, owner
            ):
                if region.lstrip().startswith("- "):
                    steps.extend(yaml.safe_load("steps:\n" + region)["steps"])
                else:
                    fields.append(yaml.safe_load(region))
            assert {"runs-on": workflow["jobs"][job]["runs-on"]} in fields
            for step in workflow["jobs"][job]["steps"]:
                if step.get("uses", "").startswith(
                    (
                        "actions/setup-python@",
                        "actions/checkout@",
                        "docker/setup-buildx-action@",
                        "docker/build-push-action@",
                    )
                ) or step.get("name", "").startswith(
                    ("Build or verify", "Reuse or build", "Install compiler")
                ):
                    assert step in steps


def test_docker_build_invocation_is_consumed_from_its_hashed_recipe(tmp_path):
    from tools import linux_sdk_artifacts as producer

    assert "tools/sdk_build_recipe.py" in artifacts.FILES["linux-litert"]
    command = sdk_build_recipe.docker_build_command(
        "linux-litert", "output", {"linux-core": "parent@sha256:123"}, tmp_path
    )
    assert command == [
        "docker",
        "build",
        "-f",
        str(tmp_path / "packaging/sdk-litert.Dockerfile"),
        "-t",
        "output",
        "--build-arg",
        "CORE_IMAGE=parent@sha256:123",
        str(tmp_path),
    ]
    assert producer.docker_build_command is sdk_build_recipe.docker_build_command


def test_new_consumed_speech_header_and_mode_are_bound(source):
    before = identities(source)
    header = source / "services/speech/additional.h"
    header.write_text("// additional worker source\n")
    after = identities(source)
    assert {name for name in before if before[name] != after[name]} == {
        "linux-sdk",
        "macos-runtime",
    }
    header.chmod(0o755)
    assert identities(source)["linux-sdk"] != after["linux-sdk"]


def test_matrix_build_settings_cannot_escape_recipe(source):
    path = source / artifacts.WORKFLOW
    path.write_text(
        path.read_text().replace(
            "        - sdk\n", "        - sdk\n        compiler: [clang]\n", 1
        )
    )
    with pytest.raises(ValueError, match="matrix"):
        identities(source)


def test_bootstrap_cache_uses_the_same_semantic_identity():
    workflow = yaml.safe_load((artifacts.ROOT / artifacts.WORKFLOW).read_text())
    bootstrap = next(
        step
        for step in workflow["jobs"]["macos"]["steps"]
        if step.get("name") == "Bootstrap from existing sdk cache"
    )
    assert bootstrap["with"]["key"] == "macos15-arm64-sdk-${{ env.IDENTITY }}"


@pytest.mark.parametrize(
    "key", ["name", "timeout-minutes", "retention-days", "compression-level"]
)
def test_shell_functions_that_look_like_yaml_fields_are_never_normalized(source, key):
    path = source / artifacts.WORKFLOW
    command = (
        f"        {key}:(){{ printf altered > tools/build_macos_sdk.py; }}; {key}:\n"
    )
    path.write_text(
        path.read_text().replace(
            "        echo 'hit=true' >> \"$GITHUB_OUTPUT\"\n",
            "        echo 'hit=true' >> \"$GITHUB_OUTPUT\"\n" + command,
            1,
        )
    )
    with pytest.raises(ValueError, match="Unaccounted SDK build step"):
        identities(source)


def test_sdk_retry_uploads_and_original_forwarding_are_explicit():
    jobs = yaml.safe_load((artifacts.ROOT / artifacts.WORKFLOW).read_text())["jobs"]
    for job in JOBS:
        payload = next(
            step for step in jobs[job]["steps"] if step.get("id") == "payload"
        )
        assert payload["with"]["overwrite"] is True
    for job in ("linux-pr-core", "linux-pr-runtime", "linux-pr"):
        steps = jobs[job]["steps"]
        setup = next(
            i
            for i, step in enumerate(steps)
            if step.get("name") == "Enable read-only registry layer reuse"
        )
        produce = next(
            i for i, step in enumerate(steps) if step.get("id") == "component"
        )
        assert setup < produce
        assert steps[setup]["if"] == "steps.probe.outputs.hit != 'true'"
        assert (
            steps[setup]["with"]["daemon-config"].strip()
            == '{"features":{"containerd-snapshotter":true}}'
        )
        for step in steps[produce + 1 :]:
            if step.get("name") == "Record final runner storage":
                assert step["if"] == "always()"
                assert step["run"] == "df -h / /mnt\ndocker system df\n"
                continue
            assert "steps.component.outputs.original != 'true'" in step["if"]


@pytest.mark.parametrize(
    "addition",
    [
        "  extra-sdk-job:\n    name: Build Linux litert\n    runs-on: ubuntu-24.04\n    steps:\n    - run: printf altered > build/fake-sdk\n",
        '  extra-sdk-job: {name: Build Linux litert, runs-on: ubuntu-24.04, steps: [{run: "printf altered"}]}\n',
    ],
)
def test_unaccounted_producer_jobs_fail_closed(source, addition):
    path = source / artifacts.WORKFLOW
    path.write_text(path.read_text() + addition)
    with pytest.raises(ValueError, match="job"):
        identities(source)


@pytest.mark.parametrize(
    "old,new",
    [
        ("  plan:\n", "  plan:\n    name: Build Linux litert\n"),
        ("name: Build Linux litert", "name: ${{ 'Build Linux litert' }}"),
        ("        - whisper\n", "        - core\n"),
    ],
)
def test_auxiliary_display_and_matrix_aliases_cannot_spoof_component_jobs(
    source, old, new
):
    path = source / artifacts.WORKFLOW
    path.write_text(path.read_text().replace(old, new, 1))
    with pytest.raises(ValueError):
        identities(source)
