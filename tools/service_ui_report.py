"""Validate observations emitted by named expectations in the native UI test."""

from collections import Counter

REQUIRED_EXPECTATIONS = frozenset(
    {
        "desktop_and_mcp_same_owner",
        "mcp_changes_visible",
        "recording_survived_mcp_close",
        "recording_stopped_when_desktop_indicator_closed",
        "desktop_restart_preserved_owner",
        "transcript_persisted",
        "artifact_persisted",
        "desktop_database_read_only",
    }
)


def verify_service_ui_report(report):
    if not isinstance(report, dict) or report.get("schema") != 1:
        raise ValueError("Native UI report has no expectation schema")
    observations = report.get("expectations")
    if not isinstance(observations, list) or not observations:
        raise ValueError("Native UI report contains no expectations")
    names: Counter[str] = Counter()
    for observation in observations:
        if (
            not isinstance(observation, dict)
            or set(observation) != {"name", "actual", "expected", "passed"}
            or observation["passed"] is not True
        ):
            raise ValueError("Invalid or failed native UI expectation")
        names[observation["name"]] += 1
    missing = sorted(name for name in REQUIRED_EXPECTATIONS if names[name] != 1)
    if missing:
        raise ValueError(
            "Missing or duplicated native UI expectations: " + ", ".join(missing)
        )
    return report
