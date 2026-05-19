// [MiSTer-DB9-Pro BEGIN] - SipHash-2-4 portable reference
// Test vectors: matches libsodium's crypto_shorthash_siphash24 for the same
// (msg, key) inputs. Self-test in db9_keygen.py and the Verilog testbench
// share the canonical Aumasson reference vectors.
#include "siphash24.h"

#include <string.h>

#define ROTL(x, b) ((uint64_t)(((x) << (b)) | ((x) >> (64 - (b)))))

#define SIPROUND                                          \
	do {                                              \
		v0 += v1; v1 = ROTL(v1, 13); v1 ^= v0;    \
		v0 = ROTL(v0, 32);                        \
		v2 += v3; v3 = ROTL(v3, 16); v3 ^= v2;    \
		v0 += v3; v3 = ROTL(v3, 21); v3 ^= v0;    \
		v2 += v1; v1 = ROTL(v1, 17); v1 ^= v2;    \
		v2 = ROTL(v2, 32);                        \
	} while (0)

static uint64_t le64(const uint8_t *p)
{
	return  (uint64_t)p[0]        | ((uint64_t)p[1] <<  8) |
	       ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 24) |
	       ((uint64_t)p[4] << 32) | ((uint64_t)p[5] << 40) |
	       ((uint64_t)p[6] << 48) | ((uint64_t)p[7] << 56);
}

void siphash24(const uint8_t *in, size_t inlen,
               const uint8_t key[16], uint8_t out[8])
{
	uint64_t k0 = le64(key);
	uint64_t k1 = le64(key + 8);

	uint64_t v0 = k0 ^ 0x736f6d6570736575ULL;
	uint64_t v1 = k1 ^ 0x646f72616e646f6dULL;
	uint64_t v2 = k0 ^ 0x6c7967656e657261ULL;
	uint64_t v3 = k1 ^ 0x7465646279746573ULL;

	const uint8_t *end = in + inlen - (inlen & 7);
	const size_t left = inlen & 7;
	uint64_t b = ((uint64_t)inlen) << 56;

	for (; in != end; in += 8) {
		uint64_t m = le64(in);
		v3 ^= m;
		SIPROUND;
		SIPROUND;
		v0 ^= m;
	}

	switch (left) {
		case 7: b |= ((uint64_t)in[6]) << 48; /* fallthrough */
		case 6: b |= ((uint64_t)in[5]) << 40; /* fallthrough */
		case 5: b |= ((uint64_t)in[4]) << 32; /* fallthrough */
		case 4: b |= ((uint64_t)in[3]) << 24; /* fallthrough */
		case 3: b |= ((uint64_t)in[2]) << 16; /* fallthrough */
		case 2: b |= ((uint64_t)in[1]) <<  8; /* fallthrough */
		case 1: b |= ((uint64_t)in[0]);       /* fallthrough */
		case 0: break;
	}

	v3 ^= b;
	SIPROUND;
	SIPROUND;
	v0 ^= b;

	v2 ^= 0xff;
	SIPROUND;
	SIPROUND;
	SIPROUND;
	SIPROUND;

	uint64_t r = v0 ^ v1 ^ v2 ^ v3;
	out[0] = (uint8_t)(r);
	out[1] = (uint8_t)(r >>  8);
	out[2] = (uint8_t)(r >> 16);
	out[3] = (uint8_t)(r >> 24);
	out[4] = (uint8_t)(r >> 32);
	out[5] = (uint8_t)(r >> 40);
	out[6] = (uint8_t)(r >> 48);
	out[7] = (uint8_t)(r >> 56);
}
// [MiSTer-DB9-Pro END]
