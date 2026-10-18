"""Run the shared adversarial corpus through the shipped native checker."""

import json
from pathlib import Path
import subprocess
import sys


def check_corpus(binary):
    cases = json.loads((Path(__file__).parent / "grounding_cases.json").read_text())
    native = subprocess.run(
        [binary, "--validate"],
        input="".join(json.dumps(case) + "\n" for case in cases),
        text=True,
        capture_output=True,
        check=True,
    )
    rows = native.stdout.splitlines()
    if len(rows) != len(cases):
        raise AssertionError(native.stdout)
    for case, row in zip(cases, rows):
        if (not json.loads(row)) != case["valid"]:
            raise AssertionError((case, row))
    print(f"Native grounding corpus: {len(cases)} cases passed")


if __name__ == "__main__":
    check_corpus(sys.argv[1])
