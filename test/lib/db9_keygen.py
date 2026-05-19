#!/usr/bin/env python3
# Offline MASTER_ROOT generator for db9pro v1.5 key gate.
# Run on an air-gapped machine. The output MUST stay offline.
#
# Usage:
#   db9_keygen.py --out ~/.db9pro-master/
#   db9_keygen.py --rotate --out ~/.db9pro-master/        # bumps generation counter
#
# Outputs (in --out dir):
#   master_root.bin         32 bytes random              KEEP SECRET
#   master_root.hex         hex form                     (paste as MASTER_ROOT_HEX repo secret)
#   manifest.json           { generated_unix, fingerprint }

import argparse
import json
import os
import secrets
import stat
import sys
import time
from pathlib import Path


def write_secret(path: Path, data: bytes) -> None:
    """Write file with 0600 perms; refuse to overwrite without --force."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def fingerprint(root: bytes) -> str:
    """Short fingerprint for human verification (first 8 bytes of SipHash output
    using zero key — this leaks nothing about the actual MASTER_ROOT, since
    SipHash with a known key is just a public hash). Just a sanity tag."""
    import hashlib
    return hashlib.sha256(root).hexdigest()[:16]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="db9pro v1.5 MASTER_ROOT generator (offline only).",
    )
    ap.add_argument("--out", required=True, type=Path,
                    help="output directory (created if missing, mode 0700)")
    ap.add_argument("--rotate", action="store_true",
                    help="acknowledge this is a rotation (refuses to clobber otherwise)")
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing files (DESTROYS PREVIOUS MASTER)")
    args = ap.parse_args()

    out: Path = args.out.expanduser().resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(out, 0o700)

    targets = {
        "root":     out / "master_root.bin",
        "root_hex": out / "master_root.hex",
        "manifest": out / "manifest.json",
    }

    existing = [p for p in targets.values() if p.exists()]
    if existing:
        if not args.force and not args.rotate:
            sys.exit(
                f"ERROR: refusing to clobber existing files: {[str(p) for p in existing]}\n"
                f"Use --rotate (intentional rotation) or --force to overwrite."
            )
        for p in existing:
            p.unlink()

    root = secrets.token_bytes(32)

    write_secret(targets["root"], root)
    write_secret(targets["root_hex"], (root.hex() + "\n").encode())

    manifest = {
        "generated_unix": int(time.time()),
        "fingerprint":    fingerprint(root),
        "rotation":       bool(args.rotate),
    }
    targets["manifest"].write_text(json.dumps(manifest, indent=2) + "\n")

    print(f"MASTER_ROOT generated in {out}/")
    print(f"  fingerprint:        {manifest['fingerprint']}")
    print()
    print("SECRET (offline only, never commit, never CI logs):")
    print(f"  master_root.bin    -> embed in RBF + Main_MiSTer via repo secret MASTER_ROOT_HEX")
    print(f"  master_root.hex    = {root.hex()}")
    print()
    print("Next: run db9_sign.py to issue per-customer keys.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
