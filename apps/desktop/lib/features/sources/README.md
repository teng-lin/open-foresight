# Sources ownership

The application constructs `SourcesController` with host, navigation, operation,
dialog and Integrations ports. The feature owns source browsing, import actions,
source dialogs, graph state and the note editor. `SourceCommands` exposes source
opening and imports to other features without exposing a writer or controller.

| Library | Owner and purpose |
| --- | --- |
| `sources_controller.dart` | Feature state, lifecycle, public commands and rebuild bridge |
| `read_model.dart` | Eight stable typed watches, search ownership and value equality |
| `source_collection.dart`, `source_tiles.dart` | Prepared collection, filters, list and grid presentation |
| `source_actions.dart` | Import, discovery and guarded source dialogs |
| `source_labels.dart` | Label and graph persistence commands |
| `note_widgets.dart` | Independent loading/status/editor/review presentation and callbacks |
| `graph_layout_owner.dart` | Asynchronous graph snapshot and embedding work |
| `graph_interaction.dart` | Camera, pointer and selection actions |
| `graph_widgets.dart`, `source_painters.dart` | Pure graph projection and painting |
| `typed_graph.dart` | Typed scene helpers, graph queries and serialization at command boundaries |
| `source_type_view.dart` | Pure source-type presentation shared with the collection |
| `file_discovery_sheet.dart`, `graph_label_controls.dart` | Feature-owned interactive widgets |

The feature-local parts share only this controller's state. They do not obtain
other feature controllers. Shared presentation, `DesktopEnvironment`, request
identity and shell ports remain external dependencies.

`SourcesReadModel` owns sources, notes, MIME, label, cluster, cluster-name,
graph-label-set and embedding-registration watches. A normalized search query
owns one additional watch. Ordinary durable changes refresh these subscriptions
through the reader; status events and widget rebuilds retain them. Equal values
preserve snapshot identity, including maps with different insertion order.
Errors are visible and successful replies clear their own errors. Owner changes
clear snapshots, retire old replies and rebind; disposal cancels subscriptions.
Same-owner preview values can display, while embedding readiness requires a
current registration. Source, note-body and graph actions require current typed
reads and check connection, session, epoch and their operation's identity.

Layout preparation runs on feature updates or coalesced service revisions.
Builders do not admit persistence queries or graph work. Animation frames reuse
the prepared scene and perform projection only. Failed layout retries require a
new input or external service revision rather than an error/rebuild loop. Held
worker operations retain their settlement and cancellation ownership.

A held note read preserves text typed after loading began. New selection,
workspace reset, session replacement and disposal prevent stale reads or saves
from publishing into another editor. The global operation gate still owns saves
and imports; opening a local source dialog remains nongated so its Edit action
can run. Asynchronous source-opening failures report only to their live owner.

Independent collection, note, tile and graph renderers receive immutable view
values, UI handles and callbacks. `source_type_view.dart` keeps collection
presentation outside the graph-query helper's import closure. The controller
retains the draft/save/read lifecycle and guarded source-opening actions.

Residual parts are orchestration: `source_actions.dart` handles import/discovery
and async source dialogs; `source_labels.dart` handles label dialogs and typed
persistence operations; `graph_layout_owner.dart` owns layout reads/worker work;
`graph_interaction.dart` owns pointer/camera/selection actions. None returns a
widget. `source_composition.dart` connects snapshots and owner callbacks to
independent renderers and owns graph animation bookkeeping. All these parts
remain included in the recursive controller size/decision budget.
