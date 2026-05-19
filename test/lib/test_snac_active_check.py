#!/usr/bin/env python3
# Self-test for snac_active_check.py. Pure Python, no iverilog / no core
# repos. Fixtures are core-named dirs (the check keys the SNAC table on the
# core dir basename), so each fixture lives at
# test/fixtures/snac_active/<case>/<Core>_MiSTer/<x>.sv. Locks in:
#   * a tabled SNAC core reset to 1'b0 -> FATAL exit 1
#   * a tabled SNAC core with its expr -> ok exit 0
#   * a non-tabled core at default     -> n/a exit 0  (no false positive)
#   * a non-tabled core non-default    -> FINDING exit 0 (review, not FATAL)
#
#   python3 test/lib/test_snac_active_check.py  # -> "SNAC selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "snac_active_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "snac_active")

# (relpath_to_core_dir, core_sv_basename, expected_exit, must_contain)
CASES = [
    ("ok_snac/NES_MiSTer",            "nes.sv", 0, "SNAC core, snac_active"),
    ("bad_snac/NES_MiSTer",           "nes.sv", 1, "inert default"),
    ("missing_snac/Genesis_MiSTer",   "g.sv",   1, "has no `wire snac_active"),
    ("nonsnac_default/Foo_MiSTer",    "foo.sv", 0, "non-SNAC core"),
    ("nonsnac_missing/Baz_MiSTer",    "baz.sv", 0, "no snac gate"),
    ("nonsnac_nondefault/Bar_MiSTer", "bar.sv", 0, "not in the SNAC table"),
    # regression guard: a non-SNAC core (line absent) must never FAIL.
    ("nonsnac_missing/Baz_MiSTer",    "baz.sv", 0, None),
]


def run(coredir, sv):
    p = subprocess.run(
        [sys.executable, CHECK, os.path.join(FIX, coredir), sv],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []
    for coredir, sv, want_rc, want in CASES:
        rc, out = run(coredir, sv)
        ok = (rc == want_rc)
        if want is None:
            ok = ok and ("FAIL" not in out)
            why = "no FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {coredir:<30} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(coredir)
            print(out.rstrip())
    if fails:
        print(f"SNAC selftest: FAIL ({', '.join(fails)})")
        return 1
    print("SNAC selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
