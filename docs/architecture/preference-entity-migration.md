# Preference entities (application schema 23)

The public `preferencesSet` command and `Store.preference` compatibility API keep
scalar settings in `preferences`. Entity keys use relational storage internally;
callers do not need a new command. `updateNoticeEnabled`, `workspaceEpoch`, privacy
maintenance markers and all unrelated settings retain their existing scalar path.
Distribution credentials are outside this migration and its reviewed source scope.

| Existing key | Storage | Owner/deletion |
| --- | --- | --- |
| `answerScope.v1.<answer>` | `answer_metadata.scope_identity` | Answer foreign key, cascade |
| `webAnswer.v1.<answer>` | `answer_metadata.web_answer` | Answer foreign key, cascade |
| `answerScope.<conversation>` | `conversation_scopes` | Meeting foreign key for `meeting:<id>`; otherwise workspace conversation key |
| `proactiveScope.<meeting>` | `proactive_scopes` | Meeting foreign key, cascade |
| `answerSources.<conversation>` | `source_selections` + `source_selection_items` | Meeting foreign key for `meeting:<id>`; otherwise workspace conversation key |
| `answerSourcesSelection.<meeting>` | Same ordered relation, `picker` purpose | Meeting foreign key, cascade |
| `preparationSources.<meeting>` | Same ordered relation, `preparation` purpose | Meeting foreign key, cascade |

Selection rows have explicit positions and preserve ordering, duplicates and the
meaning of an empty selection. Each item references a source; hard source deletion
removes that item. Answer history, private-scope matching and web checkpoints read
answer metadata directly. Answer save and its metadata stay in the existing
savepoint. Compatibility writes preserve the key/value command: malformed payloads or
missing owners/sources replace the prior typed value atomically in bounded
quarantine. Existing readers retain their original private-scope and fail-closed
validation; invalid input never becomes an unrestricted workspace default.
Storage failures still roll back the previous value.

The ordered migration moves valid values and removes their old preference rows.
Malformed keys/values and orphaned owners from migration or compatible writes
are preserved in
`legacy_preference_entities` with a reason and migration timestamp. The adapter
retains their previous read value for at most seven days. Live answer/meeting
parents remain foreign keys even when a value is malformed, so parent deletion
also deletes quarantined content. A new answer or meeting purges matching ownerless
orphans before a reused integer ID can inherit or later re-expose an old value.
Ownerless orphans otherwise expire in bounded batches via
existing Store retention maintenance; reads exclude expired rows immediately.
Deleting quarantined content or answer metadata sets the existing durable backup
erasure marker. Workspace clear includes every new table. Database snapshots
include these tables automatically; backup erasure and pending privacy work retain
the existing retry policy. A legacy restore is migrated again through schema 23.

Versions 1–22 and their original helper/fixture hashes stay frozen. Version 23 owns
its migration parser and mover independently of the runtime compatibility parser;
the migration guard explicitly inventories its complete helper closure.

The previously reported answer retrieval cycle is already broken:
`answer_retrieval.dart` exports the leaf reader/ranking APIs, and
`conversation_queries.dart` imports `answer_passage_queries.dart` directly. This
unit adds no cycle repair.

The source inventory was confined to Store/persistence, the public
`preferencesSet` descriptor and the two meeting UI files `ai_views.dart` and
`read_model.dart`. It does not claim an application-wide preference inventory or
inspect credential or SearchService value-supply implementation.
