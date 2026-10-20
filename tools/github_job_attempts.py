"""Resolve API carry-forward job copies to their original executed attempts."""

from datetime import datetime
import re

COPY_FIELDS = (
    "name",
    "run_id",
    "head_sha",
    "status",
    "conclusion",
    "started_at",
    "completed_at",
    "steps",
)


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Missing authoritative job/attempt timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("Invalid authoritative job/attempt timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError("Job/attempt timestamp must include its timezone")
    return parsed


def canonical_jobs(jobs, run, request_attempt):
    """Keep genuine latest attempts, replacing only proven historical copies.

    GitHub repeats untouched jobs with new IDs and higher run_attempt values.
    A copy must predate its own authoritative attempt and match exactly one
    lower genuine job, including every step. Receipt/attestation identities
    continue to name that original job and attempt, never the API copy.
    """
    identifiers = [job.get("id") for job in jobs]
    if any(type(value) is not int or value < 1 for value in identifiers) or len(
        set(identifiers)
    ) != len(identifiers):
        raise ValueError("Missing or ambiguous original job IDs")
    metadata = {}

    def attempt_start(number):
        if number not in metadata:
            record = request_attempt(number)
            if (
                record.get("id") != run["id"]
                or type(record.get("run_attempt")) is not int
                or record["run_attempt"] != number
                or record.get("head_sha") != run["head_sha"]
                or not re.fullmatch(r"[a-f0-9]{40}", record.get("head_sha", ""))
            ):
                raise ValueError(
                    "Attempt metadata differs from the original run/source"
                )
            metadata[number] = timestamp(record.get("run_started_at"))
        return metadata[number]

    result, selected = [], set()
    for job in jobs:
        number = job.get("run_attempt")
        if type(number) is not int or number < 1:
            raise ValueError("Missing original job attempt")
        original = job
        if (
            number > 1
            and job.get("status") == "completed"
            and job.get("conclusion") == "success"
        ):
            # Missing timestamps cannot establish a copy. Retain the row so
            # strict latest-job qualification rejects incomplete/skipped work.
            if (
                job.get("started_at") is not None
                and job.get("completed_at") is not None
            ):
                start, end = (
                    timestamp(job["started_at"]),
                    timestamp(job["completed_at"]),
                )
                boundary = attempt_start(number)
                if end < start:
                    raise ValueError("Invalid original job execution window")
                if start < boundary:
                    if (
                        end >= boundary
                        or any(key not in job for key in COPY_FIELDS)
                        or not isinstance(job["steps"], list)
                    ):
                        raise ValueError(
                            "Unproven carried job execution window/identity"
                        )
                    origins = []
                    for lower in jobs:
                        lower_number = lower.get("run_attempt")
                        if (
                            type(lower_number) is int
                            and 0 < lower_number < number
                            and all(
                                key in lower and lower[key] == job[key]
                                for key in COPY_FIELDS
                            )
                            and lower.get("run_id") == run["id"]
                            and lower.get("head_sha") == run["head_sha"]
                            and start >= attempt_start(lower_number)
                        ):
                            origins.append(lower)
                    if len(origins) != 1:
                        raise ValueError(
                            "Carried job has no unique proven original execution"
                        )
                    original = origins[0]
        identity = (original.get("id"), original["run_attempt"])
        if type(identity[0]) is not int or identity[0] < 1:
            raise ValueError("Missing original job ID")
        if identity not in selected:
            result.append(original)
            selected.add(identity)
    return result
