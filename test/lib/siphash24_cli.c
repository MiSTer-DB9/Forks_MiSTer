// Hermetic SipHash-2-4 CLI for the key-gate C<->Verilog parity step of
// test_gate_e2e.sh. NOT shipped to hardware, NOT mirrored from Main_MiSTer:
// it only drives the byte-identical mirror copy siphash24.c so a drift
// between Main_MiSTer/siphash24.c and siphash24.v / db9_sign.py is caught in
// CI (run_tier0.sh cmp-guards the mirror against Main_MiSTer).
//
//   siphash24_cli <key_hex_32> <msg_hex>
//
// key_hex   : exactly 32 hex chars (16-byte SipHash key, = MASTER_ROOT[:16]).
// msg_hex   : even number of hex chars (the signed payload bytes; empty ok).
// stdout    : 16 lowercase hex chars = the 8-byte LE tag. Exit 2 on bad args.

#include "siphash24.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

// Decode a hex string into buf (cap bytes). Returns byte count, or -1 on a
// malformed/oversized input.
static int unhex(const char *s, uint8_t *buf, size_t cap)
{
	size_t n = strlen(s);
	if (n & 1) return -1;
	n /= 2;
	if (n > cap) return -1;
	for (size_t i = 0; i < n; i++) {
		int hi = hexval((unsigned char)s[2 * i]);
		int lo = hexval((unsigned char)s[2 * i + 1]);
		if (hi < 0 || lo < 0) return -1;
		buf[i] = (uint8_t)((hi << 4) | lo);
	}
	return (int)n;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <key_hex_32> <msg_hex>\n", argv[0]);
		return 2;
	}

	uint8_t key[16];
	if (unhex(argv[1], key, sizeof(key)) != 16) {
		fprintf(stderr, "key must be exactly 32 hex chars\n");
		return 2;
	}

	uint8_t msg[256];
	int mlen = unhex(argv[2], msg, sizeof(msg));
	if (mlen < 0) {
		fprintf(stderr, "msg hex malformed or too long (max %zu bytes)\n",
		        sizeof(msg));
		return 2;
	}

	uint8_t out[8];
	siphash24(msg, (size_t)mlen, key, out);
	for (int i = 0; i < 8; i++) printf("%02x", out[i]);
	printf("\n");
	return 0;
}
