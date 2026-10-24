# Python tooling import inventory

This is the Stage E starting inventory at integration commit `b41ea253`.
[The machine-readable inventory](python-tooling-inventory.json) records each
production module, main entrypoint, local import, caller candidate, path mutation
and dynamic loader location. No import migration is claimed by this inventory.

The tracked source contains 370 Python files, including 167 tooling/packaging
production modules and 138 `__main__` entrypoints. AST scanning found 88
`sys.path` mutations and 68 dynamic-loader calls across tracked Python, with no
parse failures. These counts use a broader, explicitly recorded AST definition
than the audit's 84 insertions and 38 dynamic loads: path mutations include
operations other than insertion, and dynamic calls include `import_module`.
They are starting debt measurements, not newly introduced regressions.

Caller candidates combine AST imports (including legacy bare tooling imports)
and literal source paths or module names in tracked shell, workflow, test, CMake,
Dart and documentation text. Historical audit text is excluded from literal
caller candidates. Literal references can be documentation rather than execution;
computed command construction, imported aliases and dynamic targets still need
semantic review before changing their module. Python fixture and native SDK
loaders must receive an explicit keep/convert disposition rather than blindly
replacing them. The artifact intentionally retains paths and line numbers rather
than captured command output or credential contents.

The distribution credential sourcing module
`tools/reference_distribution_config.py`, its dedicated tests and value-supply
path to SearchService remain excluded from import/config/digest/helper rewrites.
Inventory visibility does not authorize changing them.

Implementation order within the same final PR:

1. Classify the complete inventory into shared CI dependency layers, release and
   packaging entrypoints, build/setup entrypoints, installed/exported adapters,
   and fixture/SDK loaders. Review computed callers and dependency cycles before
   assigning each conversion batch. Preserve existing monkeypatch boundaries.
2. Establish the real `tools` package and package imports in the lowest shared
   dependency layer together with all its consumers. Adopt module invocation in
   workflow/shell/docs/tests and retain direct-script adapters where an external
   interface requires them. An initializer by itself does not complete this step.
3. Convert successive dependent batches with Git-free export and unrelated-cwd
   proofs. Release trust behavior and checksum/timeout/output semantics must stay
   covered by the existing integrity matrix and owner review requirements.
4. Introduce only demonstrated shared helpers, actionable smoke diagnostics and
   registry-derived operation counts. Add per-module typing/complexity ratchets
   after the import topology is coherent. A standard-library-only leaf may start
   its own module ratchet earlier because it has no local dependency edges;
   caller typing still waits for normal package imports. Disclose remaining debt.

The inventory does not qualify tooling runtime behavior, complete Stage E, or
close the separate Dart/native quality requirements. Existing acceptance gates
remain required for every implementation batch.


The [conservative dependency graph](python-tooling-dependencies.json) additionally
records literal alternatives within dynamic imports. It finds five possible
strongly connected groups, including release lookup/candidates, CI handoffs,
acceptance planning and main coordination. These are not assumed to execute at
import time. Computed helper calls such as `_module(name)` remain unresolved and
must be reviewed before assigning conversion batches. The first typing ratchet
covers only the shared `tools.ci_timing` leaf, with explicit per-module
strictness flags. The pinned mypy version expands the `strict` shorthand globally
even inside an override, so the override lists its supported per-module flags;
the global-only redundant-cast and unused-config warnings are unchanged. Existing
dynamic import callers remain untyped at this boundary; the new annotation does
not enforce their argument types until package conversion. Broader
CI typing, C901, package conversion and shared helper work remain outstanding.


Before adding a real `tools/__init__.py`, include package initialization in the
producer-control review. The current
[SDK producer control list](../../tools/sdk_producer_trust.py) enumerates tool
modules but has no initializer entry: today `tools` is a namespace package.
Adding an initializer creates a new execution dependency for existing imports.
Its bytes and mode therefore need control-closure coverage, with an explicit
policy for historical producers that had no initializer. Existing SDK reuse must
not silently trust an unchecked initializer or be described as a fresh build.
This prerequisite is part of the import conversion, and any trust-code change
requires the final owner review described by CI integrity.

The `ci_registry` leaf's executable callers are the immutable-image inspection
steps in `ci-dependencies.yml`; the SDK transport contract freezes those workflow
snippets. Other literal matches are historical baseline/selector fixtures or
module imports by tests and `publish_linux_package_aliases.py`. A future primary
module-invocation conversion must update workflow commands and their exact
transport contract together, preserve the direct-script external interface, and
prove Git-free/unrelated-cwd behavior. These caller dispositions are preparation,
not a completed conversion batch.
