# Diagnostic SHA-256 leaf

`native/diagnostic_sha256.{h,c}` is a portable C11 streaming SHA-256 used to
hash public source files during CHILD source SDK verification. It is a leaf:
it does not change the owner function table or the existing bootstrap path, and
it is not used for secrets, keys or authentication.

## ABI

Three exported symbols, separate from the owner function table:

```c
int fs_diagnostic_sha256_init(fs_diagnostic_sha256_context *context);
int fs_diagnostic_sha256_update(fs_diagnostic_sha256_context *context,
                                const void *data, size_t length);
int fs_diagnostic_sha256_final(fs_diagnostic_sha256_context *context,
                               unsigned char *digest);
```

| Constant | Value |
| --- | --- |
| `FS_DIAGNOSTIC_SHA256_CONTEXT_SIZE` | 128 bytes, byte alignment |
| `FS_DIAGNOSTIC_SHA256_DIGEST_SIZE` | 32 bytes |
| `FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE` | 65536 bytes per update |

`fs_diagnostic_sha256_context` is `struct { unsigned char opaque[128]; }`.
Callers may allocate it anywhere (for Dart FFI, 128 bytes of `Uint8`) and may
move it with `memcpy` between calls. The implementation reads and writes the
context only through byte copies, so caller alignment does not matter.

The implementation performs no allocation, IO, threading, callbacks,
environment access, static construction/teardown or dynamic loading. A single
context must not be used from several threads at once.

## Return codes and ordering

| Code | Value | Meaning |
| --- | --- | --- |
| `OK` | 0 | Success |
| `ERROR_ARGUMENT` | -1 | NULL context, NULL digest, or NULL data with non-zero length |
| `ERROR_STATE` | -2 | Never initialized, zeroed, or corrupt context |
| `ERROR_FINALIZED` | -3 | Context already finalized |
| `ERROR_TOO_LARGE` | -4 | Update longer than 65536 bytes |
| `ERROR_OVERFLOW` | -5 | Total message bit count would exceed `UINT64_MAX` |

`update` checks in this order: NULL context, length limit, NULL data, context
state, total overflow. `final` checks NULL arguments, then context state.
`init` accepts any context bytes, including finalized or garbage contents, and
fails only for NULL.

Every failing call is transactional: neither the context nor the digest
buffer is modified. `update(ctx, NULL, 0)` on a valid active context succeeds
without changes. A successful `final` writes the digest and leaves the context
in a finalized state; further `update`/`final` calls return
`ERROR_FINALIZED` until `init`. The digest buffer must not overlap the context.

The total byte count is a `uint64_t` limited to `UINT64_MAX / 8`, so the
SHA-256 length field (bits) never wraps. An update that would exceed it fails
with `ERROR_OVERFLOW`; reaching the limit exactly is allowed.

## State validation

The serialized layout is internal; only its size is ABI. Each call validates
a magic word, a phase word, the total limit and backend-specific invariants.
The scalar backend also requires the buffered byte count to equal
`total % 64`, unused block bytes and reserved bytes to be zero, and a finalized
context to have an all-zero payload. Zeroed or random contexts are therefore
rejected as `ERROR_STATE`. This detects misuse and accidental corruption; it is
not an integrity mechanism against deliberate forgery.

## Backends

- Scalar (default on every host): self-contained FIPS 180-4 implementation with
  a rolling 16-word message schedule and 8-way unrolled rounds. Full input
  blocks are compressed directly from caller memory without copying.
- CommonCrypto is disabled at compile time until its opaque-state bounds are
  validated. The dormant Apple implementation was originally selected by compiling `native/diagnostic_sha256.c` with
  `-DFS_DIAGNOSTIC_SHA256_USE_COMMONCRYPTO`. It uses `CC_SHA256_Init/Update/Final`
  from libSystem, so no new dylib is linked. The wrapper keeps the same ABI,
  argument checks, phases, update limit and total overflow check. Its state
  validation covers header and reserved bytes only; it cannot validate
  CommonCrypto's internal state. Defining the macro on non-Apple hosts has no
  effect. Whether it is faster than the scalar backend has not been measured.

## Tests

`tests/native/diagnostic_sha256.c` is valid C11 and C++17 and returns non-zero
on failure. It covers:

- ABI constants and context size;
- FIPS 180 vectors (empty, `abc`, 448-bit, 896-bit) at chunk sizes 1–4096;
- one million `a` at chunk sizes 1, 63, 64, 1000, 4093 and 65536;
- every length 0–300 at every two-way split point and byte-at-a-time;
- contexts and data at odd addresses, and contexts relocated mid-stream;
- NULL arguments, the 65536-byte limit and `SIZE_MAX`;
- zeroed, `0xff`, bad magic/phase/reserved/total contexts, plus scalar-layout
  invariant corruption (skipped for the CommonCrypto build);
- finalized-state rejection, tampered finalized contexts and reinitialization;
- total overflow at the `UINT64_MAX / 8` boundary.

Each rejection test asserts the context and digest buffer are byte-identical
afterwards.

Example invocations (from the repository root):

```sh
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -Inative \
  native/diagnostic_sha256.c tests/native/diagnostic_sha256.c -o diagnostic_sha256_test
./diagnostic_sha256_test

cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -Inative -c native/diagnostic_sha256.c -o diagnostic_sha256.o
c++ -std=c++17 -Wall -Wextra -Wpedantic -Werror -O2 -Inative \
  -x c++ tests/native/diagnostic_sha256.c -x none diagnostic_sha256.o -o diagnostic_sha256_test_cxx
./diagnostic_sha256_test_cxx
```

## Pending qualification

The coordinator owns CMake/CTest registration, randomized comparison against
Python `hashlib`, strict C11 and sanitizer (ASan/UBSan) runs, and real macOS
timing for both backends. The root benchmark hashes 171.6 MB against the
existing 1 s complete source gate; pure Dart measured 1.332 s. The budget is not
relaxed. No throughput figure for this implementation has been measured.
