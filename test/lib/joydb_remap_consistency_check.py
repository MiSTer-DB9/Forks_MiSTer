#!/usr/bin/env python3
# joydb_remap registration-consistency guard (Quartus Error 12006 class).
#
# The canonical joydb wrapper (fork_ci_template/sys/joydb.sv) instantiates the
# `joydb_remap` programmable-remap matrix UNCONDITIONALLY. joydb_remap lives in
# its own sys/joydb_remap.sv, which Quartus compiles ONLY if it is registered
# via `set_global_assignment -name (SYSTEM)VERILOG_FILE ...` in sys.qip/sys.tcl.
#
# Quartus raises Error 12006 ("instantiates undefined entity") only for an
# instance that is actually ELABORATED, i.e. reachable from the top entity. So
# the registration is required IFF the core's top `<core>.sv` instantiates the
# `joydb` wrapper (which pulls joydb_remap into the elaborated hierarchy):
#   * Gameboy: Gameboy.sv instantiates `joydb joydb` -> joydb_remap elaborated
#     -> joydb_remap.sv MUST be registered, else Error 12006 (15 min into CI).
#   * Menu: menu.sv does NOT instantiate the joydb wrapper -> joydb.sv is a dead
#     compiled unit, joydb_remap is never elaborated -> builds fine WITHOUT the
#     registration (verified: Menu stable release stays green). MUST be n/a here.
#
# This is exactly the failure that 00f49da -> af3471d produced on Gameboy: an
# upstream merge reverted the sys.qip joydb_remap.sv registration (rerere stale
# canary), then the copy-only sys/ helper sync re-installed a joydb.sv that
# instantiates joydb_remap against a sys.qip that no longer registered it.
# qip_registration_check.py (token `qipreg`) does NOT catch this -- it is
# file-presence-driven and joydb_remap.sv is excluded from its CANON (adding it
# there would false-positive on Menu). This check is instantiation-driven, so it
# flags only cores where the missing registration actually breaks the build.
#
# FATAL (exit 1): `<core>.sv` instantiates the `joydb` wrapper AND the core's
#   sys/joydb.sv instantiates `joydb_remap` AND joydb_remap.sv is NOT registered
#   in sys.qip/sys.tcl.
# n/a   (exit 0): `<core>.sv` does not instantiate the `joydb` wrapper (Menu /
#   joydb-less / pristine), OR the core's joydb.sv does not instantiate
#   joydb_remap (pre-remap wrapper), OR joydb_remap.sv is registered (the
#   correct, consistent state).
# parse (exit 2, fail-open): no resolvable <core>.sv / parse error -- consistent
#   with the other python checks' parse tier in merge_validate / run_fleet_audit.
#
# Usage:  joydb_remap_consistency_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = consistent / n-a, 1 = FATAL, 2 = parse (fail-open).

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

# A module instantiation of joydb_remap, in either the plain form
# `joydb_remap <inst_name> (` or the parameterized form `joydb_remap #(...)`.
# A `#` immediately after the module name unambiguously marks a parameter
# override (the only Verilog construct that follows a type name with `#`), so we
# accept it without parsing the param list — which can itself nest parens, e.g.
# `#(.N(9))`. Either form distinguishes the instantiation from a qip
# registration line or a bare identifier, and keeps a future parameterized
# instantiation from being misread as a pre-remap (non-instantiating) wrapper.
_INST_RE = re.compile(r"\bjoydb_remap\s+(?:#|[A-Za-z_]\w*\s*\()")
# A (SYSTEM)VERILOG_FILE registration assignment. The basename match is applied
# separately in _joydb_remap_registered (bounded by a non-filename char on both
# sides so substrings can't match).
_REG_LINE_RE = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEM)?VERILOG_FILE\b")
_BASENAME = "joydb_remap.sv"


def _wrapper_instantiated(core_sv):
    """True iff <core>.sv instantiates the `joydb joydb` wrapper."""
    try:
        text = strip_comments(open(core_sv, "r", errors="replace").read())
    except OSError:
        return None
    return "joydb joydb" in text


def _joydb_remap_instantiated(core_dir):
    """True iff the core's sys/joydb.sv instantiates a joydb_remap module."""
    path = os.path.join(core_dir, "sys", "joydb.sv")
    try:
        text = strip_comments(open(path, "r", errors="replace").read())
    except OSError:
        return False
    return bool(_INST_RE.search(text))


def _joydb_remap_registered(core_dir):
    """True iff joydb_remap.sv has a (SYSTEM)VERILOG_FILE registration in
    sys.qip or sys.tcl."""
    sysd = os.path.join(core_dir, "sys")
    for name in ("sys.qip", "sys.tcl"):
        path = os.path.join(sysd, name)
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, "r", errors="replace").read()
        except OSError:
            continue
        for line in text.splitlines():
            # `#` at statement start is a Tcl/qip comment — Quartus never
            # compiles a commented-out registration, so a merge/rerere revert
            # that comments the line out (rather than deleting it) must NOT read
            # as registered, else the Error-12006 escape this guard exists to
            # catch sails through as a false PASS.
            if line.lstrip().startswith("#"):
                continue
            if not _REG_LINE_RE.search(line):
                continue
            if re.search(r"(?:^|[ \t/\"'])" + re.escape(_BASENAME) +
                         r"(?:$|[ \t\]\"'])", line):
                return True
    return False


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: joydb_remap_consistency_check.py <core_dir> "
              "[<core_sv_basename>]", file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2] and \
       os.path.isfile(os.path.join(core_dir, argv[2])):
        core_sv = os.path.join(core_dir, argv[2])
    else:
        core_sv = find_core_sv(core_dir)
    cb = os.path.basename(core_sv) if core_sv else ""
    if not core_sv:
        print(f"  remapreg: n/a  no <core>.sv declaring `module emu` in "
              f"{core_dir} (fail-open)")
        return 2

    inst = _wrapper_instantiated(core_sv)
    if inst is None:
        print(f"  remapreg: n/a  parse error reading {cb} (fail-open)")
        return 2
    if not inst:
        # No `joydb joydb` instance -> the wrapper (and its joydb_remap child)
        # is never elaborated, so joydb_remap.sv need not be registered. This is
        # the Menu / joydb-less / pristine case.
        print(f"  remapreg: n/a  no joydb wrapper instance (Menu / joydb-less "
              f"/ pristine)  [{cb}]")
        return 0

    if not _joydb_remap_instantiated(core_dir):
        # joydb wrapper present but its joydb.sv predates the remap matrix.
        print(f"  remapreg: n/a  joydb.sv does not instantiate joydb_remap "
              f"(pre-remap wrapper)  [{cb}]")
        return 0

    if not _joydb_remap_registered(core_dir):
        print(f"  remapreg: FAIL <core>.sv instantiates the joydb wrapper and "
              f"sys/joydb.sv instantiates joydb_remap, but joydb_remap.sv is "
              f"NOT registered in sys.qip/sys.tcl -- Quartus Error 12006 "
              f"(undefined entity)  [{cb}]")
        return 1

    print(f"  remapreg: PASS  joydb_remap.sv registered for the elaborated "
          f"joydb wrapper  [{cb}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
