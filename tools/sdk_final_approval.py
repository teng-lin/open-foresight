"""Qualify original SDK bytes under a source-equivalent merged final PR head.

Approval is separate from semantic build identity and original payload receipts.
Historical source is data only: the consumer supplies the trusted fingerprint
and immutable Git-object reader; no producer Python or workflow is executed.
"""

import re

from tools.ci_producer_trust import PRODUCERS

SHA = re.compile(r"[a-f0-9]{40}")
WORKFLOW = PRODUCERS["dependency-sdk"].workflows[0]
MAX_COMMIT_PAGES = 3  # GitHub's PR commits endpoint returns at most 250 commits.


def approved_final_heads(
    repository, run, *, workflow, api, merged_source, merged_equivalent=None
):
    """Yield related merged final heads with authoritative source approval.

    PR history is bounded to three 100-entry pages: GitHub exposes at most 250
    commits. Consumers keep their own build/control equivalence and error rules.
    This qualifies source only, never jobs, receipts, attempts or payload bytes.
    """
    producer = run.get("head_sha")
    if (
        run.get("path") != workflow
        or run.get("event") != "pull_request"
        or (run.get("head_repository") or {}).get("full_name") != repository
        or not isinstance(producer, str)
        or not SHA.fullmatch(producer)
    ):
        return
    references = run.get("pull_requests") or api(
        repository, f"commits/{producer}/pulls"
    )
    for reference in references:
        number = reference.get("number")
        if type(number) is not int or number <= 0:
            continue
        pull = api(repository, f"pulls/{number}")
        final = pull.get("head", {}).get("sha")
        if (
            not pull.get("merged_at")
            or pull.get("base", {}).get("repo", {}).get("full_name") != repository
            or pull.get("head", {}).get("repo", {}).get("full_name") != repository
            or not isinstance(final, str)
            or not SHA.fullmatch(final)
        ):
            continue
        related = producer == final
        if not related:
            related = api(repository, f"compare/{producer}...{final}")["status"] in (
                "ahead",
                "identical",
            )
        if not related:
            for page in range(1, MAX_COMMIT_PAGES + 1):
                commits = api(
                    repository, f"pulls/{number}/commits?per_page=100&page={page}"
                )
                if any(commit.get("sha") == producer for commit in commits):
                    related = True
                    break
                if len(commits) < 100:
                    break
        if not related:
            continue
        approved = {**run, "head_sha": final, "pull_requests": [{"number": number}]}
        if not merged_source(repository, approved):
            # A squash merge can include unrelated changes already on its base.
            # SDK callers may prove their complete input/control closure equal
            # to the authoritative merged tree. Other callers retain the whole
            # tree boundary, including stage-result and instrumented outputs.
            merge = pull.get("merge_commit_sha")
            if (
                merged_equivalent is None
                or not isinstance(merge, str)
                or not SHA.fullmatch(merge)
                or api(repository, f"compare/{merge}...main")["status"]
                not in ("ahead", "identical")
                or not merged_equivalent(repository, final, merge)
            ):
                continue
        yield final


def approved_final_source(
    repository,
    run,
    component,
    *,
    api,
    merged_source,
    fingerprint_at,
    read_source,
    controls,
):
    if component.endswith("-app"):
        return False
    producer = run.get("head_sha")
    errors = []

    def merged_equivalent(repo, final, merge):
        return fingerprint_at(repo, final, component) == fingerprint_at(
            repo, merge, component
        ) and read_source(repo, final, paths=controls) == read_source(
            repo, merge, paths=controls
        )

    for final in approved_final_heads(
        repository,
        run,
        workflow=WORKFLOW,
        api=api,
        merged_source=merged_source,
        merged_equivalent=merged_equivalent,
    ):
        if fingerprint_at(repository, producer, component) != fingerprint_at(
            repository, final, component
        ):
            errors.append(
                ValueError(
                    "SDK build inputs differ between original producer and approved final source; "
                    "preserve its artifact and review compatibility before any rebuild."
                )
            )
            continue
        original_controls = read_source(repository, producer, paths=controls)
        final_controls = read_source(repository, final, paths=controls)
        if original_controls != final_controls:
            errors.append(
                ValueError(
                    "SDK producer controls changed before final approval; preserve the original "
                    "artifact and obtain reviewed control compatibility, not a cold rebuild."
                )
            )
            continue
        return True
    if errors:
        raise errors[-1]
    return False
