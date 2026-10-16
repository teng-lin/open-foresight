# Focused reference snapshot reader

Developer-only investigation tool; the application has no dependency on it.
It deserializes the matching original Dart snapshot without invoking Dart
application code. It prints only an explicit allowlist of pool entries needed
to bind the IDA trace, including entry types before decoding immediate doubles.
No search API-key entry is selected.

Validated target: installed Foresight 1.0.0.28.20261005, arm64 macOS, SHA-256
fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326.

## Reproduce on Apple Silicon

Use a temporary checkout; do not alter the installed original.

1. Fetch greeng3/blutter at
   d3b4615c7b7bd9bc1583f15fc6bc229b6aa8d9bd (Mach-O support).
2. Apply upstream single-snapshot PR 213, commit
   c1caafecd233ea17c3f4b6b5ff8847d59478b979, then apply the adjacent
   macho-single-snapshot.patch to that checkout using git apply --unidiff-zero. This adds the newer Mach-O
   symbol names to its loader.
3. Build the Dart library with the checkout's script:
   python3 dartvm_fetch_build.py 3.14.0-294.0.dev macos arm64 e3b703b387b759dc21a3cbe8aa329f7a.
   Existing CMake, Ninja and ICU are required. On this host ICU was supplied by
   /opt/homebrew/opt/icu4c through CMAKE_PREFIX_PATH and PKG_CONFIG_PATH.
   Limit Ninja parallelism if necessary.
4. Verify the SDK checkout is commit
   ac1a97aae47d12e81d772ad45ab6d1fe57a02cf4. From that SDK root,
   python3 -c "import sys; sys.path.insert(0, 'tools'); import make_version; print(make_version.MakeSnapshotHashString())"
   must independently produce e3b703b387b759dc21a3cbe8aa329f7a, matching the
   artifact. Supplying a hash to the build script alone does not verify this.
5. Copy this directory to pool-reader inside the temporary Blutter checkout.
   Configure with cmake -S pool-reader -B build/pool-reader -GNinja
   -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/icu4c,
   then cmake --build build/pool-reader -j4.
6. Run build/pool-reader/pool_reader
   /Applications/Foresight.app/Contents/MacOS/Foresight.

The pool-offset labels are raw X27-relative byte offsets from IDA. Convert
using ObjectPool::IndexFromOffset(offset - kHeapObjectTag), rather than
treating the decompiler's array index as an ObjectPool element index.
Immediate values must use RawValueAt; calling ObjectAt on them is invalid.

String dispatch targets -4092 and -4090, one-byte/two-byte string hash dispatch
targets, and the Smi expiry comparison are printed as offsets from the mapped
image base for binding to original native symbols.

See [the finding ledger](../../docs/proactive-reference-trace.md) for recovered
values, REA Evidence IDs, and remaining dispatcher integration work.

Upstream sources:
- https://github.com/worawit/blutter/pull/216
- https://github.com/worawit/blutter/pull/213
- https://github.com/dart-lang/sdk/tree/ac1a97aae47d12e81d772ad45ab6d1fe57a02cf4
