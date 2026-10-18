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

DISPLAY_NAMES = {
    "macos": "Build macOS ${{ matrix.component }}",
    "macos-vendor": "Build macOS vendor",
    "macos-runtime": "Build macOS ${{ matrix.component }}",
    "core": "Build Linux core",
    "linux-pr-core": "Build Linux core",
    "litert": "Build Linux litert",
    "whisper": "Build Linux whisper",
    "sdk": "Assemble Linux SDK",
    "linux-pr": "Assemble Linux SDK",
    "linux-pr-runtime": "Build Linux ${{ matrix.component }}",
}
MATRICES = {
    "macos": {"sdk"},
    "macos-runtime": {"runtime"},
    "linux-pr-runtime": {"litert", "whisper"},
}


def transport_body(lines):
    """Ignore only YAML display/budget/retention fields, never shell content."""
    result = []
    scalar = False
    parent = None
    for line in lines:
        # Shell block contents are opaque, including text resembling YAML keys.
        if scalar and (not line.strip() or line.startswith("        ")):
            result.append(line)
            continue
        scalar = False
        if re.match(r"      run: [|>]", line):
            scalar = True
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"    - name:|      (name|timeout-minutes):", line):
            continue
        if re.match(r"      [A-Za-z-]+:", line):
            parent = line.strip().split(":", 1)[0]
        if parent == "with" and re.match(
            r"        (retention-days|compression-level):", line
        ):
            continue
        result.append(line)
    return "".join(result)


def validate(lines, coverage):
    contract = set(
        json.loads(Path(__file__).with_name("sdk_transport_contract.json").read_text())
    )
    """Every build-capable step and ambient build setting needs a recipe region."""
    jobs_start = [i for i, line in enumerate(lines) if line == "jobs:\n"]
    if len(jobs_start) != 1:
        raise ValueError("Unsupported SDK workflow job layout")
    starts = []
    for i in range(jobs_start[0] + 1, len(lines)):
        line = lines[i]
        if (
            line.startswith("  ")
            and not line.startswith("   ")
            and line.strip()
            and not line.lstrip().startswith("#")
        ):
            match = re.fullmatch(r"  ([a-z][a-z-]*):\s*", line)
            if not match:
                raise ValueError("Unsupported SDK workflow job layout")
            starts.append((i, match[1]))
    if {job for _, job in starts} != set(JOBS) | {"plan", "snapshot-update"}:
        raise ValueError("Unaccounted SDK workflow producer jobs")
    found = set()
    for position, (start, job) in enumerate(starts):
        stop = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        names = [
            line.removeprefix("    name: ").strip()
            for line in lines[start:stop]
            if line.startswith("    name:")
        ]
        if job not in JOBS:
            if names and names != [job]:
                raise ValueError("Auxiliary SDK job cannot alias a producer name")
            continue
        if names != [DISPLAY_NAMES[job]]:
            raise ValueError("Unsupported SDK producer display name")
        found.add(job)
        owners = JOBS[job]
        strategies = [i for i in range(start, stop) if lines[i] == "    strategy:\n"]
        if job in MATRICES:
            if len(strategies) != 1:
                raise ValueError("Missing SDK producer matrix")
            matrix_start = strategies[0]
            matrix_stop = next(
                i
                for i in range(matrix_start + 1, stop)
                if re.match(r"    \S", lines[i])
                and not lines[i].lstrip().startswith("#")
            )
            matrix_lines = [
                line.strip()
                for line in lines[matrix_start + 1 : matrix_stop]
                if line.strip() and not line.lstrip().startswith("#")
            ]
            expected = {
                "matrix:",
                "component:",
                *("- " + value for value in MATRICES[job]),
            }
            actual = {
                line for line in matrix_lines if not line.startswith("fail-fast:")
            }
            if actual != expected:
                raise ValueError("Unsupported SDK producer matrix aliases/settings")
        elif strategies:
            raise ValueError("Unexpected SDK producer matrix")
        step_start = next(
            (i for i in range(start, stop) if lines[i].strip() == "steps:"), None
        )
        if step_start is None:
            raise ValueError("Missing SDK build steps: " + job)
        for i in range(start, step_start):
            if re.match(
                r"    (runs-on|env|defaults|container|services|strategy):", lines[i]
            ):
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
