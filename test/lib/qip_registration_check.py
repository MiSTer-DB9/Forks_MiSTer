#!/usr/bin/env python3
# Canonical fork sys/*.{v,sv} <-> sys.qip/sys.tcl registration audit.
#
# Quartus compiles ONLY files listed via `set_global_assignment -name
# (SYSTEM)VERILOG_FILE ...` in sys.qip / sys.tcl. A canonical fork source
# physically present in sys/ but NOT registered is SILENTLY skipped: either
# an undefined-module synth error 15 min into the build, or — worse — the
# feature just vanishes from the RBF with a clean compile. Nothing else
# checks this; the live defect that motivated it is InputTest_MiSTer +
# Menu_MiSTer, which ship sys/siphash24.v + sys/db9_key_gate.sv unregistered
# (PSX_MiSTer/sys/sys.qip:35-40 is the correct shape).
#
# Audited set = the canonical COMPILED fork HDL (same list run_tier0.sh
# cmp-checks), minus db9_key_secret.vh which is a `\`include` header (like
# build_id.v) and is never a qip-registered compilation unit.
#
# FATAL (exit 1):
#   * a canonical file present in sys/ with no VERILOG_FILE/SYSTEMVERILOG_FILE
#     registration in sys.qip OR sys.tcl (the silent-skip defect)
#   * a dangling registration: a canonical basename registered but the file
#     absent from sys/ (merge/port left a stale entry -> missing-file build)
# n/a (exit 0): the core carries none of the canonical files (pristine /
#   upstream-only — never true post-port, keeps the check fail-safe).
# parse  (exit 2): neither sys.qip nor sys.tcl exists (layout; fail-open,
#   consistent with the python checks' parse-error tier in merge_validate).
#
# Usage:  qip_registration_check.py <core_dir>
# Exit:   0 = registered / n-a, 1 = FATAL, 2 = parse/layout.

import os
import re
import sys

# Canonical COMPILED fork sources. db9_key_secret.vh deliberately excluded
# (`\`include`d by hps_io.sv, not a compilation unit). joydb9saturn.v /
# db9_key_gate.sv / siphash24.v are the key-gate trio whose absence from
# sys.qip is the InputTest/Menu defect.
CANON = (
    "joydb9md.v", "joydb15.v", "joydb9saturn.v", "joydb.sv",
    "siphash24.v", "db9_key_gate.sv",
)

# `set_global_assignment -name VERILOG_FILE [file join ... joydb15.v ]`
# (or SYSTEMVERILOG_FILE). The basename is matched as a whole path token so
# `joydb15.v` cannot shadow a hypothetical `xjoydb15.v`.
_REG_RE = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEM)?VERILOG_FILE\b")


def _registered_basenames(path):
    """Set of canonical basenames that have a VERILOG_FILE/SYSTEMVERILOG_FILE
    registration line in `path` (missing file -> empty set)."""
    found = set()
    try:
        text = open(path, "r", errors="replace").read()
    except OSError:
        return found
    for line in text.splitlines():
        if not _REG_RE.search(line):
            continue
        for b in CANON:
            # basename bounded by a non-filename char on both sides (path
            # separator / space / bracket), so substrings can't false-match.
            if re.search(r"(?:^|[ \t/\"'])" + re.escape(b) + r"(?:$|[ \t\]\"'])",
                         line):
                found.add(b)
    return found


def analyze(core_dir):
    """Return (status, issues):
      "noqip"  -> neither sys.qip nor sys.tcl (parse/layout)  -> exit 2
      "none"   -> no canonical file present                   -> n/a, exit 0
      "checked"-> issues = FATAL list ([] = ok)               -> exit 0/1
    """
    sysd = os.path.join(core_dir, "sys")
    qip = os.path.join(sysd, "sys.qip")
    tcl = os.path.join(sysd, "sys.tcl")
    if not os.path.isfile(qip) and not os.path.isfile(tcl):
        return "noqip", []

    present = [b for b in CANON if os.path.isfile(os.path.join(sysd, b))]
    registered = set()
    for p in (qip, tcl):
        if os.path.isfile(p):
            registered |= _registered_basenames(p)

    if not present and not (registered & set(CANON)):
        return "none", []

    issues = []
    for b in present:
        if b not in registered:
            issues.append(
                f"{b} present in sys/ but NOT registered in sys.qip/sys.tcl "
                f"(Quartus will silently skip it)")
    present_set = set(present)
    for b in sorted(registered):
        if b not in present_set:
            issues.append(
                f"{b} registered in sys.qip/sys.tcl but file absent from "
                f"sys/ (dangling entry -> missing-file build break)")
    return "checked", issues


def main(argv):
    if len(argv) != 2:
        print("usage: qip_registration_check.py <core_dir>", file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if not os.path.isdir(core_dir):
        print(f"  qipreg: FAIL core dir not found: {core_dir}")
        return 2

    status, issues = analyze(core_dir)
    if status == "noqip":
        print(f"  qipreg: n/a  no sys.qip or sys.tcl in {core_dir}/sys "
              f"(fail-open)")
        return 2
    if status == "none":
        print(f"  qipreg: n/a  no canonical fork sys/* (pristine/upstream)")
        return 0
    for msg in issues:
        print(f"  qipreg: FAIL {msg}")
    if issues:
        return 1
    print(f"  qipreg: ok   all canonical sys/* registered in sys.qip/sys.tcl")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
