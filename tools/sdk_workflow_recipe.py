"""Fail closed when compiler behavior escapes the delimited SDK build contract.

The bootstrap planner has no third party YAML dependency. This intentionally
accepts only the repository's block-style job/step layout; independent YAML
regressions check that these delimiters cover the actual workflow structure.
"""

import re
import json
from pathlib import Path

JOBS = {
    "macos": {"macos-sdk"},
    "macos-vendor": {"macos-vendor"},
    "macos-runtime": {"macos-runtime"},
    "core": {"linux-core"},
    "litert": {"linux-litert"},
    "whisper": {"linux-whisper"},
    "sdk": {"linux-sdk"},
    "linux-pr-core": {"linux-core"},
    "linux-pr-runtime": {"linux-litert", "linux-whisper"},
    "linux-pr": {"linux-sdk"},
}


def transport_body(lines):
    """Only presentation, retention and literal stdout logging are immaterial.

    Shell, environment and action inputs otherwise match reviewed templates;
    calling a step an upload cannot make arbitrary shell writes trustworthy.
    """
    return "".join(
        line
        for line in lines
        if line.strip()
        and not line.lstrip().startswith("#")
        and not re.match(
            r"\s*(?:- )?(?:name|timeout-minutes|retention-days|compression-level):",
            line,
        )
        and not re.fullmatch(r"\s*echo ['\"][A-Za-z0-9 .,!:()/-]*['\"]\s*", line)
    )


def validate(lines, coverage):
    contract = set(
        json.loads(Path(__file__).with_name("sdk_transport_contract.json").read_text())
    )
    """Every build-capable step and ambient build setting needs a recipe region."""
    starts = [
        (i, match[1])
        for i, line in enumerate(lines)
        if (match := re.fullmatch(r"  ([a-z][a-z-]*):\s*", line))
    ]
    found = set()
    for position, (start, job) in enumerate(starts):
        if job not in JOBS:
            continue
        found.add(job)
        owners = JOBS[job]
        stop = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        step_start = next(
            (i for i in range(start, stop) if lines[i].strip() == "steps:"), None
        )
        if step_start is None:
            raise ValueError("Missing SDK build steps: " + job)
        for i in range(start, step_start):
            if re.match(r"    (runs-on|env|defaults|container|services|strategy):", lines[i]):
                end = next(
                    (
                        j
                        for j in range(i + 1, step_start)
                        if re.match(r"    \S", lines[j])
                        and not lines[j].lstrip().startswith("#")
                    ),
                    step_start,
                )
                if any(
                    line.strip()
                    and not line.lstrip().startswith("#")
                    and not owners <= coverage[n]
                    for n, line in enumerate(lines[i:end], i)
                ):
                    raise ValueError("Unaccounted SDK build environment: " + job)
        steps = [
            i for i in range(step_start + 1, stop) if lines[i].startswith("    - ")
        ]
        for offset, i in enumerate(steps):
            end = steps[offset + 1] if offset + 1 < len(steps) else stop
            meaningful = [
                n
                for n in range(i, end)
                if lines[n].strip() and not lines[n].lstrip().startswith("#")
            ]
            if all(owners <= coverage[n] for n in meaningful):
                continue
            if transport_body(lines[i:end]) not in contract:
                raise ValueError(
                    "Unaccounted SDK build step: " + job + ": " + lines[i].strip()
                )
    if found != set(JOBS):
        raise ValueError("Missing SDK producer jobs")
    if any(re.match(r"^(env|defaults):", line) for line in lines):
        raise ValueError("Global SDK build settings require explicit recipe support")
