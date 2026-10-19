"""Opt-in real BuildKit proof using a cached Ubuntu base and fake external tools.

Run FORESIGHT_DOCKER_CACHE_TEST=1 python -m pytest tests/test_acceptance_image_cache.py.
No SDK, application or vendor code is compiled; the build network is disabled.
"""

import os
from pathlib import Path
import shutil
import subprocess
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
BASE = "ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac"
pytestmark = pytest.mark.skipif(
    os.environ.get("FORESIGHT_DOCKER_CACHE_TEST") != "1",
    reason="Opt-in real Docker acceptance-cache fixture",
)


def test_real_buildkit_preserves_setup_across_source_edits_and_invalidates_manifests(
    tmp_path,
):
    def run(args):
        result = subprocess.run(args, text=True, capture_output=True, timeout=120)
        with (tmp_path / "commands.log").open("a") as log:
            log.write(str(args) + "\n" + result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout + result.stderr

    # Reuse an existing base; this offline fixture never pulls or builds an SDK.
    run(["docker", "image", "inspect", BASE])
    tag = "foresight-acceptance-cache-fixture-" + uuid.uuid4().hex
    sdk, app = tag + ":sdk", tag + ":app"
    fixture = tmp_path / "fixture"
    fixture.mkdir()
    tool = fixture / "tool"
    tool.write_text("""#!/bin/bash
set -euo pipefail
name=$(basename "$0")
if [[ "$name" == git ]]; then
  if [[ "$*" == *rev-parse* ]]; then echo adc901062556672b4138e18a4dc62a4be8f4b3c2; fi
elif [[ "$name" == python3 ]]; then
  grep -q '"frameworkVersion":"3.35.7"'
elif [[ "$name" == flutter && "$*" == *--version* ]]; then
  echo '{"frameworkVersion":"3.35.7"}'
else
  if [[ "$name" == dart || "$name" == flutter ]]; then
    test -f pubspec.yaml && test -f pubspec.lock
    test -f /src/packages/foresight_core/pubspec.yaml
    test -f /src/packages/foresight_test_support/pubspec.yaml
  fi
  printf '%s %s\\n' "$name" "$*" >> /setup-trace
fi
""")
    tool.chmod(0o755)
    (fixture / "Dockerfile").write_text(f"""FROM {BASE}
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY tool /fixture/tool
RUN for name in apt-get git flutter dart python3; do ln -s /fixture/tool /usr/local/bin/$name; done
""")
    try:
        run(["docker", "build", "--network=none", "-t", sdk, str(fixture)])
        context = tmp_path / "source"
        context.mkdir()
        shutil.copy2(ROOT / "packaging/acceptance.Dockerfile", context / "Dockerfile")
        for package in (
            "packages/foresight_core",
            "packages/foresight_test_support",
            "apps/desktop",
        ):
            target = context / package
            target.mkdir(parents=True)
            shutil.copy2(ROOT / package / "pubspec.yaml", target / "pubspec.yaml")
            if (ROOT / package / "pubspec.lock").exists():
                shutil.copy2(ROOT / package / "pubspec.lock", target / "pubspec.lock")
        source = context / "test-source.txt"
        source.write_text("first source")
        build = [
            "docker",
            "build",
            "--progress=plain",
            "--network=none",
            "--build-arg",
            "SDK_IMAGE=" + sdk,
            "-t",
            app,
            str(context),
        ]
        run(build)
        original = run(["docker", "run", "--rm", app, "cat", "/setup-trace"])
        assert (
            "apt-get" in original
            and "dart pub get" in original
            and "flutter pub get" in original
        )
        source.write_text("new source without dependency changes")
        second = run(build)
        assert "CACHED" in second
        assert (
            run(["docker", "run", "--rm", app, "cat", "/src/test-source.txt"]).strip()
            == source.read_text()
        )
        assert run(["docker", "run", "--rm", app, "cat", "/setup-trace"]) == original
        # The complete dependency stage must be cached, including both pub runs.
        for command in ("dart pub get", "flutter pub get"):
            lines = second.splitlines()
            start = next(
                i
                for i, line in enumerate(lines)
                if "] RUN cd " in line and command in line
            )
            assert "CACHED" in lines[start + 1]
        manifest = context / "packages/foresight_test_support/pubspec.yaml"
        manifest.write_text(
            manifest.read_text() + f"\n# changed dependency declaration {tag}\n"
        )
        third = run(build)
        for command in ("dart pub get", "flutter pub get"):
            lines = third.splitlines()
            start = next(
                i
                for i, line in enumerate(lines)
                if "] RUN cd " in line and command in line
            )
            assert "CACHED" not in lines[start + 1]
    finally:
        # Remove only this test's tags, never SDK images or shared build caches.
        run(["docker", "image", "rm", "-f", app, sdk])
