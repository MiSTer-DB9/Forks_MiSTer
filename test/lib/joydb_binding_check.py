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
    cb = os.path.basename(core_sv) if core_sv else ""
    print(f"  joydb-bind-coresv: {cb}")
    if not core_sv:
        print(f"  joydb-bind: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        text = strip_comments(open(core_sv, "r", errors="replace").read())
    except OSError as e:
        print(f"  joydb-bind: FAIL parse error ({e})")
        return 2

    bound = bound_ports(text)
    if bound is None:
        # No `joydb joydb` instance -> bespoke / non-ported / pristine
        # upstream. No canonical lookup needed; no FP path.
        print(f"  joydb-bind: n/a  no joydb wrapper (bespoke / non-ported / "
              f"pristine upstream)  [{cb}]")
        return 0

    req = required_ports(core_dir)
    if len(req) < 2:
        print(f"  joydb-bind: FAIL canonical joydb.sv unparsable (tried "
              f"{CANON_UMBRELLA} and {core_dir}/sys/joydb.sv)")
        return 2

    missing = [p for p in req if p not in bound]
    if missing:
        print(f"  joydb-bind: FAIL unbound canonical joydb port(s): "
              f"{', '.join(missing)} -- controller path silently dead  "
              f"[{cb}]")
        return 1
    print(f"  joydb-bind: PASS  all {len(req)} canonical joydb ports bound  "
          f"[{cb}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
