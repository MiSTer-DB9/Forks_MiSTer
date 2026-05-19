#!/usr/bin/env python3
# Self-test for saturn_gate_check.py. Pure Python. Fixtures:
# test/fixtures/saturn_gate/<case>/Core_MiSTer/{core.sv,sys/joydb9saturn.v}.
# Locks in:
#   * real saturn_unlocked signal        -> PASS exit 0
#   * constant tie (1'b1)                -> WEAK exit 1 (delta-cancelled)
#   * port not connected                 -> WEAK exit 1
#   * not Saturn-capable                 -> n/a  exit 0 (no false positive)
#
#   python3 test/lib/test_saturn_gate_check.py  # "SATGATE selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "saturn_gate_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "saturn_gate")

# (case, expected_exit, must_contain)
CASES = [
    ("real",   0, "PASS"),
    ("tied",   1, "constant tie"),
    ("absent", 1, "NOT connected"),
    ("na",     0, "no Saturn support"),
    ("real",   0, None),     # regression guard: no WEAK/FAIL on real
]


def run(case):
    p = subprocess.run(
        [sys.executable, CHECK,
         os.path.join(FIX, case, "Core_MiSTer"), "core.sv"],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []
    for case, want_rc, want in CASES:
        rc, out = run(case)
        ok = (rc == want_rc)
        if want is None:
            ok = ok and ("WEAK" not in out) and ("FAIL" not in out)
            why = "no WEAK/FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {case:<8} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(case)
            print(out.rstrip())
    if fails:
        print(f"SATGATE selftest: FAIL ({', '.join(fails)})")
        return 1
    print("SATGATE selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
