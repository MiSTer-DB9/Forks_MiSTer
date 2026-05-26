#!/usr/bin/env python3
# Self-test for status_feedback_check.py. Pure Python, no iverilog / no
# core repos. Each fixture lives at
# test/fixtures/status_feedback/<case>/<Core>_MiSTer/<x>.sv. Locks in:
#   * truncated `.status_in({status[63:8],...})`  -> FATAL exit 1
#   * widened   `.status_in({status[127:8],...})` -> PASS  exit 0
#   * no joy_type wrapper at all                  -> n/a   exit 2
#   * joy_type present, no .status_in port        -> n/a   exit 2
#   * .status_in(status) pass-through             -> PASS  exit 0
#   * pre-PSX 2-bit joy_type form truncated       -> FATAL exit 1
#   * multi-line truncated concat                 -> FATAL exit 1
#
#   python3 test/lib/test_status_feedback_check.py
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "status_feedback_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "status_feedback")

# (relpath_to_core_dir, core_sv_basename, expected_exit, must_contain)
CASES = [
    ("truncated/Genesis_MiSTer",            "genesis.sv",   1, "truncates status feedback"),
    ("widened/MegaDrive_MiSTer",            "megadrive.sv", 0, "preserves status[127:..]"),
    ("no_joytype/Foo_MiSTer",               "foo.sv",       2, "no joy_type wrapper"),
    ("no_statusin/Bar_MiSTer",              "bar.sv",       2, "no `.status_in("),
    ("passthrough/Baz_MiSTer",              "baz.sv",       0, "preserves status[127:..]"),
    ("pre_psx_truncated/Qux_MiSTer",        "qux.sv",       1, "truncates status feedback"),
    ("multiline_truncated/Quux_MiSTer",     "quux.sv",      1, "truncates status feedback"),
    # regression guard: widened core must never emit a FAIL line.
    ("widened/MegaDrive_MiSTer",            "megadrive.sv", 0, None),
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
        print(f"  {tag} {coredir:<38} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(coredir)
            print(out.rstrip())
    if fails:
        print(f"statusfb selftest: FAIL ({', '.join(fails)})")
        return 1
    print("statusfb selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
