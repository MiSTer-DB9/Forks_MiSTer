#!/usr/bin/env python3
# Verify a db9pro v1.5 key file against MASTER_ROOT.
#
# Usage:
#   db9_verify.py --root master_root.bin key.file
#
# Exit code: 0 = valid, 1 = invalid (with reason on stderr).
#
# Used for:
#   - regression tests against db9_sign.py
#   - sanity-check before delivering a key to a customer
#   - debugging FPGA-side mismatches

import argparse
import struct
import sys
import time
from pathlib import Path

# Reuse the SipHash impl from db9_sign.py.
sys.path.insert(0, str(Path(__file__).parent))
from db9_sign import (  # noqa: E402
    siphash24,
    DB9_KEY_MAGIC, DB9_KEY_VERSION, KEY_SIZE, SIGNED_RANGE,
    FEATURE_BITS, FLAG_TEST,
)


def parse_key(blob: bytes) -> dict:
    if len(blob) != KEY_SIZE:
        raise ValueError(f"bad size {len(blob)} (expected {KEY_SIZE})")
    fmt = "<IHHQIIII"
    fixed = struct.calcsize(fmt)
    assert fixed == 32
    (magic, version, flags, customer_id,
     issue, expiry, feature_mask, reserved) = struct.unpack(fmt, blob[:fixed])
    return {
        "magic":             magic,
        "version":           version,
        "flags":             flags,
        "customer_id":       customer_id,
        "issue_unix":        issue,
        "expiry_unix":       expiry,
        "feature_mask":      feature_mask,
        "reserved":          reserved,
        "per_customer_seed": blob[32:40],
        "auth_tag":          blob[40:48],
        "pad":               blob[48:64],
    }


def feature_names(mask: int) -> str:
    names = [n for n, b in FEATURE_BITS.items() if mask & b]
    return ",".join(names) if names else "(none)"


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Verify a db9pro v1.5 per-customer key file.",
    )
    ap.add_argument("--root", required=True, type=Path,
                    help="MASTER_ROOT file (32B raw)")
    ap.add_argument("key_file", type=Path,
                    help="path to db9pro.key (64 bytes)")
    args = ap.parse_args()

    root = args.root.expanduser().read_bytes()
    if len(root) != 32:
        sys.exit(f"{args.root}: must be 32 bytes (got {len(root)})")

    blob = args.key_file.read_bytes()
    try:
        k = parse_key(blob)
    except ValueError as e:
        sys.exit(f"{args.key_file}: {e}")

    if k["magic"] != DB9_KEY_MAGIC:
        sys.exit(f"{args.key_file}: bad magic 0x{k['magic']:08x} (expected 0x{DB9_KEY_MAGIC:08x})")
    if k["version"] != DB9_KEY_VERSION:
        sys.exit(f"{args.key_file}: unsupported version 0x{k['version']:04x}")
    if k["customer_id"] == 0:
        sys.exit(f"{args.key_file}: customer_id is zero")
    if k["reserved"] != 0:
        sys.exit(f"{args.key_file}: reserved field is 0x{k['reserved']:08x} (must be 0)")

    sip_key = root[:16]
    expected_tag  = siphash24(blob[:SIGNED_RANGE], sip_key)
    expected_seed = siphash24(k["customer_id"].to_bytes(8, "little"), sip_key)

    tag_ok  = expected_tag  == k["auth_tag"]
    seed_ok = expected_seed == k["per_customer_seed"]

    now = int(time.time())
    expired = k["expiry_unix"] < now

    print(f"{args.key_file}:")
    print(f"  magic         : 0x{k['magic']:08x} OK")
    print(f"  version       : 0x{k['version']:04x}")
    print(f"  flags         : 0x{k['flags']:04x}"
          f"{' (TEST)' if k['flags'] & FLAG_TEST else ''}")
    print(f"  customer_id   : {k['customer_id']}")
    print(f"  issue_unix    : {k['issue_unix']}  ({time.strftime('%Y-%m-%d', time.gmtime(k['issue_unix']))} UTC)")
    print(f"  expiry_unix   : {k['expiry_unix']} ({time.strftime('%Y-%m-%d', time.gmtime(k['expiry_unix']))} UTC)"
          f"{' [EXPIRED]' if expired else ''}")
    print(f"  feature_mask  : 0x{k['feature_mask']:08x}  ({feature_names(k['feature_mask'])})")
    print(f"  auth_tag      : {k['auth_tag'].hex()}  {'OK' if tag_ok else 'BAD MAC'}")
    print(f"  per_cust_seed : {k['per_customer_seed'].hex()}  {'OK' if seed_ok else 'mismatch (informational)'}")

    if not tag_ok:
        print("VERIFICATION FAILED: auth_tag mismatch", file=sys.stderr)
        return 1
    if expired:
        print("VERIFICATION FAILED: key expired", file=sys.stderr)
        return 1

    print("VERIFICATION OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
