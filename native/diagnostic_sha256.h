#ifndef FORESIGHT_NATIVE_DIAGNOSTIC_SHA256_H
#define FORESIGHT_NATIVE_DIAGNOSTIC_SHA256_H

/*
 * Streaming SHA-256 leaf for public source verification.
 *
 * Separate from the owner function table: these three symbols are the whole
 * ABI. The context is a fixed 128-byte opaque blob with byte alignment, so
 * callers (including Dart FFI) may place it at any address and may relocate it
 * with memcpy between calls. The implementation performs no allocation, IO,
 * threading, callbacks or environment access. A context must not be used
 * concurrently from several threads; distinct contexts are independent.
 *
 * Every failing call leaves the context and the digest output unchanged.
 * See docs/architecture/diagnostic-sha256.md for the full contract.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__) || defined(__clang__)
#define FS_DIAGNOSTIC_SHA256_EXPORT __attribute__((visibility("default")))
#else
#define FS_DIAGNOSTIC_SHA256_EXPORT
#endif

#define FS_DIAGNOSTIC_SHA256_CONTEXT_SIZE 128
#define FS_DIAGNOSTIC_SHA256_DIGEST_SIZE 32
#define FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE 65536u

/* Return codes. */
#define FS_DIAGNOSTIC_SHA256_OK 0
/* NULL context, NULL digest output, or NULL data with a non-zero length. */
#define FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT (-1)
/* Context was never initialized, is zeroed, or is corrupt. */
#define FS_DIAGNOSTIC_SHA256_ERROR_STATE (-2)
/* Context was already finalized; call init to reuse it. */
#define FS_DIAGNOSTIC_SHA256_ERROR_FINALIZED (-3)
/* A single update exceeded FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE bytes. */
#define FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE (-4)
/* The total message bit count would no longer fit in 64 bits. */
#define FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW (-5)

typedef struct fs_diagnostic_sha256_context {
  unsigned char opaque[FS_DIAGNOSTIC_SHA256_CONTEXT_SIZE];
} fs_diagnostic_sha256_context;

/* Resets any context bytes (initialized or not) to an empty active hash. */
FS_DIAGNOSTIC_SHA256_EXPORT int
fs_diagnostic_sha256_init(fs_diagnostic_sha256_context *context);

/* Absorbs `length` bytes (at most FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE).
 * `data` may be NULL only when `length` is zero. */
FS_DIAGNOSTIC_SHA256_EXPORT int
fs_diagnostic_sha256_update(fs_diagnostic_sha256_context *context,
                            const void *data, size_t length);

/* Writes the 32-byte digest and marks the context finalized. `digest` must
 * not overlap `context`. */
FS_DIAGNOSTIC_SHA256_EXPORT int
fs_diagnostic_sha256_final(fs_diagnostic_sha256_context *context,
                           unsigned char *digest);

#ifdef __cplusplus
}
#endif

#endif
