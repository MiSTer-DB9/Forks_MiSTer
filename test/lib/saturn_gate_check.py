#!/usr/bin/env python3
# `saturn_unlocked` AND-gate regression guard (key-gate not decorative).
#
# the marker rules mandates every key-gated Saturn path be ANDed with the
# `saturn_unlocked` signal the db9_key_gate drives, so Saturn stays inert
# without a valid db9pro.key. step6.sh #4b only checks the joydb-instance
# `.saturn_unlocked(...)` PORT is connected and DELIBERATELY accepts a
# `1'b1` tie (InputTest_MiSTer is an always-unlocked test core). Nothing
# catches a merge / porter regression that rewrites a real-signal core's
# `.saturn_unlocked(saturn_unlocked)` -> `(1'b1)` (or drops it entirely)
# while the Pro Saturn markers stay -> the entitlement gate goes decorative
# fleet-wide, every existing test still green.
#
# That cannot be an ABSOLUTE gate (InputTest's legit 1'b1 would FP it).
# It is zero-FP ONLY as a regression DELTA: this check emits exit 1 for a
# `tied` / `absent` connection; merge_validate.sh's baseline/check delta
# cancels a core that is tied in BOTH trees (InputTest), so only a
# `real -> tied/absent` change a merge introduces produces a new token. In
# run_fleet_audit.sh / run_tier0.sh it is ADVISORY ONLY (surface WEAK,
# never gate) -- same treatment as the joydb_semantic WARN tier.
#
# Saturn-capable = sys/joydb9saturn.v present (the fork docs truth source).
# Wrapper present = a `joydb joydb` instance (step6's bespoke predicate).
#
# Usage:  saturn_gate_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = real / n-a; 1 = WEAK (tied | absent); 2 = parse / no <core>.sv.

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

CONN_RE = re.compile(r"\.saturn_unlocked\s*\(\s*([^)]*?)\s*\)")
# A constant tie: 1'b0 / 1'b1 / 1'd0 / 1'h1 / bare 0 / bare 1.
CONST_RE = re.compile(r"^(?:1'[bdh][01]|[01])$", re.I)


def classify(core_dir, core_sv):
    """-> ('real'|'tied'|'absent'|'na', detail)."""
    saturn_capable = os.path.isfile(
        os.path.join(core_dir, "sys", "joydb9saturn.v"))
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    has_wrapper = "joydb joydb" in text
    if not saturn_capable or not has_wrapper:
        return "na", ("no Saturn support" if not saturn_capable
                      else "no joydb wrapper (bespoke / inline)")
    m = CONN_RE.search(text)
    if not m:
        return "absent", (".saturn_unlocked port is NOT connected on the "
                          "joydb instance")
    expr = re.sub(r"\s+", "", m.group(1))
    if CONST_RE.match(expr):
        return "tied", f".saturn_unlocked({m.group(1).strip()}) is a "\
                       f"constant tie (gate decorative)"
    return "real", f".saturn_unlocked({m.group(1).strip()})"


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: saturn_gate_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2] and \
       os.path.isfile(os.path.join(core_dir, argv[2])):
        core_sv = os.path.join(core_dir, argv[2])
    else:
        core_sv = find_core_sv(core_dir)
    cb = os.path.basename(core_sv) if core_sv else ""
    print(f"  satgate-coresv: {cb}")
    if not core_sv:
        print(f"  satgate: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2
    try:
        state, detail = classify(core_dir, core_sv)
    except OSError as e:
        print(f"  satgate: FAIL parse error ({e})")
        return 2

    if state == "real":
        print(f"  satgate: PASS  {detail}  [{cb}]")
        return 0
    if state == "na":
        print(f"  satgate: n/a  {detail}  [{cb}]")
        return 0
    # tied | absent -> WEAK (gates ONLY via merge_validate delta)
    print(f"  satgate: WEAK  {detail} -- Saturn key gate would be "
          f"decorative if this is a regression (delta-gated)  [{cb}]")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
