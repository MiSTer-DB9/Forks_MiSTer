#!/usr/bin/env python3
# CONF_STR <-> joy_type/joy_2p status-bit alignment check.
#
# The fork's "UserIO Joystick" / "UserIO Players" OSD options write a status
# bit slice; <core>.sv decodes joy_type / joy_2p from a (possibly different)
# status slice. If the two drift apart the menu writes bits the decode never
# reads: the controller is silently dead, yet the core compiles clean and no
# existing check notices (check_status_collision = upstream encroachment;
# step6 #10 = hps_io width; #11 = Saturn order — none tie the fork's OWN
# CONF_STR to its OWN decode). This is the NES commit 7fc497b class: CONF_STR
# left at the legacy letter form `oUV` (= status[63:62]) while the decode read
# status[127:126].
#
# Decodes BOTH CONF_STR option spellings:
#   * bracket form  O[hi:lo] / O[b]      -> absolute bits
#   * legacy letter Oc / Occ / oc / occ  -> alphabet "0..9A..V" = bits 0..31,
#                                           lowercase 'o' adds the +32 page
#                                           (so `oUV` = status[63:62])
# and compares the bit SET against the decode wires
#   wire [1:0] joy_type[_raw] = status[HI:LO];
#   wire       joy_2p         = status[B];
#
# n/a for cores with no `joy_type[_raw]` wire (bespoke / pre-wrapper cores
# that gate joy_type inline), AND for cores with a decode wire but no
# `UserIO Joystick` CONF_STR option: Template-B/C computer cores (AtariST,
# Minimig-AGA, X68000-class) deliberately have no menu option — joy_type is
# mirrored into status[63:62] from Main_MiSTer's ext_ctrl, not written by the
# OSD. The 7fc497b regression is specifically an option that EXISTS but points
# at the wrong bits; FATAL is scoped to exactly that, keeping the zero-false-
# positive contract of the other FATAL-tier checks (snac/mt32/joydb).
#
# Usage:  confstr_joytype_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = aligned / n-a, 1 = FATAL misalignment, 2 = parse/layout.

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

FATAL = "FATAL"

# Legacy MiSTer status alphabet: 32 chars -> status bits 0..31. Uppercase 'O'
# option = this page; lowercase 'o' option = the same alphabet + 32 (bits
# 32..63). Bits >= 64 have no letter form (bracket only) — exactly why a
# joy_type at 127:126 can never be expressed as a letter, and why a leftover
# letter form is unambiguously a misalignment.
_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUV"

JOYTYPE_RE = re.compile(
    r"wire\s*\[\s*1\s*:\s*0\s*\]\s*joy_type(?:_raw)?\s*=\s*"
    r"status\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]")
JOY2P_RE = re.compile(
    r"wire\s+joy_2p\s*=\s*status\s*\[\s*(\d+)\s*\]")
CONFSTR_RE = re.compile(
    r"\bCONF_STR\w*\s*=\s*\{(.*?)\}\s*;", re.DOTALL)
QUOTED_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _opt_bits(spec):
    """Bits referenced by a CONF_STR option spec (the pre-first-comma field,
    e.g. `d4P2O[127:126]` or `d4P2oUV`). Returns a set of ints, or None if the
    spec carries no O/o status option."""
    # Bracket form: O[hi:lo] or O[b]. Take the LAST O[..]/o[..] so leading
    # conditional flags (d4/P2/H1/...) and any 'O' in earlier flags can't
    # shadow it (flags never use bracket syntax).
    brackets = re.findall(r"[Oo]\[\s*(\d+)\s*(?::\s*(\d+)\s*)?\]", spec)
    if brackets:
        hi_s, lo_s = brackets[-1]
        hi = int(hi_s)
        lo = int(lo_s) if lo_s else hi
        return set(range(min(hi, lo), max(hi, lo) + 1))
    # Legacy letter form: strip the conditional-display flags
    # (d/D/h/H/P followed by one digit), then the next char is the O/o option
    # type, followed by one or two alphabet chars.
    rest = re.sub(r"^(?:[dDhHP]\d)+", "", spec)
    ml = re.match(r"([Oo])([0-9A-V])([0-9A-V])?", rest)
    if not ml:
        return None
    base = 0 if ml.group(1) == "O" else 32
    a = base + _ALPHA.index(ml.group(2))
    if ml.group(3) is None:
        return {a}
    b = base + _ALPHA.index(ml.group(3))
    return set(range(min(a, b), max(a, b) + 1))


def _confstr_option(text, label):
    """Reconstruct the CONF_STR concatenation and return the option spec
    whose comma-field[1] matches `label` (case-insensitive, trimmed), or
    None if absent."""
    m = CONFSTR_RE.search(text)
    if not m:
        return None
    blob = "".join(QUOTED_RE.findall(m.group(1)))
    blob = blob.replace("\\t", "\t")
    for element in blob.split(";"):
        fields = element.split(",")
        if len(fields) >= 2 and fields[1].strip().lower() == label.lower():
            return fields[0].strip()
    return None


def analyze(core_sv):
    """Return (status, issues):
      status "nowire"  -> no joy_type decode wire (bespoke)            -> n/a
      status "noopt"   -> decode wire but no UserIO Joystick option
                          (ext_ctrl-mirror computer core)              -> n/a
      status "checked" -> option present; issues = FATAL list ([]=ok)
    Raises only OSError."""
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    jt = JOYTYPE_RE.search(text)
    if not jt:
        return "nowire", []
    hi, lo = int(jt.group(1)), int(jt.group(2))
    jt_bits = set(range(min(hi, lo), max(hi, lo) + 1))
    issues = []

    spec = _confstr_option(text, "UserIO Joystick")
    if spec is None:
        return "noopt", []
    bits = _opt_bits(spec)
    if bits is None:
        issues.append((
            FATAL,
            f"`UserIO Joystick` spec `{spec}` has no O/o status option"))
    elif bits != jt_bits:
        issues.append((
            FATAL,
            f"`UserIO Joystick` writes status{sorted(bits)} but the "
            f"decode reads joy_type from status[{hi}:{lo}] "
            f"({sorted(jt_bits)}) — menu writes bits the decode never "
            f"reads (NES 7fc497b class); align the CONF_STR option to "
            f"`O[{hi}:{lo}]`"))

    j2 = JOY2P_RE.search(text)
    if j2:
        b = int(j2.group(1))
        pspec = _confstr_option(text, "UserIO Players")
        if pspec is not None:
            pbits = _opt_bits(pspec)
            if pbits is not None and pbits != {b}:
                issues.append((
                    FATAL,
                    f"`UserIO Players` writes status{sorted(pbits)} but "
                    f"joy_2p is decoded from status[{b}] — align to "
                    f"`O[{b}]`"))
    return "checked", issues


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: confstr_joytype_check.py <core_dir> "
              "[<core_sv_basename>]", file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2]:
        core_sv = os.path.join(core_dir, argv[2])
        if not os.path.isfile(core_sv):
            core_sv = find_core_sv(core_dir)
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  confstr-coresv: {os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  confstr: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        status, issues = analyze(core_sv)
    except OSError as e:
        print(f"  confstr: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    if status == "nowire":
        print(f"  confstr: n/a  no joy_type[_raw] decode wire  [{cb}]")
        return 0
    if status == "noopt":
        print(f"  confstr: n/a  decode wire but no `UserIO Joystick` "
              f"CONF_STR option (ext_ctrl-mirror computer core)  [{cb}]")
        return 0
    fatal = [msg for sev, msg in issues if sev == FATAL]
    for msg in fatal:
        print(f"  confstr: FAIL {msg}")
    if fatal:
        return 1
    print(f"  confstr: ok   CONF_STR aligned with joy_type/joy_2p  [{cb}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
