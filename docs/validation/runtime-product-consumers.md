# Runtime support product consumers

`tools/diagnostic_product_receipt.py --root SOURCE --build NATIVE_BINARY_DIR`
records the three finished native products after the actual CMake dependencies
complete. `--verify` recomputes the same closed native identity and compares
current bytes with the retained receipt. The build directory contains
`runtime-support-build.json` alongside diagnostic availability, native inputs
and public toolchain metadata. The receipt binds the exact SHA256, size and mode
of SQL support, diagnostic support and the launcher; it also binds the SQL C,
header, CMake/generator source hashes, the independent SQL source ID and both
SQL/diagnostic metadata bytes. Each product must contain exactly one expected
private identity marker: SQL's source ID or the diagnostic NativeID.

This receipt is a byte binding, not independent proof that a compiler ran.
Its producer must depend on the actual product targets. Calling it manually over
old files is not a fresh build. Existing CI source/artifact receipt verification
and owner review remain required. Native identity stays independent of SQL.
The tool never loads these libraries or runs the launcher.
The actual `foresight_runtime_support_products` target depends on SQL support
and the two diagnostic links before running the receipt producer. Configure and
failed diagnostic builds advertise unavailable state; a successful shared SQL
toolchain check preserves its source record instead of overwriting it.

SQL support has a separate `diagnostic-sql-inputs.json` source/recipe record.
`tools/sql_support_identity.py` binds its explicit C/header/CMake/generator
closure, ordered public compile flags and selected public compiler/OS metadata.
It never incorporates NativeID. Its private NUL-delimited
`FORESIGHT_SQL_SUPPORT_SOURCE_ID:v1:<digest>:end` byte marker adds no exported ABI.
The qualified CMake producer compiles SQL in a dedicated sub-build with a
closed public cache vector and an environment containing only fixed PATH/locale
and a private temporary directory. Application directory, target, source, rule
and imported Threads properties cannot reach that compiler. The source record
also binds this isolated producer and its environment/generator recipe.
Unrecognized public flags or unavailable metadata leave the ordinary mandatory
SQL target unmarked and its record unavailable. A separate build prerequisite
rechecks selected toolchain metadata; the qualified producer uses CMake 3.24's
`--fresh` to compile the small component again without inheriting a cache.
Existing CMake pins meet that requirement; older CMake still builds unmarked SQL.
Direct C mechanism proofs remain unmarked. The marker binds declared inputs to
bytes; it does not independently witness compiler execution, SDK bytes or a
production WorkerID.

Unavailable diagnostics, a nonproduction native record, changed source inputs,
missing products, unsafe artifact modes and mismatched bytes refuse verification.
The tool does not accept, create or review any WorkerID. The currently pending
production worker closure must still refuse, including when all native products
have a valid byte receipt. Synthetic test bytes qualify receipt mechanics only.

Dart, compiled service and core-coverage gates verify the finished three-product
receipt before consuming native bytes. They export the selected SQL test image
and distinct production/test helper paths. The native-runtime payload retains
both the SQL source record and finished byte receipt. These identity-qualified
product gates refuse unavailable diagnostics or an unclosed recipe; the
mandatory SQL mechanism itself remains independently usable with diagnostics
disabled. Package consumer wiring and the production WorkerID contract remain
under implementation. Existing artifact producer selection,
publishing permissions and legacy trust selectors are unchanged. A complete
combined product matrix and package/artifact-trust owner review are still needed.
