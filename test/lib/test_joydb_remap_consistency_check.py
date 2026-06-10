#!/usr/bin/env python3
# Self-test for joydb_remap_consistency_check.py. Pure Python, no iverilog / no
# core repos — fixtures are synthesised into a tmpdir (NOT committed). Locks in
# the instantiation-driven semantics that keep Menu green while catching the
# 00f49da -> af3471d Error-12006 class:
#   * joydb wrapper instance + joydb.sv has joydb_remap + REGISTERED  -> PASS  0
#   * joydb wrapper instance + joydb.sv has joydb_remap + UNregistered-> FATAL 1
#   * NO joydb wrapper instance (Menu) + unregistered joydb_remap     -> n/a   0
#   * joydb wrapper instance + pre-remap joydb.sv (no joydb_remap)    -> n/a   0
#   * no <core>.sv at all                                             -> n/a   2
#
#   python3 test/lib/test_joydb_remap_consistency_check.py  # "REMAPREG selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "joydb_remap_consistency_check.py")

WRAPPER = "  joydb joydb (\n    .clk ( clk )\n  );\n"
JOYDB_WITH_REMAP = (
    "module joydb(input clk);\n"
    "joydb_remap joydb_remap_i (\n  .clk_sys(clk)\n);\n"
    "endmodule\n"
)
JOYDB_NO_REMAP = "module joydb(input clk);\nendmodule\n"
QIP_REG = (
    "set_global_assignment -name SYSTEMVERILOG_FILE  "
    "[file join $::quartus(qip_path) joydb.sv ]\n"
    "set_global_assignment -name SYSTEMVERILOG_FILE  "
    "[file join $::quartus(qip_path) joydb_remap.sv ]\n"
)
QIP_NO_REG = (
    "set_global_assignment -name SYSTEMVERILOG_FILE  "
    "[file join $::quartus(qip_path) joydb.sv ]\n"
)
# A commented-out registration (Tcl `#`) — Quartus never compiles it, so this
# must read as UNregistered (a merge/rerere revert that comments out rather than
# deletes the line is the same Error-12006 escape).
QIP_COMMENTED_REG = (
    "set_global_assignment -name SYSTEMVERILOG_FILE  "
    "[file join $::quartus(qip_path) joydb.sv ]\n"
    "# set_global_assignment -name SYSTEMVERILOG_FILE  "
    "[file join $::quartus(qip_path) joydb_remap.sv ]\n"
)


def write_case(root, name, *, core_has_wrapper, joydb_has_remap, registered,
               with_core_sv=True, qip_override=None):
    d = os.path.join(root, name, "Core_MiSTer")
    os.makedirs(os.path.join(d, "sys"), exist_ok=True)
    if with_core_sv:
        body = WRAPPER if core_has_wrapper else "  // no wrapper\n"
        with open(os.path.join(d, "core.sv"), "w") as f:
            f.write("module emu(input clk);\n" + body + "endmodule\n")
    with open(os.path.join(d, "sys", "joydb.sv"), "w") as f:
        f.write(JOYDB_WITH_REMAP if joydb_has_remap else JOYDB_NO_REMAP)
    with open(os.path.join(d, "sys", "sys.qip"), "w") as f:
        f.write(qip_override if qip_override is not None
                else (QIP_REG if registered else QIP_NO_REG))
    return d


def run(case_dir):
    p = subprocess.run(
        [sys.executable, CHECK, case_dir, "core.sv"],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    # (name, kwargs, want_rc, must_contain | None)
    cases = [
        ("registered",
         dict(core_has_wrapper=True, joydb_has_remap=True, registered=True),
         0, "PASS"),
        ("unregistered",
         dict(core_has_wrapper=True, joydb_has_remap=True, registered=False),
         1, "Error 12006"),
        ("menu_no_wrapper",
         dict(core_has_wrapper=False, joydb_has_remap=True, registered=False),
         0, "no joydb wrapper instance"),
        ("pre_remap_joydb",
         dict(core_has_wrapper=True, joydb_has_remap=False, registered=False),
         0, "does not instantiate joydb_remap"),
        ("no_core_sv",
         dict(core_has_wrapper=True, joydb_has_remap=True, registered=False,
              with_core_sv=False),
         2, "no <core>.sv"),
        # commented-out registration is NOT a real registration -> FATAL.
        ("commented_out_reg",
         dict(core_has_wrapper=True, joydb_has_remap=True, registered=False,
              qip_override=QIP_COMMENTED_REG),
         1, "Error 12006"),
        # regression guard: the registered (correct) case never emits FAIL.
        ("registered2",
         dict(core_has_wrapper=True, joydb_has_remap=True, registered=True),
         0, None),
    ]

    fails = []
    with tempfile.TemporaryDirectory(prefix="rrtest.") as root:
        for name, kw, want_rc, want in cases:
            d = write_case(root, name, **kw)
            rc, out = run(d)
            ok = (rc == want_rc)
            if want is None:
                ok = ok and ("FAIL" not in out)
                why = "no FAIL line"
            else:
                ok = ok and (want in out)
                why = repr(want)
            tag = "ok  " if ok else "FAIL"
            print(f"  {tag} {name:<16} rc={rc} (want {want_rc}, {why})")
            if not ok:
                fails.append(name)
                print(out.rstrip())

    if fails:
        print(f"REMAPREG selftest: FAIL ({', '.join(fails)})")
        return 1
    print("REMAPREG selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
