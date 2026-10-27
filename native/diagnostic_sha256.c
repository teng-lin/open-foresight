#include "diagnostic_sha256.h"

#include <stdint.h>
#include <string.h>

/*
 * Serialized context layout (little-endian, internal; only the size is ABI):
 *
 *   0  u32 magic (backend specific)
 *   4  u32 phase
 *   8  u64 total message bytes
 *  16  backend payload
 *
 * Scalar payload: 16 u32 buffered byte count, 20 u32 reserved zero,
 * 24 u32[8] chaining value, 56 u8[64] pending block (unused tail zero),
 * 120..127 reserved zero.
 *
 * CommonCrypto payload: 16 CC_SHA256_CTX bytes, remaining tail reserved zero.
 *
 * Every call loads the bytes into a local state, validates it, works on the
 * copy and stores the whole context with one memcpy only on success. This
 * makes caller alignment irrelevant and keeps failures transactional.
 */

#if defined(FS_DIAGNOSTIC_SHA256_USE_COMMONCRYPTO)
#error CommonCrypto diagnostic hashing is not qualified for opaque-state validation
#endif

#if defined(__APPLE__) && defined(FS_DIAGNOSTIC_SHA256_USE_COMMONCRYPTO)
#define FS_SHA256_COMMONCRYPTO 1
#include <CommonCrypto/CommonDigest.h>
#else
#define FS_SHA256_COMMONCRYPTO 0
#endif

#define CONTEXT_SIZE FS_DIAGNOSTIC_SHA256_CONTEXT_SIZE
#define BLOCK_SIZE 64u

#define OFF_MAGIC 0
#define OFF_PHASE 4
#define OFF_TOTAL 8
#define OFF_PAYLOAD 16

#define PHASE_ACTIVE 0x41435456u
#define PHASE_FINALIZED 0x46494e4cu

/* The bit count, total * 8, must fit in uint64_t. */
#define MAX_TOTAL_BYTES (UINT64_MAX / 8u)

#if FS_SHA256_COMMONCRYPTO
#define CONTEXT_MAGIC 0x43534846u
#define OFF_CC OFF_PAYLOAD
#define OFF_CC_END (OFF_CC + sizeof(CC_SHA256_CTX))
_Static_assert(sizeof(CC_SHA256_CTX) <= CONTEXT_SIZE - OFF_CC,
               "CC_SHA256_CTX does not fit the opaque context");
#else
#define CONTEXT_MAGIC 0x53534846u
#define OFF_BUFFER_LEN 16
#define OFF_RESERVED 20
#define OFF_H 24
#define OFF_BUFFER 56
#define OFF_TAIL 120
_Static_assert(OFF_TAIL == OFF_BUFFER + BLOCK_SIZE, "scalar layout");
#endif

_Static_assert(sizeof(fs_diagnostic_sha256_context) == CONTEXT_SIZE,
               "opaque context size is ABI");

typedef struct sha256_state {
  uint64_t total;
#if FS_SHA256_COMMONCRYPTO
  CC_SHA256_CTX cc;
#else
  uint32_t h[8];
  uint32_t buffer_len;
  unsigned char buffer[BLOCK_SIZE];
#endif
} sha256_state;

static uint32_t load_le32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static uint64_t load_le64(const unsigned char *p) {
  return (uint64_t)load_le32(p) | ((uint64_t)load_le32(p + 4) << 32);
}

static void store_le32(unsigned char *p, uint32_t v) {
  p[0] = (unsigned char)v;
  p[1] = (unsigned char)(v >> 8);
  p[2] = (unsigned char)(v >> 16);
  p[3] = (unsigned char)(v >> 24);
}

static void store_le64(unsigned char *p, uint64_t v) {
  store_le32(p, (uint32_t)v);
  store_le32(p + 4, (uint32_t)(v >> 32));
}

static int bytes_are_zero(const unsigned char *p, size_t from, size_t to) {
  unsigned char acc = 0;
  size_t i;
  for (i = from; i < to; ++i) {
    acc |= p[i];
  }
  return acc == 0;
}

static void store_header(unsigned char *out, uint32_t phase, uint64_t total) {
  store_le32(out + OFF_MAGIC, CONTEXT_MAGIC);
  store_le32(out + OFF_PHASE, phase);
  store_le64(out + OFF_TOTAL, total);
}

static void store_finalized(fs_diagnostic_sha256_context *context) {
  unsigned char out[CONTEXT_SIZE];
  memset(out, 0, sizeof out);
  store_header(out, PHASE_FINALIZED, 0);
  memcpy(context->opaque, out, sizeof out);
}

#if FS_SHA256_COMMONCRYPTO

static int load_payload(const unsigned char *p, sha256_state *s) {
  if (!bytes_are_zero(p, OFF_CC_END, CONTEXT_SIZE)) {
    return FS_DIAGNOSTIC_SHA256_ERROR_STATE;
  }
  memcpy(&s->cc, p + OFF_CC, sizeof s->cc);
  return FS_DIAGNOSTIC_SHA256_OK;
}

static void store_active(fs_diagnostic_sha256_context *context,
                         const sha256_state *s) {
  unsigned char out[CONTEXT_SIZE];
  memset(out, 0, sizeof out);
  store_header(out, PHASE_ACTIVE, s->total);
  memcpy(out + OFF_CC, &s->cc, sizeof s->cc);
  memcpy(context->opaque, out, sizeof out);
}

static void state_reset(sha256_state *s) {
  memset(s, 0, sizeof *s);
  (void)CC_SHA256_Init(&s->cc);
}

static void state_absorb(sha256_state *s, const unsigned char *data,
                         size_t length) {
  /* length <= FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE fits CC_LONG. */
  (void)CC_SHA256_Update(&s->cc, data, (CC_LONG)length);
}

static void state_finish(sha256_state *s, unsigned char *digest) {
  (void)CC_SHA256_Final(digest, &s->cc);
}

#else

static const uint32_t k_round[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static const uint32_t k_initial[8] = {
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define BSIG0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define BSIG1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SSIG0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SSIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))
#define CH(x, y, z) ((z) ^ ((x) & ((y) ^ (z))))
#define MAJ(x, y, z) (((x) & (y)) | ((z) & ((x) | (y))))

/* Rolling 16-word message schedule. */
#define SCHEDULE(t)                                                            \
  (w[(t) & 15] +=                                                              \
   SSIG1(w[((t) - 2) & 15]) + w[((t) - 7) & 15] + SSIG0(w[((t) - 15) & 15]))

#define ROUND(a, b, c, d, e, f, g, h, t)                                       \
  do {                                                                         \
    uint32_t t1 = (h) + BSIG1(e) + CH(e, f, g) + k_round[t] + w[(t) & 15];     \
    uint32_t t2 = BSIG0(a) + MAJ(a, b, c);                                     \
    (d) += t1;                                                                 \
    (h) = t1 + t2;                                                             \
  } while (0)

static uint32_t load_be32(const unsigned char *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void store_be32(unsigned char *p, uint32_t v) {
  p[0] = (unsigned char)(v >> 24);
  p[1] = (unsigned char)(v >> 16);
  p[2] = (unsigned char)(v >> 8);
  p[3] = (unsigned char)v;
}

static void compress_blocks(uint32_t state[8], const unsigned char *p,
                            size_t blocks) {
  uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
  uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

  while (blocks-- > 0) {
    uint32_t w[16];
    unsigned t, j;
    for (j = 0; j < 16; ++j) {
      w[j] = load_be32(p + 4 * j);
    }
    for (t = 0; t < 64; t += 8) {
      if (t >= 16) {
        for (j = 0; j < 8; ++j) {
          SCHEDULE(t + j);
        }
      }
      ROUND(a, b, c, d, e, f, g, h, t + 0);
      ROUND(h, a, b, c, d, e, f, g, t + 1);
      ROUND(g, h, a, b, c, d, e, f, t + 2);
      ROUND(f, g, h, a, b, c, d, e, t + 3);
      ROUND(e, f, g, h, a, b, c, d, t + 4);
      ROUND(d, e, f, g, h, a, b, c, t + 5);
      ROUND(c, d, e, f, g, h, a, b, t + 6);
      ROUND(b, c, d, e, f, g, h, a, t + 7);
    }
    a = state[0] += a;
    b = state[1] += b;
    c = state[2] += c;
    d = state[3] += d;
    e = state[4] += e;
    f = state[5] += f;
    g = state[6] += g;
    h = state[7] += h;
    p += BLOCK_SIZE;
  }
}

static int load_payload(const unsigned char *p, sha256_state *s) {
  size_t i;
  s->buffer_len = load_le32(p + OFF_BUFFER_LEN);
  if (load_le32(p + OFF_RESERVED) != 0 ||
      !bytes_are_zero(p, OFF_TAIL, CONTEXT_SIZE) ||
      s->buffer_len >= BLOCK_SIZE ||
      (s->total & (BLOCK_SIZE - 1)) != s->buffer_len ||
      !bytes_are_zero(p, OFF_BUFFER + s->buffer_len, OFF_TAIL)) {
    return FS_DIAGNOSTIC_SHA256_ERROR_STATE;
  }
  for (i = 0; i < 8; ++i) {
    s->h[i] = load_le32(p + OFF_H + 4 * i);
  }
  memcpy(s->buffer, p + OFF_BUFFER, BLOCK_SIZE);
  return FS_DIAGNOSTIC_SHA256_OK;
}

static void store_active(fs_diagnostic_sha256_context *context,
                         const sha256_state *s) {
  unsigned char out[CONTEXT_SIZE];
  size_t i;
  memset(out, 0, sizeof out);
  store_header(out, PHASE_ACTIVE, s->total);
  store_le32(out + OFF_BUFFER_LEN, s->buffer_len);
  for (i = 0; i < 8; ++i) {
    store_le32(out + OFF_H + 4 * i, s->h[i]);
  }
  memcpy(out + OFF_BUFFER, s->buffer, s->buffer_len);
  memcpy(context->opaque, out, sizeof out);
}

static void state_reset(sha256_state *s) {
  memset(s, 0, sizeof *s);
  memcpy(s->h, k_initial, sizeof s->h);
}

static void state_absorb(sha256_state *s, const unsigned char *data,
                         size_t length) {
  size_t blocks;
  if (s->buffer_len > 0) {
    size_t take = BLOCK_SIZE - s->buffer_len;
    if (take > length) {
      take = length;
    }
    memcpy(s->buffer + s->buffer_len, data, take);
    s->buffer_len += (uint32_t)take;
    data += take;
    length -= take;
    if (s->buffer_len < BLOCK_SIZE) {
      return;
    }
    compress_blocks(s->h, s->buffer, 1);
    memset(s->buffer, 0, sizeof s->buffer);
    s->buffer_len = 0;
  }
  blocks = length / BLOCK_SIZE;
  compress_blocks(s->h, data, blocks);
  data += blocks * BLOCK_SIZE;
  length -= blocks * BLOCK_SIZE;
  if (length > 0) {
    memcpy(s->buffer, data, length);
    s->buffer_len = (uint32_t)length;
  }
}

static void state_finish(sha256_state *s, unsigned char *digest) {
  uint64_t bits = s->total * 8u;
  size_t i;
  s->buffer[s->buffer_len] = 0x80;
  if (s->buffer_len >= BLOCK_SIZE - 8) {
    compress_blocks(s->h, s->buffer, 1);
    memset(s->buffer, 0, sizeof s->buffer);
  }
  store_be32(s->buffer + 56, (uint32_t)(bits >> 32));
  store_be32(s->buffer + 60, (uint32_t)bits);
  compress_blocks(s->h, s->buffer, 1);
  for (i = 0; i < 8; ++i) {
    store_be32(digest + 4 * i, s->h[i]);
  }
}

#endif

static int load_state(const fs_diagnostic_sha256_context *context,
                      sha256_state *s) {
  const unsigned char *p = context->opaque;
  uint32_t phase;
  if (load_le32(p + OFF_MAGIC) != CONTEXT_MAGIC) {
    return FS_DIAGNOSTIC_SHA256_ERROR_STATE;
  }
  phase = load_le32(p + OFF_PHASE);
  s->total = load_le64(p + OFF_TOTAL);
  if (phase == PHASE_FINALIZED) {
    return s->total == 0 && bytes_are_zero(p, OFF_PAYLOAD, CONTEXT_SIZE)
               ? FS_DIAGNOSTIC_SHA256_ERROR_FINALIZED
               : FS_DIAGNOSTIC_SHA256_ERROR_STATE;
  }
  if (phase != PHASE_ACTIVE || s->total > MAX_TOTAL_BYTES) {
    return FS_DIAGNOSTIC_SHA256_ERROR_STATE;
  }
  return load_payload(p, s);
}

int fs_diagnostic_sha256_init(fs_diagnostic_sha256_context *context) {
  sha256_state s;
  if (context == NULL) {
    return FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT;
  }
  state_reset(&s);
  store_active(context, &s);
  return FS_DIAGNOSTIC_SHA256_OK;
}

int fs_diagnostic_sha256_update(fs_diagnostic_sha256_context *context,
                                const void *data, size_t length) {
  sha256_state s;
  int status;
  if (context == NULL) {
    return FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT;
  }
  if (length > FS_DIAGNOSTIC_SHA256_MAX_UPDATE_SIZE) {
    return FS_DIAGNOSTIC_SHA256_ERROR_TOO_LARGE;
  }
  if (data == NULL && length > 0) {
    return FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT;
  }
  status = load_state(context, &s);
  if (status != FS_DIAGNOSTIC_SHA256_OK) {
    return status;
  }
  if ((uint64_t)length > MAX_TOTAL_BYTES - s.total) {
    return FS_DIAGNOSTIC_SHA256_ERROR_OVERFLOW;
  }
  if (length == 0) {
    return FS_DIAGNOSTIC_SHA256_OK;
  }
  state_absorb(&s, (const unsigned char *)data, length);
  s.total += length;
  store_active(context, &s);
  return FS_DIAGNOSTIC_SHA256_OK;
}

int fs_diagnostic_sha256_final(fs_diagnostic_sha256_context *context,
                               unsigned char *digest) {
  sha256_state s;
  unsigned char result[FS_DIAGNOSTIC_SHA256_DIGEST_SIZE];
  int status;
  if (context == NULL || digest == NULL) {
    return FS_DIAGNOSTIC_SHA256_ERROR_ARGUMENT;
  }
  status = load_state(context, &s);
  if (status != FS_DIAGNOSTIC_SHA256_OK) {
    return status;
  }
  state_finish(&s, result);
  store_finalized(context);
  memcpy(digest, result, sizeof result);
  return FS_DIAGNOSTIC_SHA256_OK;
}
