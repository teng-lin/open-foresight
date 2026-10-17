"""Run the same adversarial corpus through both shipped grounding checkers."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "shipped_grounding", ROOT / "services/inference/macos/grounded_generation.py"
)
grounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grounded)


def check_parity(binary):
    cases = json.loads((ROOT / "tests/inference/grounding_cases.json").read_text())
    native = subprocess.run(
        [binary, "--validate"],
        input="".join(json.dumps(case) + "\n" for case in cases),
        text=True,
        capture_output=True,
        check=True,
        timeout=300,
    )
    rows = native.stdout.splitlines()
    if len(rows) != len(cases):
        raise AssertionError(native.stdout)
    for case, row in zip(cases, rows, strict=False):
        python_errors = grounded.validate_draft(case["text"], case["evidence"])
        if json.loads(row) != python_errors:
            raise AssertionError((case, row, python_errors))
        if (not python_errors) != case["valid"]:
            raise AssertionError((case, python_errors))
    print(f"C++/shipped Python grounding parity: {len(cases)} cases passed")


if __name__ == "__main__":
    check_parity(sys.argv[1])
