#!/usr/bin/env python3
# Self-test for joydb_semantic_check.py. Pure Python, no iverilog / no core
# repos -- synthesizes minimal <core>.sv fixtures (a `module emu (...)` stub
# plus a hand-built joystick mux) into temp dirs whose names drive the
# arcade-vs-console branch, then asserts exit code + a signature substring.
#
#   python3 test/lib/test_joydb_semantic_check.py
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "joydb_semantic_check.py")

EMU = "module emu (input clk);\nendmodule\n"


def conf(j):
    return f'localparam CONF_STR = {{"CORE;","{j}"}};\n' if j else ""


def mux(p1, p2=None):
    s = (f"wire [31:0] joystick_0 = joydb_1ena ? (OSD_STATUS ? 32'b0 : "
         f"{{{p1}}}) : joystick_0_USB;\n")
    if p2 is not None:
        s += (f"wire [31:0] joystick_1 = joydb_2ena ? (OSD_STATUS ? 32'b0 : "
              f"{{{p2}}}) : joystick_1_USB;\n")
    return s


# (case, core_dir_name, sv_body, expected_exit, must_contain / None)
# Exit contract: only FATAL (P1/P2 role transpose) gates -> exit 1.
# WARN/INFO are advisory -> exit 0 (but the WARN line must still appear).
CASES = [
    # Canonical arcade arm, P1==P2 order -> clean.
    ("arcade-canonical", "Arcade-Foo_MiSTer",
     conf("J1,Fire,Start,Coin;") +
     mux("joydb_1[11],joydb_1[9],joydb_1[10],joydb_1[4:0]",
         "joydb_2[11],joydb_2[9],joydb_2[10],joydb_2[4:0]"),
     0, "joydbsem: ok"),

    # --- FATAL tier (gates) ---
    # ComputerSpace class: same bit-set, transposed [9]<->[10], role bit
    # [10] at mismatched position, single shared Start in CONF_STR.
    ("fatal-transpose", "Arcade-Cspace_MiSTer",
     conf("J1,Thrust,Fire,Start,Coin;") +
     mux("joydb_1[9],joydb_1[10],joydb_1[5:0]",
         "joydb_2[10],joydb_2[9],joydb_2[5:0]"),
     1, "P1/P2 role transpose"),
    # Identical mechanics but CONF_STR routes Start per player
    # (Start 1P/2P) -> legit fleet-wide arcade convention -> NOT fatal.
    ("legit-perplayer-swap", "Arcade-Galaga2_MiSTer",
     conf("J1,Fire,Start 1P,Start 2P,Coin,Pause;") +
     mux("joydb_1[11],joydb_1[9],joydb_1[10],joydb_1[4:0]",
         "joydb_2[11],joydb_2[10],joydb_2[9],joydb_2[4:0]"),
     0, "joydbsem: ok"),

    # --- WARN tier (advisory, exit 0) ---
    # Arcade fire starting at B[5], A[4] absent -> WARN, exit 0.
    ("arcade-no-A", "Arcade-Bar_MiSTer",
     conf("J1,Fire,Start,Coin;") +
     mux("joydb_1[11],joydb_1[10],joydb_1[5],joydb_1[3:0]"),
     0, "fire does not start at A"),
    # CONF_STR declares Start but joydb[10] absent -> WARN, exit 0.
    ("start-declared-missing", "Arcade-Baz_MiSTer",
     conf("J1,Fire,Start,Coin;") +
     mux("joydb_1[11],joydb_1[9],joydb_1[4:0]"),
     0, "declares a Start button but joydb_1[10]"),
    # CONF_STR has NO Start (computer core) -> clean (no false flag).
    ("no-start-button", "C64_MiSTer",
     conf("J1,Fire,Fire2;") +
     mux("joydb_1[5],joydb_1[4],joydb_1[3:0]"),
     0, "joydbsem: ok"),
    # Console core, fire remapped to B/C (NES), Start+Select present.
    ("console-remap", "NES_MiSTer",
     conf("J1,A,B,Select,Start;") +
     mux("joydb_1[10],joydb_1[11],joydb_1[5],joydb_1[6],joydb_1[3:0]"),
     0, "joydbsem: ok"),
    # CONF_STR declares Select but joydb[11] absent -> WARN, exit 0.
    ("select-declared-missing", "SMS_MiSTer",
     conf("J1,Fire,Start,Select;") +
     mux("joydb_1[10],joydb_1[5],joydb_1[4],joydb_1[3:0]"),
     0, "declares Select/Mode/Coin but joydb_1[11]"),
    # Different bit-SET (P2 lacks [10]) -> WARN role divergence (NOT a
    # transpose: sets differ), exit 0.
    ("p1p2-divergence", "Arcade-Qux_MiSTer",
     conf("J1,Fire,Start,Coin;") +
     mux("joydb_1[11],joydb_1[9],joydb_1[10],joydb_1[4:0]",
         "joydb_2[11],joydb_2[9],joydb_2[4:0]"),
     0, "role divergence"),
]


def run(core_dir, sv):
    rc = subprocess.run([sys.executable, CHECK, core_dir, sv],
                        capture_output=True, text=True)
    return rc.returncode, rc.stdout + rc.stderr


def main():
    fails = []
    with tempfile.TemporaryDirectory() as td:
        for name, dname, body, want_rc, want in CASES:
            cdir = os.path.join(td, dname)
            os.makedirs(cdir, exist_ok=True)
            svname = dname.split("_")[0] + ".sv"
            with open(os.path.join(cdir, svname), "w") as fh:
                fh.write(EMU + body)
            rc, out = run(cdir, svname)
            ok = (rc == want_rc) and (want is None or want in out)
            tag = "ok  " if ok else "FAIL"
            print(f"  {tag} {name:<18} rc={rc} (want {want_rc}, {want!r})")
            if not ok:
                fails.append(name)
                print(out.rstrip())
    if fails:
        print(f"JOYDBSEM selftest: FAIL ({', '.join(fails)})")
        return 1
    print("JOYDBSEM selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
