# Runtime support product consumers

`tools/diagnostic_product_receipt.py --root SOURCE --build NATIVE_BINARY_DIR`
records the three finished native products after the actual CMake dependencies
complete. `--verify` recomputes the same closed native identity and compares
current bytes with the retained receipt. The build directory contains
`runtime-support-build.json` alongside diagnostic availability, native inputs
and public toolchain metadata. The receipt binds the exact SHA256, size and mode
of SQL support, diagnostic support and the launcher; it also binds the SQL C,
header and CMake source hashes and diagnostic metadata bytes.

This receipt is a byte binding, not independent proof that a compiler ran.
Its producer must depend on the actual product targets. Calling it manually over
old files is not a fresh build. Existing CI source/artifact receipt verification
and owner review remain required. Native identity stays independent of SQL.
The tool never loads these libraries or runs the launcher.

Unavailable diagnostics, a nonproduction native record, changed source inputs,
missing products, unsafe artifact modes and mismatched bytes refuse verification.
The tool does not accept, create or review any WorkerID. The currently pending
production worker closure must still refuse, including when all native products
have a valid byte receipt. Synthetic test bytes qualify receipt mechanics only.

Package/build/coverage/service consumer wiring and the production WorkerID
contract remain under implementation. Existing artifact producer selection,
publishing permissions and legacy trust selectors are unchanged. A complete
combined product matrix and package/artifact-trust owner review are still needed.
