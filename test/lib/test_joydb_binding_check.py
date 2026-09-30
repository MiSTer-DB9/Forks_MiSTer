#!/usr/bin/env python3
# Self-test for joydb_binding_check.py. Pure Python. Fixtures are SYNTHESISED
# from the live canonical joydb.sv port set at test time (into a tmpdir, NOT
# committed), so the selftest auto-tracks if a port is ever added/removed in
# Forks_MiSTer/fork_ci_template/sys/joydb.sv. Locks in:
#   * full instance (every canonical port bound)  -> PASS exit 0
#   * full instance minus one port (dropped .X(.)) -> FATAL exit 1, names X
#   * no `joydb joydb` instance (bespoke)          -> n/a  exit 0
#   * remap_default_db15 unbound                   -> FATAL exit 1
#   * hps_io `.joy_raw (OSD_STATUS ? ...)` gated   -> FATAL exit 1
#   * second emu .sv in the dir drops a port       -> FATAL exit 1
#
#   python3 test/lib/test_joydb_binding_check.py  # "JOYDBBIND selftest: PASS"
# Exit 0 = all cases pass, 1 = a case regressed.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "joydb_binding_check.py")

if HERE not in sys.path:
    sys.path.insert(0, HERE)
from joydb_binding_check import required_ports  # noqa: E402


def core_sv(instance):
    """Minimal <core>.sv declaring `module emu` (find_core_sv predicate)."""
    return (
        "module emu(input clk);\n"
        + instance
        + "endmodule\n"
    )


def full_instance(ports):
    lines = "\n".join(f"  .{p} ( {p} )," for p in ports)
    lines = lines.rstrip(",") + "\n"  # strip trailing comma on last port
    return "joydb joydb (\n" + lines + ");\n"


def missing_instance(ports, drop):
    return full_instance([p for p in ports if p != drop])


def na_instance():
    return "// bespoke core: no joydb wrapper\n"


def gated_instance(ports):
    hps = "hps_io hps_io (\n  .joy_raw   ( OSD_STATUS ? joy_raw_payload : 16'b0 )\n);\n"
    return full_instance(ports) + hps


def write_case(root, name, instance, second=None):
    d = os.path.join(root, name, "Core_MiSTer")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "core.sv"), "w") as f:
        f.write(core_sv(instance))
    if second is not None:
        with open(os.path.join(d, "second.sv"), "w") as f:
            f.write(core_sv(second))
    return d


def run(case_dir):
    p = subprocess.run(
        [sys.executable, CHECK, case_dir, "core.sv"],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    req = required_ports()
    if len(req) < 2:
        print("JOYDBBIND selftest: FAIL (canonical joydb.sv unparsable)")
        return 1
    drop = "joy_raw" if "joy_raw" in req else req[-1]

    cases = [
        ("ok",      full_instance(req),         0, "PASS", None),
        ("missing", missing_instance(req, drop), 1, drop, None),
        ("na",      na_instance(),              0, "n/a", None),
        ("remapdef", missing_instance(req, "remap_default_db15"), 1,
         "remap_default_db15", None),
        ("gated",   gated_instance(req),        1, "gated on OSD_STATUS", None),
        ("second",  full_instance(req),         1, "[second.sv]",
         missing_instance(req, drop)),
        # regression guard: ensure ok stays PASS (no spurious FAIL)
        ("ok2",     full_instance(req),         0, None, full_instance(req)),
    ]

    fails = []
    with tempfile.TemporaryDirectory(prefix="jbtest.") as root:
        for name, instance, want_rc, want, second in cases:
            d = write_case(root, name, instance, second)
            rc, out = run(d)
            ok = (rc == want_rc)
            if want is None:
                ok = ok and ("FAIL" not in out)
                why = "no FAIL line"
            else:
                ok = ok and (want in out)
                why = repr(want)
            tag = "ok  " if ok else "FAIL"
            print(f"  {tag} {name:<8} rc={rc} (want {want_rc}, {why})")
            if not ok:
                fails.append(name)
                print(out.rstrip())

    if fails:
        print(f"JOYDBBIND selftest: FAIL ({', '.join(fails)})")
        return 1
    print("JOYDBBIND selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
