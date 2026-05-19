#!/usr/bin/env python3
# Self-test for qip_registration_check.py. Pure Python, no core repos.
# Fixtures: test/fixtures/qip_registration/<case>/Core_MiSTer/sys/...
# Locks in:
#   * file present + registered            -> ok    exit 0
#   * file present, sys.qip omits it       -> FATAL exit 1 (InputTest/Menu)
#   * registered but file absent           -> FATAL exit 1 (dangling)
#   * sys.qip present, no canonical files  -> n/a   exit 0
#   * canonical file, no sys.qip/sys.tcl   -> parse exit 2 (fail-open)
#
#   python3 test/lib/test_qip_registration_check.py  # -> "QIPREG selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "qip_registration_check.py")
FIX = os.path.join(HERE, "..", "fixtures", "qip_registration")

# (case_dir, expected_exit, must_contain | None=assert no FAIL line)
CASES = [
    ("ok/Core_MiSTer",           0, "all canonical sys/* registered"),
    ("unregistered/Core_MiSTer", 1, "NOT registered in sys.qip/sys.tcl"),
    ("dangling/Core_MiSTer",     1, "dangling entry"),
    ("none/Core_MiSTer",         0, "no canonical fork sys/*"),
    ("noqip/Core_MiSTer",        2, "no sys.qip or sys.tcl"),
    ("ok/Core_MiSTer",           0, None),
    ("none/Core_MiSTer",         0, None),
]


def run(coredir):
    p = subprocess.run(
        [sys.executable, CHECK, os.path.join(FIX, coredir)],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []
    for coredir, want_rc, want in CASES:
        rc, out = run(coredir)
        ok = (rc == want_rc)
        if want is None:
            ok = ok and ("FAIL" not in out)
            why = "no FAIL line"
        else:
            ok = ok and (want in out)
            why = repr(want)
        tag = "ok  " if ok else "FAIL"
        print(f"  {tag} {coredir:<24} rc={rc} (want {want_rc}, {why})")
        if not ok:
            fails.append(coredir)
            print(out.rstrip())
    if fails:
        print(f"QIPREG selftest: FAIL ({', '.join(fails)})")
        return 1
    print("QIPREG selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
