#!/usr/bin/env python3
# Self-test for mt32_gate_check.py. Pure Python, no iverilog / no core repos
# -- runs the analyzer against the hand-built fixtures in
# test/fixtures/mt32_gate/ and asserts exit code + a signature substring per
# case. Locks in the FATAL tier (fleet-audit 0-false-positive contract):
# both correct variants (always_comb + TRS-80) and the non-MT32 n/a case
# must NOT FAIL; only the genuine Gate 1 / Gate 2 defects do.
#
#   python3 test/lib/test_mt32_gate_check.py   # -> "MT32GATE selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "mt32_gate_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "mt32_gate")

# (fixture, expected_exit, must_contain)
CASES = [
    ("good.sv",       0, "both anti-contention gates present"),
    ("good_trs80.sv", 0, "both anti-contention gates present"),
    ("bad_gate1.sv",  1, "Gate 1 missing"),
    ("bad_gate2.sv",  1, "Gate 2 missing"),
    ("nonmt32.sv",    0, "n/a"),
    # regression guard: a correct core must never emit FAIL.
    ("good.sv",       0, None),   # None => assert NO 'FAIL' in output
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
            ok = ok and ("FAIL" not in out)
            why = "no FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {fixture:<16} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(fixture)
            print(out.rstrip())
    if fails:
        print(f"MT32GATE selftest: FAIL ({', '.join(fails)})")
        return 1
    print("MT32GATE selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
