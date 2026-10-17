# Desktop UI audit — October 17, 2026

Worktree: `open-foresight-desktop-ui-audit`, branch `fix/desktop-ui-audit`.
Base: main at `6832400`. Ask toggle PR #26 and Meetings PR #27 were still open
when this pass started; their implementations are not duplicated here.

## Method and scope

Navigated the installed original `/Applications/Foresight.app`, build
`1.0.0.28.20261005`, through Computer Use. The reference window was 2400×1450
physical pixels at 2× density. Inspected Settings, the inactivity menu, Ask,
Sources file list/import menu, Stats, meeting export, the helper monitor, and
the URL input dialog. Reference images were viewed inline, not retained as
repository artifacts. Font sizes and dimensions below are visual estimates,
not constants recovered by decompilation.

The original was navigated read-only: selector menus were dismissed without
choosing a setting, the URL prompt was cancelled, and no meeting was edited,
question submitted, import saved, model downloaded, or recording started.
Open Foresight renders use disposable profiles, synthetic content, the actual
Google Sans/Material fonts, and a mocked native login-status response.

## Findings and disposition

| Area/state | Finding | Disposition |
| --- | --- | --- |
| Shell and standard controls | Original standard button text is about 14pt; the port's shared label role was 12pt. | Use 14pt consistently. Keep independent branding and truthful local output statistics. |
| Meetings list/preview/detail | Prior live comparison identified title, notes, corners, row gaps, clipped tabs and hints. | Covered by PR #27; do not repeat its changes. Shared controls remain compatible with its Meetings scope. |
| Ask, empty | Original empty message, white panel and full-page prompt wording already agree. Input text was 14pt versus the reference's approximately 16pt. | Use the shared 16pt field role. Single-toggle parity remains in PR #26. |
| Ask, populated/generated text | Port headings, paragraphs, bullets and emphasis render in synthetic fixtures. An original populated answer was not generated during this read-only pass. | Preserve existing question/answer hierarchy and adjustable answer size. Exact rich-renderer equivalence is unverified, not a confirmed defect. |
| Sources, file list | 14pt row text already agrees. Port rows were about 56pt rather than the original's 44pt; panel corners were 12 rather than about 16. | Remove excess outer row padding, preserve 40pt action targets, use a shared 16pt panel corner and compact header spacing. Rows can still grow for errors or larger content. |
| Sources, search and chips | Search field and Add source/Add label/type-count text were smaller than the reference. | Shared 16pt search role and 14pt control/chip text. Search/filter behavior is unchanged. |
| Sources, import menu | Ordering already agrees. Port menu rows inherited oversized ListTile padding, opened over the trigger, and used generic Mac finder wording. | Shared 48pt menu rows below the trigger; search glyph and platform-specific “Find files on this Mac” label. Preserve the portable wording elsewhere and all import actions. |
| Sources, grid/filter states | Existing list/grid, filter, sorting, selection and persistence coverage is available. | Recheck port behavior in regression tests; original grid geometry was not independently established. |
| Graph | Original graph showed a loading spinner on both visits. Its inspector was not available before the native window became unavailable. | No speculative inspector or graph-physics restyling. Existing graph tests and [retained behavior evidence](reference-exact-ui-behavior.md) remain the basis; live inspector appearance remains open. |
| Stats | Original counts are grouped and cards have about 16pt corners. The port could spill large ungrouped counts. Canvas labels omitted the app font/text scale and crowded narrow layouts. | Group and fit counts; shared panel corners; chart font/direction/scale from the current theme, compact ticks, short week labels when needed, and accessible weekly-value nodes. Do not reproduce the reference's visibly truncated chart labels. |
| Settings, general/inactivity | Original selector is a filled rounded field with an unfold glyph and “15 minutes (Default)” in the field/menu. The port used a plain underlined dropdown. | Shared filled selector preserving Flutter focus, keyboard, selection and disabled behavior. Keep the port's existing Never option. |
| Settings, hierarchy/extensions | Original section headings are about 18pt bold. Device/refresh selectors used unrelated styling. | Shared section role; reuse filled selectors for the port's device and refresh controls. Preserve additional capabilities and permission explanations. |
| URL dialog | Original has a pale surface, 24pt title, filled underlined 16pt field, immediate field focus, and Cancel/OK text actions. Port used the 28pt page-heading role and an outlined field. | Shared dialog title/body/surface roles and matching URL prompt. Cancellation leaves sources untouched. |
| Helper dialog | Original custom monitor has tighter, roughly 16pt corners, 24pt title and 14pt body. | Match visual roles and corners. Keep Open Foresight's own service diagnostics/actions rather than inventing original helper lifecycle APIs. |
| Export | Original export page and empty/date-filter state were observed. Selectable Markdown preview/save behavior already has retained evidence and tests. | Preserve existing behavior. Controlled nonempty original export appearance is not newly established here. |
| Native/model/account states | No new permission, account connection, destructive confirmation, or model-selection operation was performed in the original. | Existing fixture tests continue to cover these flows; platform dialog appearance and live account/model outcomes are outside this visual pass. |

This is a comprehensive screen/state inventory within those read-only boundaries,
not a claim of exhaustive pixel parity. Unknowns are left explicit instead of
being turned into guessed visual changes.

## Reproduction and checks

From `apps/desktop`:

```sh
FORESIGHT_DESKTOP_AUDIT=/tmp/foresight-desktop-ui-audit \
  flutter test test/desktop_parity_audit_test.dart
flutter test
flutter analyze
```

The audit fixture renders empty/populated Ask, Sources, the import menu, URL
dialog, Stats and Settings at 1200×800, plus 800×800 with 1.4× text scaling.
It checks preference persistence, keyboard opening/dismissal, unavailable
selectors, row density, cancelled imports, grouped large counts, chart semantics
and layout exceptions. Screenshot-only fonts/shadows/semantics are restored at
test exit. No new golden baselines or user-data captures are committed.

Validation completed on this branch: the full desktop suite passed 110 tests
with 10 existing opt-in skips; static analysis and `git diff --check` passed.
The enhancement-cancellation test scrolls its control into view before tapping,
so the larger control typography is exercised at the default test viewport.
The same test correction is included in PR #27's CI repair.

Integration review: this branch merges cleanly with the Ask toggle branch
(PR #26) and Meetings branch including its CI correction (PR #27). All 17
affected widget tests passed on the combined checkout, and analysis was clean.
