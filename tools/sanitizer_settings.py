#!/usr/bin/env python3
"""Emit the shared ASan/LSan/UBSan settings used by the native gate and probes.

This is deliberately separate from sanitizer_runtime.py, which is an input to
the instrumented SDK cache key. Changing gate settings must not change SDK
identity.
"""

import argparse
from pathlib import Path
import re

SUPPRESSIONS = Path(__file__).resolve().with_name("lsan-cpython.supp")
# Exact CPython initialization, constant-unmarshalling and parser frames seen
# in the clean host's retained allocations. These are not the generic eval,
# call/import, finalization, allocator or libffi frames above application calls.
# Extend this set only with captured clean-host stacks and review; the real
# application-leak control must still fail through the same Python host.
CPYTHON_RETAINED_FRAMES = frozenset(
    {
        "_PyRuntime_Initialize",
        "Py_InitializeFromConfig",
        "r_object",
        "_PyPegen_name_token",
        "itertoolsmodule_exec",
        "collections_exec",
        "_ctypes_add_objects",
    }
)
# LSan otherwise treats a pattern as a substring of any function, file or
# module name. Anchors restrict a rule to one exact symbol.
RULE = re.compile(r"leak:\^([A-Za-z_][A-Za-z0-9_]*)\$")


def suppression_policy_errors(text):
    errors = []
    justified = False
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped:
            justified = False
            continue
        if stripped.startswith("#"):
            justified = justified or stripped[1:].strip().lower().startswith("reason:")
            continue
        match = RULE.fullmatch(stripped)
        if not match:
            errors.append(
                f"line {number}: only exact anchored leak:^symbol$ rules are allowed"
            )
        elif match.group(1) not in CPYTHON_RETAINED_FRAMES:
            errors.append(
                f"line {number}: {match.group(1)} is not an allowlisted CPython retained-allocation frame"
            )
        if not justified:
            errors.append(
                f"line {number}: rule lacks its own preceding '# reason:' comment"
            )
        justified = False
    return errors


def sanitizer_options(log_directory=None, suppressions=SUPPRESSIONS):
    suppressions = Path(suppressions)
    errors = suppression_policy_errors(suppressions.read_text())
    if errors:
        raise ValueError(f"{suppressions}: " + "; ".join(errors))
    for path in filter(None, (log_directory, suppressions)):
        if ":" in str(path) or "\n" in str(path):
            raise ValueError(
                f"Sanitizer option paths cannot contain ':' or newlines: {path}"
            )
    # Recursive frozen-module unmarshalling can put the interpreter startup
    # owner beyond ASan's default 30-frame allocation trace. Keep enough trace
    # to match its exact startup symbol instead of suppressing allocators.
    asan = "detect_leaks=1:halt_on_error=1:abort_on_error=1:malloc_context_size=128"
    ubsan = "halt_on_error=1:print_stacktrace=1"
    if log_directory is not None:
        asan += f":log_path={Path(log_directory) / 'asan'}"
        ubsan += f":log_path={Path(log_directory) / 'ubsan'}"
    return {
        "ASAN_OPTIONS": asan,
        # A matched suppression would otherwise print to log_path and create
        # an evidence file even when no unsuppressed leak exists.
        "LSAN_OPTIONS": f"suppressions={suppressions}:print_suppressions=0",
        "UBSAN_OPTIONS": ubsan,
        # pymalloc arenas are mmap regions LSan does not scan, so malloc blocks
        # owned by live Python objects would look unreachable. Plain malloc
        # keeps the interpreter heap graph visible and suppressions minimal.
        "PYTHONMALLOC": "malloc",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-directory", type=Path)
    parser.add_argument("--suppressions", type=Path, default=SUPPRESSIONS)
    args = parser.parse_args()
    for name, value in sanitizer_options(args.log_directory, args.suppressions).items():
        print(f"{name}={value}")


if __name__ == "__main__":
    main()
