#!/usr/bin/env python3
"""Relocate the real packaged runtime and run the dedicated worker in isolation.

No model is copied. --model points to a separately registered authenticated
fixture; omit it to verify actual NumPy/SentencePiece imports and model rejection.
"""

from typing import Any

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from package_macos import copy_python
from query_worker_packaging import copy_worker, MODULES
from macos_bundle import relocate_dependencies, audit_dependencies, binaries


def verify(prefix, model=None):
    with tempfile.TemporaryDirectory(prefix="foresight-query-package-") as directory:
        root = Path(directory)
        app = root / "before relocation.app"
        resources = app / "Contents/Resources"
        adapters = resources / "adapters"
        adapters.mkdir(parents=True)
        copy_worker(adapters)
        values: dict[str, Any] = {}
        copy_python(prefix, resources, values)
        relocate_dependencies(app)
        for file in binaries(app):
            subprocess.run(
                ["/usr/bin/codesign", "--force", "--sign", "-", str(file)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=True,
                timeout=300,
            )
        moved = root / "moved directory with spaces/Relocated.app"
        moved.parent.mkdir()
        app.rename(moved)
        resources = moved / "Contents/Resources"
        adapters = resources / "adapters"
        poisoned = root / "untrusted working directory"
        poisoned.mkdir()
        for name in ["numpy.py", "legacy_query_executor.py"]:
            (poisoned / name).write_text(
                'raise RuntimeError("loaded untrusted cwd module")\n'
            )
        environment = {"PATH": "/usr/bin:/bin", "PYTHONPATH": str(poisoned)}
        python = adapters / "litert-python"
        imports = subprocess.check_output(
            [
                str(python),
                "-I",
                "-B",
                "-c",
                "import json,numpy,sentencepiece;print(json.dumps([numpy.__version__,sentencepiece.__version__,numpy.__file__]))",
            ],
            env=environment,
            cwd=poisoned,
            text=True,
            timeout=300,
        )
        versions = json.loads(imports)
        assert versions[:2] == ["2.5.1", "0.2.1"], versions
        assert str(resources / "python") in versions[2], versions
        names = {file.name for file in adapters.iterdir()}
        assert names == {*MODULES, "litert-python", "litert-runner"}, names
        assert (resources / "licenses/numpy-licenses/LICENSE.txt").is_file()
        assert (resources / "licenses/numpy-licenses/numpy/random/LICENSE.md").is_file()
        assert (resources / "licenses/sentencepiece-licenses/LICENSE").is_file()
        worker = adapters / "legacy_query_worker.py"
        requests = [
            {
                "id": "positive",
                "prompt": " <ctrl1>We need to ship the launch soon. What risks could delay the launch?",
                "max_output_tokens": 512,
            },
            {
                "id": "negative",
                "prompt": " <ctrl1>The meeting starts at three.",
                "max_output_tokens": 512,
            },
        ]
        result = subprocess.run(
            [
                str(python),
                "-I",
                "-B",
                str(worker),
                "--model",
                str(model or root / "missing-model"),
            ],
            input="".join(json.dumps(request) + "\n" for request in requests),
            env=environment,
            cwd=poisoned,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )
        frames = [json.loads(line) for line in result.stdout.splitlines()]
        if model:
            assert result.returncode == 0 and frames[0]["type"] == "ready", (
                result.returncode,
                frames,
                result.stderr,
            )
            assert (
                frames[1]["id"] == "positive"
                and frames[1]["text"].strip() == "What risks could delay the launch?"
            ), frames
            assert frames[2]["id"] == "negative" and frames[2]["text"] == "", frames
        else:
            assert result.returncode == 1 and frames[0]["type"] == "fatal", frames
        assert not list(moved.rglob("*.tflite")) and not list(
            moved.rglob("Foresight.bundle")
        )
        linkage = audit_dependencies(moved)
        return {
            "relocated": True,
            "versions": versions[:2],
            "model_bundled": False,
            "original_oracle_bundled": False,
            "worker_exit": result.returncode,
            "frames": frames,
            "mach_o_binaries_audited": len(linkage),
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-runtime", required=True, type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Real Mach-O relocation check requires macOS")
    report = verify(args.python_runtime, args.model.resolve() if args.model else None)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
