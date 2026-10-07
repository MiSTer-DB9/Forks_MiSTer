#!/usr/bin/env python3
# joydb wrapper port-binding completeness guard.
#
# step6.sh only greps that the `joydb joydb` instance EXISTS;
# saturn_gate_check.py validates exactly ONE of its ports
# (.saturn_unlocked). Nothing verifies the instance binds EVERY port of the
# canonical joydb module. A merge / hand-edit that drops or typo-renames a
# named connection (.joy_raw / .joydb_2ena / .USER_OUT_DRIVE / ...) leaves
# that fork port unbound -> the controller path goes silently dead while the
# core still compiles clean and every other check stays green.
#
# Zero-FP BY CONSTRUCTION: the canonical
#   Forks_MiSTer/fork_ci_template/sys/joydb.sv
# module declaration is the single source of truth. The porter WRAPPER_BLOCK
# emits an instance binding exactly those ports; only a merge / hand-edit
# mangle removes one. A core with no `joydb joydb` instance (bespoke /
# non-ported / pristine upstream) is n/a -- there is no "legitimately
# missing port" case (unlike satgate's InputTest 1'b1 tie), so this GATES.
#
# EXCEPTION -- OPTIONAL_PORTS (below): two canonical ports are excused. They
# are ADVISORY OUTPUTS the WRAPPER_BLOCK deliberately does NOT emit (commit
# a79778f) -- an unconnected output is harmless in Verilog (no silently-dead
# path). The remap_default_* inputs are NOT excused: unbound, Quartus grounds
# them, every DB9 button slot reads NONE and DB15/DB9MD face buttons go dead
# on a stock MiSTer binary.
#
# Also FATAL: the hps_io `.joy_raw` bound to an `OSD_STATUS ? ...` ternary.
# Main_MiSTer needs DB9 button edges during gameplay for its idle timers
# (hdmi_off, CEC sleep) and reapplies the OSD gate itself, so a gated binding
# blanks the screen mid-play.
#
# Every .sv in the core dir (and rtl/, for jtframe `rtl/emu.sv` cores) that
# holds a `joydb joydb` instance is checked, so the second core of a
# multi-core repo (Atari800.sv next to Atari5200.sv) is covered too.
#
# Required-port set is parsed from the live canonical header, so it
# auto-tracks if a port is ever added/removed there.
#
# Usage:  joydb_binding_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = all bound / n-a; 1 = FATAL (>=1 canonical port unbound);
#         2 = parse / no <core>.sv / canonical unreadable (fail-open).

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

# Canonical joydb.sv. Two equally-valid locations: the umbrella source
# (Forks_MiSTer/fork_ci_template/sys/joydb.sv -- present when this check is
# invoked from run_fleet_audit.sh / run_tier0.sh) and the per-core
# materialised copy (<core_dir>/sys/joydb.sv -- present when invoked from
# merge_validate.sh inside a per-fork CI container, where fork_ci_template
# does NOT exist). canonical_drift_check.sh / Tier-0 guarantee the two are
# byte-identical, so the parsed port set is the same either way.
CANON_UMBRELLA = os.path.normpath(
    os.path.join(_HERE, "..", "..", "fork_ci_template", "sys", "joydb.sv"))

# `module joydb ( ... )` -- the port list has no inner parens (ranges use
# [hi:lo]), so the first ')' after the module keyword closes it.
_HDR_RE = re.compile(r"module\s+joydb\b[^)]*\)", re.S)
# Last identifier on an input/output port line (excludes , ( ) so a [hi:lo]
# range / type keyword is skipped; the trailing , or EOL anchors the name).
_PORT_RE = re.compile(
    r"^\s*(?:input|output)\b[^,()\n]*?\b([A-Za-z_]\w*)\s*(?:,|$)", re.M)
# A named-port connection `.ident(` inside the instance span.
_CONN_RE = re.compile(r"\.\s*([A-Za-z_]\w*)\s*\(")

# Outputs the canonical joydb module exposes as ADVISORY/optional --
# consumers (e.g. jtcps1/jtcps2 SF2 row-swap) bind them, others leave them
# unconnected (commit a79778f). Unlike an unbound INPUT (controller path goes
# silently dead), an unconnected OUTPUT is harmless in Verilog, so it must not
# FATAL the binding completeness guard.
OPTIONAL_OUTPUTS = {"pad_1_6btn", "pad_2_6btn"}
OPTIONAL_PORTS = OPTIONAL_OUTPUTS
_GATED_JOY_RAW_RE = re.compile(r"\.\s*joy_raw\s*\(\s*OSD_STATUS\s*\?")

# Layer B slice width. Main_MiSTer maps one DB9 button per declared label
# (CONF_STR J1/J, or the MRA <buttons names=...> on arcade cores) starting at
# bit 4, up to slot 12. A `joydb_N_mapped[H:0]` cut below that drops the top
# buttons (Start/Coin/Pause/Service) on a DB9 pad while the Define page still
# shows them mapped. Same rule as port_core_full.py mapped_top_bit().
_J_RE = re.compile(r'"J1?,([^"]*)"')
_MAPPED_RE = re.compile(r"joydb_[12]_mapped\[(\d+):0\]")
_MRA_BUTTONS_RE = re.compile(r'<buttons[^>]*\bnames="([^"]*)"')


def mapped_top_bit(text, core_dir):
    m = _J_RE.search(text)
    n = len(m.group(1).rstrip(";").split(",")) if m else 0
    for root, _, files in os.walk(os.path.join(core_dir, "releases")):
        for f in files:
            if f.endswith(".mra"):
                try:
                    s = open(os.path.join(root, f), errors="replace").read()
                except OSError:
                    continue
                for names in _MRA_BUTTONS_RE.findall(s):
                    n = max(n, len(names.split(",")))
    return min(12, 3 + n)


def required_ports(core_dir=None):
    """Canonical joydb module port names (order-preserved). [] = unparsable.
    Looks at the umbrella canonical first, falls back to <core_dir>/sys/joydb.sv
    (the per-core materialised copy; canonical_drift_check enforces equality)."""
    candidates = [CANON_UMBRELLA]
    if core_dir:
        candidates.append(os.path.join(core_dir, "sys", "joydb.sv"))
    for path in candidates:
        try:
            hdr = strip_comments(open(path, "r", errors="replace").read())
        except OSError:
            continue
        m = _HDR_RE.search(hdr)
        if not m:
            continue
        seen, out = set(), []
        for name in _PORT_RE.findall(m.group(0)):
            if name not in seen:
                seen.add(name)
                out.append(name)
        if out:
            return out
    return []


def bound_ports(text):
    """Named connections of the `joydb joydb (...)` instance, or None."""
    i = text.find("joydb joydb")
    if i < 0:
        return None
    o = text.find("(", i)
    if o < 0:
        return None
    depth, j, n = 0, o, len(text)
    while j < n:
        c = text[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    span = text[o:j + 1]
    return set(_CONN_RE.findall(span))


def joydb_svs(core_dir):
    """Every .sv under <core_dir> and <core_dir>/rtl with a joydb instance."""
    out = []
    for sub in ("", "rtl"):
        d = os.path.join(core_dir, sub)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for f in names:
            path = os.path.join(d, f)
            if not f.endswith(".sv") or not os.path.isfile(path):
                continue
            try:
                if "joydb joydb" in open(path, "r", errors="replace").read():
                    out.append(path)
            except OSError:
                pass
    return out


def check_sv(core_dir, core_sv, req):
    cb = os.path.relpath(core_sv, core_dir)
    try:
        text = strip_comments(open(core_sv, "r", errors="replace").read())
    except OSError as e:
        print(f"  joydb-bind: FAIL parse error ({e})  [{cb}]")
        return 2

    bound = bound_ports(text)
    if bound is None:
        # No `joydb joydb` instance -> bespoke / non-ported / pristine
        # upstream. No canonical lookup needed; no FP path.
        print(f"  joydb-bind: n/a  no joydb wrapper (bespoke / non-ported / "
              f"pristine upstream)  [{cb}]")
        return 0

    if len(req) < 2:
        print(f"  joydb-bind: FAIL canonical joydb.sv unparsable (tried "
              f"{CANON_UMBRELLA} and {core_dir}/sys/joydb.sv)")
        return 2

    rc = 0
    missing = [p for p in req if p not in bound and p not in OPTIONAL_PORTS]
    if missing:
        print(f"  joydb-bind: FAIL unbound canonical joydb port(s): "
              f"{', '.join(missing)} -- controller path silently dead  "
              f"[{cb}]")
        rc = 1
    if _GATED_JOY_RAW_RE.search(text):
        print(f"  joydb-bind: FAIL hps_io .joy_raw gated on OSD_STATUS -- "
              f"DB9 play cannot reset hdmi_off / CEC sleep; bind "
              f".joy_raw(joy_raw_payload)  [{cb}]")
        rc = 1
    his = [int(h) for h in _MAPPED_RE.findall(text)]
    if his:
        top = mapped_top_bit(text, core_dir)
        if min(his) < top:
            print(f"  joydb-bind: FAIL joydb_*_mapped[{min(his)}:0] narrower "
                  f"than the declared buttons; widen to [{top}:0]  [{cb}]")
            rc = 1
    if rc:
        return rc
    # Don't claim "all N bound" — an unbound OPTIONAL output passes the gate but
    # is genuinely unconnected, so report the real bound count and name the
    # skipped advisory ports.
    opt_unbound = [p for p in req if p in OPTIONAL_PORTS and p not in bound]
    if opt_unbound:
        print(f"  joydb-bind: PASS  {len(req) - len(opt_unbound)} of "
              f"{len(req)} canonical joydb ports bound; advisory output "
              f"port(s) left unbound (ok): {', '.join(opt_unbound)}  [{cb}]")
    else:
        print(f"  joydb-bind: PASS  all {len(req)} canonical joydb ports bound  "
              f"[{cb}]")
    return 0


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: joydb_binding_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2] and \
       os.path.isfile(os.path.join(core_dir, argv[2])):
        core_sv = os.path.join(core_dir, argv[2])
    else:
        core_sv = find_core_sv(core_dir)
    svs = ([core_sv] if core_sv else []) + \
        [p for p in joydb_svs(core_dir)
         if not core_sv or not os.path.samefile(p, core_sv)]
    print(f"  joydb-bind-coresv: "
          f"{' '.join(os.path.relpath(p, core_dir) for p in svs)}")
    if not svs:
        print(f"  joydb-bind: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    req = required_ports(core_dir)
    rcs = [check_sv(core_dir, p, req) for p in svs]
    return 1 if 1 in rcs else max(rcs)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
