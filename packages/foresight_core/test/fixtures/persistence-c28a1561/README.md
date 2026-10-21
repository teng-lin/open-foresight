# Frozen persistence fixtures

The source revision is `c28a1561b5091645718462169bc6c0cfd0040943`.
`source-manifest.json` binds every fixture to its SHA-256. Tests read these
committed files directly and do not inspect local HEAD or Git history.

`store.dart.txt` and `graph_labels.dart.txt` preserve the reviewed source before
historical migrations and their label/parser dependencies move. They are inputs
for characterization and migration-guard bootstrap tests. A PR's own fixture
manifest never substitutes for independently supplied reviewed-main source in
the real guard.

`schema15.sql` is the empty schema produced by that source's migration ladder.
It excludes SQLite internal objects, application data, randomly generated
workspace identity and timestamps. `schema8.sql` reconstructs the version-8
schema from that ladder: it removes the later pending-delete, request-key,
Summary checkpoint, task and document-cache tables and the later
`locally_edited`, artifact `created` and artifact `manifest` columns. These are
schema fixtures, not claimed byte copies of released user profiles.

The historical v9 tests deliberately retain its valid-JSON conflict policy and
duplicate JSON order. A new authoritative-label migration may normalize the
current projection; that does not permit changing the frozen v9 implementation
or its characterization assertions.

Do not regenerate these fixtures from an implementation branch to accommodate
a failed migration test. Add an explicitly scoped fixture and checksum when a
new historical case is needed.
