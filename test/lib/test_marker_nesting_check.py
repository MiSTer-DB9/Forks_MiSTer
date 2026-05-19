#!/usr/bin/env python3
# Self-test for marker_nesting_check.py. Pure Python, no iverilog / no core
# repos. Fixtures: test/fixtures/marker_nesting/<case>/Core_MiSTer/core.sv.
# Locks in:
#   * balanced + correctly nested      -> PASS  exit 0
#   * orphan END (no open BEGIN)        -> FATAL exit 1 (SNES dc15e64 class)
#   * wrong-family close (mis-nest)     -> FATAL exit 1 (counts still equal)
#   * unclosed BEGIN at EOF             -> FATAL exit 1 (severed block)
#   * zero markers (pristine upstream)  -> n/a   exit 0 (no false positive)
#
#   python3 test/lib/test_marker_nesting_check.py  # "MARKERNEST selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "marker_nesting_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "marker_nesting")

# (case, expected_exit, must_contain)
CASES = [
    ("ok",         0, "balanced + nested"),
    ("orphan_end", 1, "orphan"),
    ("misnest",    1, "close inner before outer"),
    ("unclosed",   1, "never closed"),
    ("none",       0, "no fork markers"),
    # regression guard: clean cases must never emit a FAIL line.
    ("ok",         0, None),
    ("none",       0, None),
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
            ok = ok and ("FAIL" not in out)
            why = "no FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {case:<12} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(case)
            print(out.rstrip())
    if fails:
        print(f"MARKERNEST selftest: FAIL ({', '.join(fails)})")
        return 1
    print("MARKERNEST selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
