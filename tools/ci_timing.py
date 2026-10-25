"""Report inclusive CI phase timings without changing results or cache policy."""

from collections.abc import Iterator
from contextlib import contextmanager
import json
import sys
import time


@contextmanager
def phase(label: str) -> Iterator[None]:
    started = time.monotonic()
    status = "error"
    try:
        yield
        status = "ok"
    finally:
        print(
            "CI phase: "
            + json.dumps(
                {
                    "phase": label,
                    "seconds": round(time.monotonic() - started, 3),
                    "status": status,
                },
                sort_keys=True,
            ),
            file=sys.stderr,
            flush=True,
        )
