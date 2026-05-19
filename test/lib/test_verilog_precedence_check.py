#!/usr/bin/env python3
# Self-test for verilog_precedence_check.py. Pure Python. Fixtures:
# test/fixtures/verilog_precedence/<case>/Core_MiSTer/core.sv. Locks in:
#   * verified true-negatives (== both sides, `&& 4'hF > M`, `|| 1'b0`,
#     `&& 1`, parenthesised, masked string)      -> PASS  exit 0 (zero-FP)
#   * the 3a94b0a `== 4'hF || 4'hA` shape         -> FATAL exit 1
#
#   python3 test/lib/test_verilog_precedence_check.py  # "VPREC selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "verilog_precedence_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "verilog_precedence")

# (case, expected_exit, must_contain)
CASES = [
    ("ok",     0, "clean"),
    ("defect", 1, "the 3a94b0a class"),
    ("ok",     0, None),     # regression guard: no FAIL on the clean fixture
]


def run(case):
    p = subprocess.run(
        [sys.executable, CHECK, os.path.join(FIX, case, "Core_MiSTer")],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []
    for case, want_rc, want in CASES:
        rc, out = run(case)
        ok = (rc == want_rc)
        if want is None:
            ok = ok and ("FAIL" not in out)
            why = "no FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {case:<8} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(case)
            print(out.rstrip())
    if fails:
        print(f"VPREC selftest: FAIL ({', '.join(fails)})")
        return 1
    print("VPREC selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
