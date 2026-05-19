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
# ALSO checks one CONF_STR defect independent of the joy_type decode (so it
# applies even on nowire/noopt cores): any option bit beyond the core's
# hps_io status width (the same width step6 #10 reads; the write is
# unobservable). Unambiguous, zero false positives. Intra-CONF_STR bit
# *overlap* was evaluated and intentionally NOT checked — see
# _structural_issues (shared bits are legitimately mode-arbitrated in HDL,
# so a static overlap rule cannot honour the zero-FP contract).
#
# Usage:  confstr_joytype_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = aligned / n-a, 1 = FATAL (misalign / over-width),
#         2 = parse/layout.

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


def _confstr_blob(text):
    """Reconstructed CONF_STR concatenation (quoted segments joined, \\t
    materialised), or None if there is no CONF_STR."""
    m = CONFSTR_RE.search(text)
    if not m:
        return None
    return "".join(QUOTED_RE.findall(m.group(1))).replace("\\t", "\t")


def _confstr_option(text, label):
    """Option spec (comma-field[0]) whose comma-field[1] matches `label`
    (case-insensitive, trimmed), or None if absent."""
    blob = _confstr_blob(text)
    if blob is None:
        return None
    for element in blob.split(";"):
        fields = element.split(",")
        if len(fields) >= 2 and fields[1].strip().lower() == label.lower():
            return fields[0].strip()
    return None


def _iter_options(text):
    """Yield (label, spec) for every CONF_STR element that has a label."""
    blob = _confstr_blob(text)
    if blob is None:
        return
    for element in blob.split(";"):
        fields = element.split(",")
        if len(fields) >= 2:
            yield fields[1].strip(), fields[0].strip()


_HPS_W_RE = re.compile(
    r"output\s+reg\s*\[\s*(31|63|127)\s*:\s*0\s*\]\s*status\b")


def _hps_width(core_dir):
    """hps_io status MSB (31/63/127) the way step6.sh reads it, or None if
    sys/hps_io.{sv,v} is absent/unparseable (caller treats None as fail-open,
    same as step6 #10's own behaviour)."""
    if not core_dir:
        return None
    for cand in ("sys/hps_io.sv", "sys/hps_io.v"):
        p = os.path.join(core_dir, cand)
        try:
            mm = _HPS_W_RE.search(open(p, "r", errors="replace").read())
        except OSError:
            continue
        if mm:
            return int(mm.group(1))
    return None


def _structural_issues(text, core_dir):
    """CONF_STR defect independent of the joy_type decode: any option bit
    beyond the core's hps_io status width (the same width step6 #10 reads) —
    a write the core can never observe. Unambiguous, zero false positives.

    Intra-CONF_STR bit *overlap* was evaluated and deliberately NOT checked:
    MiSTer cores intentionally bind one status bit to two options that are
    mutually exclusive by RUNTIME mode rather than by a CONF_STR D/H flag
    (e.g. Saturn `P2O[125]` is BOTH `UserIO Players` and `SNAC Players`,
    arbitrated in HDL by `snac_active`; upstream CDi reuses status[19]).
    Whether a shared bit is a defect is not statically decidable from
    CONF_STR alone, so an overlap rule cannot honour the zero-FP contract
    the other FATAL-tier checks hold — it is intentionally omitted."""
    issues = []
    max_bit = -1
    for _label, spec in _iter_options(text):
        bits = _opt_bits(spec)
        if bits:
            max_bit = max(max_bit, max(bits))
    hw = _hps_width(core_dir)
    if hw is not None and max_bit > hw:
        issues.append((
            FATAL,
            f"a CONF_STR option references status[{max_bit}] but "
            f"sys/hps_io declares only status[{hw}:0] — the write is "
            f"unobservable (widen hps_io or fix the option)"))
    return issues


def analyze(core_sv, core_dir=None):
    """Return (status, issues):
      status "nowire"  -> no joy_type decode wire, no structural defect -> n/a
      status "noopt"   -> decode wire but no UserIO Joystick option,
                          no structural defect (computer core)          -> n/a
      status "checked" -> issues = FATAL list ([]=ok). Structural defects
                          (overlap/width) force this even with no decode
                          wire / no UserIO option.
    Raises only OSError."""
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    extra = _structural_issues(text, core_dir)
    jt = JOYTYPE_RE.search(text)
    if not jt:
        return ("checked", extra) if extra else ("nowire", [])

    hi, lo = int(jt.group(1)), int(jt.group(2))
    jt_bits = set(range(min(hi, lo), max(hi, lo) + 1))
    issues = []

    spec = _confstr_option(text, "UserIO Joystick")
    if spec is None:
        return ("checked", extra) if extra else ("noopt", [])
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
    return "checked", issues + extra


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
        status, issues = analyze(core_sv, core_dir)
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
