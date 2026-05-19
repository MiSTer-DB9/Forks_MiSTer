#!/usr/bin/env python3
# Self-test for confstr_joytype_check.py. Pure Python, no iverilog / no core
# repos. Fixtures live at
# test/fixtures/confstr_joytype/<case>/<Core>_MiSTer/<x>.sv. Locks in:
#   * bracket form aligned                  -> ok    exit 0
#   * legacy letter `oUV` vs status[127:126]-> FATAL exit 1 (NES 7fc497b)
#   * UserIO Players bit mismatch           -> FATAL exit 1
#   * decode wire but no UserIO option      -> n/a   exit 0 (computer core,
#                                              NO false positive)
#   * no joy_type decode wire               -> n/a   exit 0
#   * matched legacy uppercase letter form  -> ok    exit 0
#
#   python3 test/lib/test_confstr_joytype_check.py  # -> "CONFSTR selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "confstr_joytype_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "confstr_joytype")

# (relpath_to_core_dir, core_sv_basename, expected_exit, must_contain)
CASES = [
    ("ok_bracket/NES_MiSTer",    "nes.sv", 0, "aligned with joy_type/joy_2p"),
    ("bad_joytype/NES_MiSTer",   "nes.sv", 1, "7fc497b class"),
    ("bad_players/NES_MiSTer",   "nes.sv", 1, "UserIO Players` writes"),
    ("noopt/AtariST_MiSTer",     "at.sv",  0, "ext_ctrl-mirror computer core"),
    ("nowire/Foo_MiSTer",        "foo.sv", 0, "no joy_type[_raw] decode wire"),
    ("legacy_ok/Bar_MiSTer",     "bar.sv", 0, "aligned with joy_type/joy_2p"),
    # regression guard: a clean core must never emit a FAIL line.
    ("ok_bracket/NES_MiSTer",    "nes.sv", 0, None),
    ("noopt/AtariST_MiSTer",     "at.sv",  0, None),
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
        print(f"  {tag} {coredir:<28} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(coredir)
            print(out.rstrip())
    if fails:
        print(f"CONFSTR selftest: FAIL ({', '.join(fails)})")
        return 1
    print("CONFSTR selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
