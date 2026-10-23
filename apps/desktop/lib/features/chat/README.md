# Chat ownership

| Library | Responsibility |
| --- | --- |
| `ports.dart` | Read-only activity and explicit font, question, answer and citation commands |
| `chat_controller.dart` | Conversation drafts, producer lifetime, actions and shell rebuild bridge |
| `read_model.dart` | Typed scope/history queries and immutable prepared answers/citations |
| `widgets.dart` | Conversation attachment, history, controls and composer |

`GeneratedContent`, presentation roles/colors and request identity remain shared.
Chat receives separate host, navigation, operation, meeting-fact and source-command
ports; it cannot access private controllers in the application library. Sources
opens a revision-checked citation document through its own typed query. Local citation dialogs retain an available source edit action; opening one does
not hold the operation gate for its lifetime. Chat keeps
its own request identity before showing an archived citation after an async reply.

Each mounted or answering conversation owns a stable scope watch and a history
watch keyed by the scope identity. Ordinary revisions retain scheduling entries;
a scope change replaces history and rejects the old scope's results. A pending
scope verification hides scoped output while leaving a valid producer alive.
Incoming text waits for actual scope verification after a data revision, so a
held scope read cannot allow late text through. An unchanged scope resumes the
same producer. Client-session/workspace replacement retires subscriptions,
waiters and results even when SQLite and endpoint identity remain unchanged.
Temporary action validation subscriptions are also owned and cancelled.

Typed results become immutable view values before notification. Citation JSON
is decoded when accepting history, outside widget building. Value-equal answers
and citations do not notify. Status-only events admit no new queries. Conversation
attachment schedules queries after widget building; builders read prepared state.

The feature owns and disposes draft controllers and query subscriptions. The
application uses its unsaved-draft fact, reset command and dispose method. Accepted
stream replies clear only the submitted draft, preserving replacement text. The
workspace-wide operation gate, cancellation, manual/web selection, answer font
limits and scope-bound history behavior remain in place.
