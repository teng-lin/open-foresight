# Meetings visual consistency

Compared the installed `/Applications/Foresight.app` live through Computer Use
on October 17, 2026: Meetings list, selected meeting preview, and expanded
meeting. The original was only navigated and scrolled; meeting data was not
edited. Original screenshots were viewed in the tool response, not saved in
this repository. Reverse engineering was unnecessary for these visible roles.

The 2400 × 1450 reference images use 2x display density. The following logical
sizes are visual estimates, not recovered source constants:

| Role | Size | Treatment |
| --- | --- | --- |
| Page heading | 28 | Existing app heading retained |
| Preview and expanded meeting title | 20 | Bold |
| List title / date group | 16 | Regular / bold |
| Notes and generated paragraphs | 15 | Regular, 1.6 line height |
| Panel heading / toolbar / tabs | 14 | Bold / medium |
| Date and time metadata | 12 | Muted |

`meeting_visuals.dart` centralizes these meeting roles, outlined date/time
badges, 16px preview/card corners and 24px full workspace panel corners.
Consecutive original list cards had 16 logical pixels between them; the
existing outer 16px row padding now supplies this without additional Card
theme margins. Control defaults are scoped to Meetings, including immersive
view. Assistant answer sizing remains user adjustable.

The rendered comparison also exposed layout defects: equal-width assistant
tab allocations truncated Live Q&A and Summary, and a long empty-editor hint
could paint above its short preview viewport. Tabs now wrap at their natural
widths. Empty-editor guidance has a clipped viewport with the same notes
typography. Enhanced-pane heading actions move to a second row when narrow
or when accessibility text scaling needs room.

Reproduce the disposable-profile widget renders from `apps/desktop`:

```sh
FORESIGHT_MEETING_VISUALS=/tmp/foresight-meetings-ui-consistency \
  flutter test test/meeting_visual_consistency_test.dart
```

The fixture loads the actual Google Sans and Material icon fonts and emits
list, empty/populated preview, populated full detail, 700px narrow detail and
preview, and 1.4x text-scale preview images. The populated detail includes
paragraphs, a generated heading and bullets. These were visually inspected;
they are representative checks rather than exhaustive pixel-parity claims.
Tests check consistent title/editor roles, full tab labels, empty guidance
placement, actual generated Summary font sizing after a user-size change,
and text scaling. Existing collection/workspace tests cover saving, selection,
formatting and adaptive navigation. No real account or model was required.

Validation: 10 tests across visual consistency, collection, workspace,
meeting-note state and generated-content suites passed; desktop static
analysis and `git diff --check` passed.
