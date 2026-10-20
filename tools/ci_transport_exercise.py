#!/usr/bin/env python3
"""Exercise real Docker SDK transport and current app gates on reviewed main.

Only qualified existing SDK bytes are loaded/exported. The source-scoped case
uses the fork-format archive; it never impersonates a pull_request event or
promotes PR bytes. No SDK producer, registry writer or vendor rebuild is called.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import ci_dependency_wait as waiter  # noqa: E402
from tools import ci_linux_shadow_sdk as shadow  # noqa: E402
from tools import integration_application as application  # noqa: E402
from tools import linux_sdk_artifacts as sdk  # noqa: E402
from tools import ci_rollout  # noqa: E402
from tools import ci_linux_handoff as handoff  # noqa: E402
from tools import compare_test_runs  # noqa: E402
from tools import check_coverage  # noqa: E402
from tools import platform_python_tests  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def run(command, *, root, output):
    result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5400)
    with (output / "commands.log").open("a") as stream:
        stream.write(json.dumps(command) + "\n" + result.stdout + "\n")
    print(result.stdout, flush=True)
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout)


def application_record(kind, source, directory):
    """Bind real build/test outputs; a publisher image alone has no such record."""
    manifest_path = directory / "handoff/source-build.json"
    manifest = json.loads(manifest_path.read_text())
    inputs = json.loads((directory / "ci-inputs.json").read_text())
    if manifest.get("source") != source or manifest.get("inputs") != inputs or manifest.get("archive_sha256") != handoff.digest(directory / "handoff/source-build.tar.gz"):
        raise ValueError("Application qualification differs from its actual handoff")
    reports = directory / "evidence"
    junit = {}
    for label, relative in (("native", "test-results/linux/native/results.xml"), ("service", "test-results/service/results.xml")):
        tree = ET.parse(reports / relative).getroot()  # noqa: S314 - local current-run JUnit
        cases = list(tree.iter("testcase"))
        if not cases or list(tree.iter("failure")) or list(tree.iter("error")) or (label == "service" and list(tree.iter("skipped"))):
            raise ValueError("Required fresh native/service qualification did not pass")
        junit[label] = {"tests": len(cases), "skipped": len(list(tree.iter("skipped")))}
    host_report = reports / "coverage/python/linux-contracts.xml"
    host_tree = ET.parse(host_report).getroot()  # noqa: S314 - local current-run JUnit
    if list(host_tree.iter("failure")) or list(host_tree.iter("error")):
        raise ValueError("Required host contracts failed")
    platform_python_tests.verify_execution("linux", host_report)
    languages = {}
    for label, events, coverage in (("core", "test-results/linux/core/core.events.jsonl", "coverage/core/lcov.info"), ("desktop", "test-results/linux/desktop/desktop.events.jsonl", "apps/desktop/coverage/lcov.info")):
        outcomes = compare_test_runs.outcomes(reports / events)
        covered, total = check_coverage.line_counts(reports / coverage)
        if covered * 100 < total * 90:
            raise ValueError("Actual qualification coverage is below the existing 90% gate")
        languages[label] = {"cases": sum(outcomes.values()), "skipped": sum(count for (*_, skip), count in outcomes.items() if skip), "covered": covered, "lines": total}
    return {"kind": kind, "source": source, "ci_inputs": inputs, "handoff_sha256": handoff.digest(manifest_path), "portable": handoff.portable_input(directory / "packages", source, required=True), "junit": junit, "languages": languages}


def exercise(kind, source, output, *, root=ROOT):
    if kind not in {"archive-sdk", "fork-sdk", "recipe-change"}:
        raise ValueError("Unknown real transport exercise")
    if (os.environ.get("GITHUB_REF"), os.environ.get("GITHUB_EVENT_NAME"), os.environ.get("GITHUB_SHA")) != ("refs/heads/main", "workflow_dispatch", source):
        raise ValueError("Transport qualification needs an actual reviewed-main dispatch")
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True, timeout=30).strip()
    if actual != source:
        raise ValueError("Qualification checkout differs from dispatched source")
    output.mkdir(parents=True, exist_ok=False)
    original_closure = ci_rollout.closure(root)
    repository = os.environ["GITHUB_REPOSITORY"]
    prefix = output / "verified"
    if not waiter.fetch(repository, "linux-sdk", prefix, source, 0, 1800):
        raise RuntimeError("No qualified SDK: this exercise cannot compile one")
    original = shadow.reference(prefix, repository)
    image = sdk.resolve(prefix, load_registry=True)
    original_image_id = sdk.inspect(image)
    details = {"kind": kind, "original_sdk": original, "image_id": original_image_id}
    recipe = root / "packaging/ci-tooling.Dockerfile"
    before = recipe.read_bytes()
    try:
        if kind in {"archive-sdk", "fork-sdk"}:
            envelope = output / "source-scoped"
            application.save_sdk(source, image, envelope, shadow=True, source_prefix=prefix)
            restored = output / "restored"
            receipt = json.loads((envelope / "identity.json").read_text())
            artifacts.unpack("linux-sdk", artifacts.fingerprint("linux-sdk"), envelope, restored)
            record = sdk.record(restored, "linux-sdk")
            if record.get("source_scope") != source or record.get("local_recipe_sha256") != artifacts.digest(root / "tools/linux_sdk_artifacts.py"):
                raise ValueError("Real source-scoped archive lost its source/recipe binding")
            if receipt.get("reused_from") != json.loads((prefix / ("source-qualification.json" if (prefix / "source-qualification.json").exists() else "approved-source.json")).read_text()):
                raise ValueError("Transport export lost original SDK provenance")
            image = sdk.load(restored, "linux-sdk", sdk.local_tag("linux-sdk"))
            if sdk.inspect(image) != original_image_id:
                raise ValueError("Real archive load changed the SDK image")
            details.update(transport="docker-archive", source_scope=source, payload_sha256=artifacts.digest(envelope / "payload.tar.gz"))
        else:
            # A harmless tooling-recipe change invalidates real setup layers;
            # verified SDK bytes and dependency outputs must remain reusable.
            marker = b"FROM ${SDK_IMAGE} AS ci-tooling\n"
            if before.count(marker) != 1:
                raise ValueError("Tooling recipe changed; update this bounded real exercise")
            recipe.write_bytes(before.replace(marker, marker + b'LABEL org.openforesight.qualification="recipe-change"\n'))
            details.update(base_recipe_sha256=hashlib.sha256(before).hexdigest(), exercised_recipe_sha256=artifacts.digest(recipe))
        run(["bash", "tools/build_linux_container.sh", "--sdk-image", image, "--output", str(output / "application")], root=root, output=output)
        if sdk.inspect(image) != original_image_id:
            raise ValueError("Application exercise changed the qualified SDK image")
    finally:
        if kind == "recipe-change":
            recipe.write_bytes(before)
    ci_rollout.compare(original_closure, ci_rollout.closure(root))
    details["application"] = application_record(kind, source, output / "application")
    (output / "exercise.json").write_text(json.dumps(details, indent=2, sort_keys=True) + "\n")
    return details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("archive-sdk", "fork-sdk", "recipe-change", "publisher"), required=True)
    parser.add_argument("--record-application", type=Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.record_application:
        value = application_record(args.kind, args.source, args.record_application)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    else:
        exercise(args.kind, args.source, args.output)


if __name__ == "__main__":
    main()
