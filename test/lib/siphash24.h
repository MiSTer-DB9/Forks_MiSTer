// [MiSTer-DB9-Pro BEGIN] - SipHash-2-4 portable reference (Aumasson + Bernstein 2012)
// Used by db9_key.cpp to verify v1.5 db9pro.key MAC. Output matches both
// libsodium's crypto_shorthash_siphash24 and the Verilog gate in
// sys/siphash24.v / sys/db9_key_gate.sv.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// in/inlen: message bytes. key: 16 bytes (lo 64 first, hi 64 next; little-endian).
// out: 8-byte tag, little-endian.
void siphash24(const uint8_t *in, size_t inlen,
               const uint8_t key[16], uint8_t out[8]);

#ifdef __cplusplus
}
#endif
// [MiSTer-DB9-Pro END]
