#!/usr/bin/env python3
# Self-test for forks_ini_check.py (focus: the #6 slug-collision guard).
# Pure Python. Fixtures: test/fixtures/forks_ini/*.ini. Locks in:
#   * distinct slugs                          -> ok    exit 0
#   * two SYNCING sections, same slug         -> FAIL  exit 1
#   * same slug but filtered (Hook-3 skip)    -> ok    exit 0 (ZERO-FP mirror)
#   * two UNSTABLE sections, same slug        -> FAIL  exit 1 (no filter skip)
#
#   python3 test/lib/test_forks_ini_check.py  # -> "FORKSINI selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "forks_ini_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "forks_ini")

# (ini, expected_exit, must_contain)
CASES = [
    ("clean.ini",              0, "slugs clean"),
    ("collision.ini",          1, "slug collision `foobar`"),
    ("filtered_ok.ini",        0, "slugs clean"),
    ("unstable_collision.ini", 1, "UNSTABLE_FORKS: slug collision"),
    ("clean.ini",              0, None),     # regression guard: no FAIL
    ("filtered_ok.ini",        0, None),     # zero-FP guard: no FAIL
]


def run(ini):
    p = subprocess.run(
        [sys.executable, CHECK, os.path.join(FIX, ini)],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []
    for ini, want_rc, want in CASES:
        rc, out = run(ini)
        ok = (rc == want_rc)
        if want is None:
            ok = ok and ("FAIL" not in out)
            why = "no FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {ini:<24} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(ini)
            print(out.rstrip())
    if fails:
        print(f"FORKSINI selftest: FAIL ({', '.join(fails)})")
        return 1
    print("FORKSINI selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
