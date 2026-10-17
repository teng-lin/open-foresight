# Original source-label editor behavior

The target is the same Foresight `1.0.0.28.20261005` binary identified in
[the export trace](../notes/reference-meeting-export.md). This is IDA Pro static evidence,
not a new live label-editing experiment. Speaker channel labels are separate
from these organization/document labels.

## Inline editor focus

`_DocumentGraphAddLabelButtonState._onFocusChange (_2)` at `0x100aa4684`
checks for lost focus, an active editor, and a mounted state. Its selected
set-state closure at `0x1009a6060` only stores `false` to the editing flag.
It does not submit, clear the controller, or write a document label. The edit
activation closure at `0x1009a6278` sets that flag back to `true`.

The reconstructed graph inspector previously left its editor visible after
focus moved away. `GraphLabelControls` now closes on focus loss and retains the
draft for reopening. Explicit cancellation still clears the draft. The listener
is removed before its focus node is disposed.

The closure addresses come from the exact selected function-pool entries
PP40651 and PP40646. Retained outputs are `source-label-focus.json`,
`source-label-focus-state.json` and `source-label-start-state.json` under
`test-results/reference-functions/ida/`. The final closure analysis was captured
by REA evidence
`ev_54e89aa17acdc9afba2cb5794c25e0d4aa0539d9b256cd688822d31f45743b42`
with the owned IDA dispatcher closed.

The follow-up build callbacks at `0x100a28ba0` and `0x100a28c20` respectively
clear the controller and invoke the parent document-label addition method.
Both then call `setState`; the addition callback does not await the returned
future before that update. These effects agree with the port's current
cancel/submit delegation. Retained outputs are `source-label-submit-actual.json`
(the controller-clear function) and `source-label-cancel-actual.json` (the
addition function). The parent method's internal trim/clear timing remains a
separate binding; no additional label behavior change was made in this pass.

## Colors

`DocumentGraphLayout.getHexForLabel` at `0x100855290` reuses a matching label's
stored nonnull color with case-insensitive name comparison, treats occupied
colors in uppercase, chooses the first unused color from its seven-color
palette, and falls back to `label.hashCode.abs() % 7` when exhausted. The port's
existing case and palette choices agree; the fallback now explicitly applies
`abs()` too. `source-label-color.json` retains the complete function, and
`source-label-string-dispatch.json` binds the uppercase dispatch to
`String.toUpperCase` at `0x100d1f774`. An exact hash-value comparison across the
original and port Dart VM versions has not been performed.

The editor regression checks focus loss, draft retention/reopening, no implicit
label write, explicit cancellation, and disposal. Existing workflow tests cover
document-specific addition/removal, organization propagation/deletion, and
persistent association fields. Controlled live original-app document editing,
deletion and graph restoration remain unverified.

Final focused validation: 23 desktop tests pass across meeting export, label
storage, graph label controls and organization-label workflows with
`TZ=America/New_York`. The analyzer reports no issues in the changed desktop
export implementation and test, and `git diff --check` passes.
