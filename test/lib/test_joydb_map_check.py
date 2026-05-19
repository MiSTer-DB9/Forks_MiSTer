#!/usr/bin/env python3
# Self-test for joydb_map_check.py. Pure Python, no iverilog / no core repos
# -- runs the analyzer against the hand-built fixtures in
# test/fixtures/joydb_map/ and asserts exit code + a signature substring per
# case. Keeps the FATAL tier honest (the fleet-audit 0-false-positive
# contract) and locks in that a pure P1/P2 *order* swap is NOT reported.
#
#   python3 test/lib/test_joydb_map_check.py        # -> "JOYDBMAP selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "joydb_map_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "joydb_map")

# (fixture, expected_exit, must_contain)
CASES = [
    ("good.sv",       0, "joydbmap: ok"),
    ("leak.sv",       1, "P1/P2 leak"),
    ("range.sv",      1, "out-of-range bit"),
    ("noosd.sv",      1, "missing OSD_STATUS guard"),
    ("divergence.sv", 0, "P1/P2 bit-set divergence"),
    # good.sv doubles as the order-swap regression guard: its P1 arm is
    # {11,9,10,4:0} and P2 {11,10,9,4:0} -- same bit set, swapped order.
    # Asserting it stays exit 0 with NO divergence line proves the
    # convention is not misreported.
    ("good.sv",       0, None),   # None => assert NO 'divergence' in output
]


def run(fixture):
    p = subprocess.run([sys.executable, CHECK, FIX, fixture],
                        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []
    for fixture, want_rc, want in CASES:
        rc, out = run(fixture)
        ok = (rc == want_rc)
        if want is None:
            ok = ok and ("divergence" not in out)
            why = "no divergence line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {fixture:<16} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(fixture)
            print(out.rstrip())
    if fails:
        print(f"JOYDBMAP selftest: FAIL ({', '.join(fails)})")
        return 1
    print("JOYDBMAP selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
