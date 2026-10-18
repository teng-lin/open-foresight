#!/usr/bin/env python3
"""Allocate distribution build numbers with compare-and-swap Git reference updates."""

import argparse
import base64
import json
import subprocess
import time

REF = "heads/ci/build-sequence"


def request(repository, route, method="GET", payload=None, optional=False):
    command = ["gh", "api", "--method", method, f"repos/{repository}/{route}"]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(
        command,
        input=json.dumps(payload) if payload is not None else None,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode:
        if optional and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def allocate(repository, minimum):
    if minimum < 0:
        raise ValueError("Minimum build must be nonnegative")
    for attempt in range(10):
        ref = request(repository, "git/ref/" + REF, optional=True)
        parent = ref["object"]["sha"] if ref else None
        state = (
            request(repository, f"contents/sequence.json?ref={parent}")
            if parent
            else None
        )
        previous = (
            json.loads(base64.b64decode(state["content"]))["build"] if state else 0
        )
        number = max(previous, minimum) + 1
        blob = request(
            repository,
            "git/blobs",
            "POST",
            {"content": json.dumps({"build": number}), "encoding": "utf-8"},
        )
        tree = request(
            repository,
            "git/trees",
            "POST",
            {
                "tree": [
                    {
                        "path": "sequence.json",
                        "mode": "100644",
                        "type": "blob",
                        "sha": blob["sha"],
                    }
                ]
            },
        )
        commit = request(
            repository,
            "git/commits",
            "POST",
            {
                "message": f"Reserve distribution build {number}",
                "tree": tree["sha"],
                "parents": [parent] if parent else [],
            },
        )
        try:
            if parent:
                request(
                    repository,
                    "git/refs/" + REF,
                    "PATCH",
                    {"sha": commit["sha"], "force": False},
                )
            else:
                request(
                    repository,
                    "git/refs",
                    "POST",
                    {"ref": "refs/" + REF, "sha": commit["sha"]},
                )
            return number
        except RuntimeError as error:
            if not any(code in str(error) for code in ("HTTP 409", "HTTP 422")):
                raise
            time.sleep(min(attempt + 1, 5))
    raise RuntimeError("Build sequence changed repeatedly; retry allocation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--minimum", type=int, required=True)
    args = parser.parse_args()
    print(allocate(args.repository, args.minimum))


if __name__ == "__main__":
    main()
