/*
 * Tests for native/diagnostic_sha256.{h,c}.
 *
 * This file is valid C11 and C++17 so the same source checks the ABI from
 * both languages; link it against the C-compiled implementation. Define
 * FS_DIAGNOSTIC_SHA256_USE_COMMONCRYPTO identically for both translation units
 * when testing the Apple backend.
 */

#include "diagnostic_sha256.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(__APPLE__) && defined(FS_DIAGNOSTIC_SHA256_USE_COMMONCRYPTO)
#define TEST_SCALAR_LAYOUT 0
#else
#define TEST_SCALAR_LAYOUT 1
#endif

#define DIGEST_SIZE FS_DIAGNOSTIC_SHA256_DIGEST_SIZE
#define CONTEXT_SIZE FS_DIAGNOSTIC_SHA256_CONTEXT_SIZE
#define MAX_UPDATE FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE

/* Mirrors the internal header layout; see diagnostic_sha256.c. */
#define TEST_OFF_PHASE 4
#define TEST_OFF_TOTAL 8
#define TEST_MAX_TOTAL_BYTES (UINT64_MAX / 8u)

static int failures;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

static unsigned char big_a[MAX_UPDATE + 1];

static void to_hex(const unsigned char *digest, char *out) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < DIGEST_SIZE; ++i) {
    out[2 * i] = digits[digest[i] >> 4];
    out[2 * i + 1] = digits[digest[i] & 15];
  }
  out[2 * DIGEST_SIZE] = '\0';
}

static void check_hex(const unsigned char *digest, const char *expected,
                      const char *label, size_t chunk) {
  char hex[2 * DIGEST_SIZE + 1];
  to_hex(digest, hex);
  if (strcmp(hex, expected) != 0) {
    fprintf(stderr, "%s (chunk %zu): got %s expected %s\n", label, chunk, hex,
            expected);
    ++failures;
  }
}

/* Hashes `data` in `chunk`-byte updates; returns the first failing status. */
static int hash_chunked(fs_diagnostic_sha256_context *ctx,
                        const unsigned char *data, size_t length, size_t chunk,
                        unsigned char *digest) {
  size_t offset = 0;
  int status = fs_diagnostic_sha256_init(ctx);
  if (status != FS_DIAGNOSTIC_SHA256_OK) {
    return status;
  }
  while (offset < length) {
    size_t n = length - offset < chunk ? length - offset : chunk;
    status = fs_diagnostic_sha256_update(ctx, data + offset, n);
    if (status != FS_DIAGNOSTIC_SHA256_OK) {
      return status;
    }
    offset += n;
  }
  return fs_diagnostic_sha256_final(ctx, digest);
}

static void put_le64(unsigned char *p, uint64_t v) {
  size_t i;
  for (i = 0; i < 8; ++i) {
    p[i] = (unsigned char)(v >> (8 * i));
  }
}

static void test_abi_constants(void) {
  CHECK(sizeof(fs_diagnostic_sha256_context) == 128);
  CHECK(CONTEXT_SIZE == 128);
  CHECK(DIGEST_SIZE == 32);
  CHECK(MAX_UPDATE == 65536u);
  CHECK(FS_DIAGNOSTIC_SHA256_OK == 0);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT < 0);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_STATE < 0);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_FINALIZED < 0);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE < 0);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW < 0);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT !=
        FS_DIAGNOSTIC_SHA256_ERROR_STATE);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_STATE !=
        FS_DIAGNOSTIC_SHA256_ERROR_FINALIZED);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_FINALIZED !=
        FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE);
  CHECK(FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE !=
        FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW);
}

/* FIPS 180-2 / NIST example vectors. */
static void test_known_vectors(void) {
  static const char *const messages[] = {
      "",
      "abc",
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmno"
       "pjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
  };
  static const char *const expected[] = {
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
      "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
  };
  static const size_t chunks[] = {1,  2,  3,  7,  31,  55,  56,
                                  57, 63, 64, 65, 127, 128, 4096};
  size_t m, c;
  for (m = 0; m < sizeof messages / sizeof messages[0]; ++m) {
    for (c = 0; c < sizeof chunks / sizeof chunks[0]; ++c) {
      fs_diagnostic_sha256_context ctx;
      unsigned char digest[DIGEST_SIZE];
      CHECK(hash_chunked(&ctx, (const unsigned char *)messages[m],
                         strlen(messages[m]), chunks[c],
                         digest) == FS_DIAGNOSTIC_SHA256_OK);
      check_hex(digest, expected[m], messages[m], chunks[c]);
    }
  }
}

static void test_million_a(void) {
  static const char *const expected =
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
  static const size_t chunks[] = {1, 63, 64, 1000, 4093, 65536};
  size_t c;
  for (c = 0; c < sizeof chunks / sizeof chunks[0]; ++c) {
    fs_diagnostic_sha256_context ctx;
    unsigned char digest[DIGEST_SIZE];
    size_t remaining = 1000000;
    CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
    while (remaining > 0) {
      size_t n = remaining < chunks[c] ? remaining : chunks[c];
      CHECK(fs_diagnostic_sha256_update(&ctx, big_a, n) ==
            FS_DIAGNOSTIC_SHA256_OK);
      remaining -= n;
    }
    CHECK(fs_diagnostic_sha256_final(&ctx, digest) == FS_DIAGNOSTIC_SHA256_OK);
    check_hex(digest, expected, "million a", chunks[c]);
  }
}

/* Every length 0..300 and every two-way split point agree with one-shot and
 * byte-at-a-time hashing, covering all padding/block boundary positions. */
static void test_split_points(void) {
  unsigned char data[300];
  size_t i, length, split;
  for (i = 0; i < sizeof data; ++i) {
    data[i] = (unsigned char)(i * 131u + 7u);
  }
  for (length = 0; length <= sizeof data; ++length) {
    fs_diagnostic_sha256_context ctx;
    unsigned char reference[DIGEST_SIZE];
    unsigned char digest[DIGEST_SIZE];
    CHECK(hash_chunked(&ctx, data, length, MAX_UPDATE, reference) ==
          FS_DIAGNOSTIC_SHA256_OK);
    CHECK(hash_chunked(&ctx, data, length, 1, digest) ==
          FS_DIAGNOSTIC_SHA256_OK);
    CHECK(memcmp(reference, digest, DIGEST_SIZE) == 0);
    for (split = 0; split <= length; ++split) {
      CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
      CHECK(fs_diagnostic_sha256_update(&ctx, data, split) ==
            FS_DIAGNOSTIC_SHA256_OK);
      CHECK(fs_diagnostic_sha256_update(&ctx, data + split, length - split) ==
            FS_DIAGNOSTIC_SHA256_OK);
      CHECK(fs_diagnostic_sha256_final(&ctx, digest) ==
            FS_DIAGNOSTIC_SHA256_OK);
      if (memcmp(reference, digest, DIGEST_SIZE) != 0) {
        fprintf(stderr, "split mismatch length %zu split %zu\n", length, split);
        ++failures;
      }
    }
  }
}

/* Contexts at odd addresses, data at odd addresses, and contexts relocated
 * with memcpy mid-stream all produce the same digest. */
static void test_alignment_and_relocation(void) {
  static const char *const expected =
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
  static const char message[] =
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  unsigned char storage[CONTEXT_SIZE * 2 + 16];
  unsigned char data_storage[sizeof message + 8];
  size_t offset;
  for (offset = 1; offset < 8; ++offset) {
    fs_diagnostic_sha256_context *ctx =
        (fs_diagnostic_sha256_context *)(storage + offset);
    fs_diagnostic_sha256_context *moved =
        (fs_diagnostic_sha256_context *)(storage + CONTEXT_SIZE + 8 + offset);
    unsigned char *data = data_storage + offset;
    unsigned char digest[DIGEST_SIZE];
    memcpy(data, message, sizeof message - 1);
    CHECK(fs_diagnostic_sha256_init(ctx) == FS_DIAGNOSTIC_SHA256_OK);
    CHECK(fs_diagnostic_sha256_update(ctx, data, 13) ==
          FS_DIAGNOSTIC_SHA256_OK);
    memcpy(moved, ctx, CONTEXT_SIZE);
    memset(ctx, 0, CONTEXT_SIZE);
    CHECK(fs_diagnostic_sha256_update(moved, data + 13,
                                      sizeof message - 1 - 13) ==
          FS_DIAGNOSTIC_SHA256_OK);
    CHECK(fs_diagnostic_sha256_final(moved, digest) == FS_DIAGNOSTIC_SHA256_OK);
    check_hex(digest, expected, "relocated", offset);
  }
}

static void test_bad_arguments(void) {
  fs_diagnostic_sha256_context ctx;
  fs_diagnostic_sha256_context before;
  unsigned char digest[DIGEST_SIZE];
  unsigned char sentinel[DIGEST_SIZE];
  memset(sentinel, 0xa5, sizeof sentinel);

  CHECK(fs_diagnostic_sha256_init(NULL) == FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT);
  CHECK(fs_diagnostic_sha256_update(NULL, "abc", 3) ==
        FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT);
  CHECK(fs_diagnostic_sha256_final(NULL, digest) ==
        FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT);

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, "a", 1) == FS_DIAGNOSTIC_SHA256_OK);
  memcpy(&before, &ctx, sizeof ctx);

  CHECK(fs_diagnostic_sha256_update(&ctx, NULL, 1) ==
        FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);
  CHECK(fs_diagnostic_sha256_update(&ctx, NULL, 0) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);

  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, MAX_UPDATE + 1) ==
        FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);
  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, SIZE_MAX) ==
        FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);

  CHECK(fs_diagnostic_sha256_final(&ctx, NULL) ==
        FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);

  /* After all rejected calls the context still hashes "abc" correctly. */
  CHECK(fs_diagnostic_sha256_update(&ctx, "bc", 2) == FS_DIAGNOSTIC_SHA256_OK);
  memcpy(digest, sentinel, sizeof digest);
  CHECK(fs_diagnostic_sha256_final(&ctx, digest) == FS_DIAGNOSTIC_SHA256_OK);
  check_hex(digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "abc after rejected calls", 0);

  /* The maximum single update is accepted. */
  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, MAX_UPDATE) ==
        FS_DIAGNOSTIC_SHA256_OK);
}

/* Expects update and final to fail with `status` without changing the
 * context or the digest output. */
static void expect_rejected(fs_diagnostic_sha256_context *ctx, int status,
                            const char *label) {
  fs_diagnostic_sha256_context before;
  unsigned char digest[DIGEST_SIZE];
  unsigned char sentinel[DIGEST_SIZE];
  int got;
  memset(sentinel, 0xa5, sizeof sentinel);
  memcpy(digest, sentinel, sizeof digest);
  memcpy(&before, ctx, sizeof before);
  got = fs_diagnostic_sha256_update(ctx, "x", 1);
  if (got != status) {
    fprintf(stderr, "%s: update returned %d expected %d\n", label, got, status);
    ++failures;
  }
  got = fs_diagnostic_sha256_update(ctx, NULL, 0);
  if (got != status) {
    fprintf(stderr, "%s: empty update returned %d expected %d\n", label, got,
            status);
    ++failures;
  }
  got = fs_diagnostic_sha256_final(ctx, digest);
  if (got != status) {
    fprintf(stderr, "%s: final returned %d expected %d\n", label, got, status);
    ++failures;
  }
  if (memcmp(&before, ctx, sizeof before) != 0) {
    fprintf(stderr, "%s: context changed by rejected call\n", label);
    ++failures;
  }
  if (memcmp(digest, sentinel, sizeof digest) != 0) {
    fprintf(stderr, "%s: digest written by rejected call\n", label);
    ++failures;
  }
}

static void test_invalid_state(void) {
  fs_diagnostic_sha256_context ctx;

  memset(&ctx, 0, sizeof ctx);
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "zeroed");

  memset(&ctx, 0xff, sizeof ctx);
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "0xff");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[0] ^= 1;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "bad magic");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[TEST_OFF_PHASE] ^= 1;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "bad phase");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[CONTEXT_SIZE - 1] = 1;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "reserved tail");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  put_le64(ctx.opaque + TEST_OFF_TOTAL, TEST_MAX_TOTAL_BYTES + 1);
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "total too large");

#if TEST_SCALAR_LAYOUT
  /* Scalar payload: buffered count at 16, reserved at 20, block at 56. */
  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, "abc", 3) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[16] = 4;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE,
                  "buffer count disagrees with total");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, "abc", 3) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[16] = 64;
  put_le64(ctx.opaque + TEST_OFF_TOTAL, 64);
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "buffer count 64");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[20] = 1;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "reserved word");

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, "abc", 3) == FS_DIAGNOSTIC_SHA256_OK);
  ctx.opaque[56 + 3] = 1;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE,
                  "nonzero unused block bytes");
#endif
}

static void test_finalization(void) {
  fs_diagnostic_sha256_context ctx;
  unsigned char digest[DIGEST_SIZE];

  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, "abc", 3) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_final(&ctx, digest) == FS_DIAGNOSTIC_SHA256_OK);
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_FINALIZED, "finalized");

  /* A tampered finalized context is invalid rather than finalized. */
  ctx.opaque[40] = 1;
  expect_rejected(&ctx, FS_DIAGNOSTIC_SHA256_ERROR_STATE, "tampered finalized");

  /* Init reuses any context, including finalized or garbage bytes. */
  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_update(&ctx, "abc", 3) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_final(&ctx, digest) == FS_DIAGNOSTIC_SHA256_OK);
  check_hex(digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "abc after reinit", 0);

  memset(&ctx, 0x5a, sizeof ctx);
  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(fs_diagnostic_sha256_final(&ctx, digest) == FS_DIAGNOSTIC_SHA256_OK);
  check_hex(digest,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "empty after garbage init", 0);
}

/* The bit count limit is enforced by patching the serialized total; a block
 * aligned total keeps the scalar buffered-count invariant consistent. */
static void test_total_overflow(void) {
  fs_diagnostic_sha256_context ctx;
  fs_diagnostic_sha256_context before;
  unsigned char digest[DIGEST_SIZE];
  const uint64_t aligned = TEST_MAX_TOTAL_BYTES - 63u;

  CHECK((aligned & 63u) == 0);
  CHECK(fs_diagnostic_sha256_init(&ctx) == FS_DIAGNOSTIC_SHA256_OK);
  put_le64(ctx.opaque + TEST_OFF_TOTAL, aligned);

  memcpy(&before, &ctx, sizeof ctx);
  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, 64) ==
        FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);
  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, MAX_UPDATE) ==
        FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);

  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, 63) ==
        FS_DIAGNOSTIC_SHA256_OK);
  memcpy(&before, &ctx, sizeof ctx);
  CHECK(fs_diagnostic_sha256_update(&ctx, big_a, 1) ==
        FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);
  CHECK(fs_diagnostic_sha256_update(&ctx, NULL, 0) == FS_DIAGNOSTIC_SHA256_OK);
  CHECK(memcmp(&before, &ctx, sizeof ctx) == 0);

  /* Exactly the maximum representable bit count still finalizes. */
  CHECK(fs_diagnostic_sha256_final(&ctx, digest) == FS_DIAGNOSTIC_SHA256_OK);
}

int main(void) {
  memset(big_a, 'a', sizeof big_a);
  test_abi_constants();
  test_known_vectors();
  test_million_a();
  test_split_points();
  test_alignment_and_relocation();
  test_bad_arguments();
  test_invalid_state();
  test_finalization();
  test_total_overflow();
  if (failures != 0) {
    fprintf(stderr, "diagnostic_sha256: %d failure(s)\n", failures);
    return 1;
  }
  printf("diagnostic_sha256: all checks passed\n");
  return 0;
}
