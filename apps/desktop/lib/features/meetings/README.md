# Meetings ownership

`MeetingsController` owns feature state, read subscriptions, note drafts and
selection. It receives host, navigation, operation, dialog, integration,
settings and chat ports at composition. Service requests use the typed operation
contracts; renderers receive no connection or command capability.

| Independent library | Presentation inputs |
| --- | --- |
| `recording_view.dart` | Recording snapshot and capture/setup actions |
| `collection_view.dart` | Collection entries, timeline/preview values and selection actions |
| `workspace_view.dart` | Meeting header/workspace values, UI slots and actions |
| `transcript_view.dart` | Transcript rows, provisional text, import/copy/question actions |
| `summary_view.dart` | Artifact versions, workflow snapshot and generation/edit actions |
| `notes_widgets.dart` | Loading/editor/toolbar/body values, owned editor handle and formatting actions |
| `enhanced_notes_view.dart` | Enhanced text/status flags, body slot and copy/edit/hide/cancel actions |
| `assistant_widgets.dart` | Panel selection, composed child panels, question snapshots and answer actions |
| `ai_panels.dart` | Answer scope, workflow/task/artifact snapshots and generation/edit actions |
| `ai_dialogs.dart` | Owned task editor handles or immutable source choices/selection and dialog actions |

Collections are copied into immutable snapshots at renderer construction. The
renderers import only UI helpers and the public read-projection/presentation
types they use. They do not import controller parts, read models, server
implementations or client operation helpers. UI handles remain owned by the
controller: task editor controllers are disposed in its existing `finally`, and
the source dialog's selection set and rebuilding callback stay in its owner.

The remaining `notes_view.dart`, `assistant_views.dart` and `ai_views.dart` parts
compose these independent widgets. They select read snapshots and disabled
states and wire owner callbacks. Note preference changes, save scheduling,
formatting edits, copy/edit requests, answer dispatch, retries, generation
cancellation and all workspace/selection/current checks stay there or in
`meeting_composition.dart`. Async dialogs preserve their before/after-await
checks, input trimming, selected-document limits and controller disposal.
These parts intentionally count toward the controller's recursive logical
library budget; extracting them into parts does not reduce that budget.

The renderer closure guard explicitly lists each independent library, follows
local imports/exports/parts and conditional branches, and rejects owner and
business-capability shortcuts. Negative controls exercise transitive exports,
conditional imports, `part of` and typed command calls. The separate desktop
closure and AST command guards continue to cover server authority and typed
client usage throughout the application.
