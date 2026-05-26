#!/usr/bin/env python3
# `.status_in(...)` feedback-width check.
#
# Enforces the fork hazard notes. A core's hps_io
# `.status_in(...)` concat is the slice the FPGA hands back to Main_MiSTer
# whenever `status_set` pulses (region detect, save-state load, BK callback,
# ...). Bits NOT covered by that concat are driven as zero into status_req
# and Main_MiSTer writes the zero straight back into the FPGA on the next
# chunk-load (`status[127:112] <= io_din;`) -- silently zeroing every
# DB9-wrapper bit upstream forgot to include (joy_type at status[127:126]
# or status[127:125], joy_2p at status[125] or status[124]).
#
# The Genesis/MegaCD/S32X 2026-05-26 class: each core sliced
# `.status_in({status[63:8], region_req, status[5:0]})`, dropping bits
# 64-127 on every ROM-load region_set -> UserIO Joystick reverts to Off on
# every game change. MegaDrive escaped by already using `status[127:8]`;
# ZX-Spectrum carries the fix wrapped in `[MiSTer-DB9 BEGIN]/END` and is
# the reference pattern.
#
# Severities (mirrors snac_active_check.py / joydb_map_check.py contract):
#   FATAL (exit 1): the core uses joy_type at status[127:..] AND has a
#         `.status_in({...})` concat whose maximum status-slice top is < 127
#         -> any status_set pulse zeros joy_type / joy_2p.
#   n/a   (exit 2, fail-open): no `wire ... joy_type_raw = status[127:` /
#         `wire [1:0] joy_type = status[127:126]` declaration (un-ported
#         core / bespoke wrapper) OR no `.status_in(` port assignment found
#         (no feedback path -> nothing to truncate) OR opaque .status_in
#         expression (not a concat with status slices).
#
# Usage: status_feedback_check.py <core_dir> [<core_sv_basename>]
# Exit:  0 = PASS; 1 = FATAL; 2 = parse / n/a (fail-open).

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv  # noqa: E402

# Match either pre-PSX (`wire [1:0] joy_type = status[127:126]`) or
# 3-bit/wrapper-thin (`wire ... joy_type_raw = status[127:125]`) form.
JOY_TYPE_RE = re.compile(
    r"\bwire\s+(?:\[\s*\d+\s*:\s*\d+\s*\]\s+)?joy_type(?:_raw)?\s*=\s*"
    r"status\s*\[\s*127\s*:\s*\d+\s*\]",
    re.S,
)

STATUS_IN_HEAD = re.compile(r"\.status_in\s*\(", re.S)
STATUS_SLICE_RE = re.compile(r"\bstatus\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]")
STATUS_BARE_RE = re.compile(r"\bstatus\b(?!\s*[\[\(])")


def _balanced_paren_end(text, open_idx):
    """Given text[open_idx] == '(', return index of the matching ')'.
    -1 if unbalanced."""
    depth = 0
    for i in range(open_idx, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


def _line_no(text, idx):
    return text.count("\n", 0, idx) + 1


def _strip_block_comments(text):
    """Remove /* ... */ blocks while PRESERVING line count (each removed
    newline-bearing comment is replaced with the same number of newlines).
    Line-comments (`// ...`) are left in place; the .status_in matcher
    rejects them by checking for `//` earlier on the same line."""
    out = []
    i = 0
    while i < len(text):
        j = text.find("/*", i)
        if j < 0:
            out.append(text[i:]); break
        out.append(text[i:j])
        k = text.find("*/", j + 2)
        if k < 0:
            break                                    # unterminated -> bail
        # Preserve newline count from the elided block.
        out.append("\n" * text.count("\n", j, k + 2))
        i = k + 2
    return "".join(out)


def _is_in_line_comment(text, match_start):
    """True if match_start is on the same line *after* a `//`."""
    line_start = text.rfind("\n", 0, match_start) + 1
    return "//" in text[line_start:match_start]


def analyze(core_sv):
    """Return list of (severity, line, slice_expr, max_h) tuples.
    Empty list = PASS / n/a; severity is 'FATAL' for the real defect."""
    raw = open(core_sv, "r", errors="replace").read()
    text = _strip_block_comments(raw)            # line numbers preserved
    if not JOY_TYPE_RE.search(text):
        return [("NA_NO_JOYTYPE", 0, "", -1)]
    findings = []
    found_any = False
    for m in STATUS_IN_HEAD.finditer(text):
        if _is_in_line_comment(text, m.start()):
            continue
        open_paren = m.end() - 1
        close_paren = _balanced_paren_end(text, open_paren)
        if close_paren < 0:
            continue
        inner = text[open_paren + 1:close_paren].strip()
        found_any = True
        line = _line_no(text, m.start())
        # Pass-through forms: `.status_in(status)` or any expr that
        # references the whole `status` bus with no slice -> bits 127:0
        # preserved.
        if (inner == "status" or
                (STATUS_BARE_RE.search(inner) and
                 not STATUS_SLICE_RE.search(inner))):
            continue                                  # PASS for this site
        slices = [(int(h), int(l)) for h, l in
                  STATUS_SLICE_RE.findall(inner)]
        if not slices:
            # Opaque expr (no status slices at all, e.g. constant '0): we
            # cannot reason -> n/a fail-open. Record so caller can print it
            # but do not gate.
            findings.append(("NA_OPAQUE", line, inner, -1))
            continue
        max_h = max(h for h, _ in slices)
        if max_h >= 127:
            continue                                  # PASS for this site
        findings.append(("FATAL", line, inner, max_h))
    if not found_any:
        return [("NA_NO_STATUSIN", 0, "", -1)]
    return findings


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: status_feedback_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2]:
        core_sv = os.path.join(core_dir, argv[2])
        if not os.path.isfile(core_sv):
            core_sv = find_core_sv(core_dir)
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  statusfb-coresv: {os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  statusfb: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        results = analyze(core_sv)
    except OSError as e:
        print(f"  statusfb: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    if not results:
        print(f"  statusfb: ok   .status_in preserves status[127:..]  [{cb}]")
        return 0

    # Special n/a sentinels (no FATAL possible) -> exit 2 fail-open.
    if len(results) == 1 and results[0][0] == "NA_NO_JOYTYPE":
        print(f"  statusfb: n/a  no joy_type wrapper (un-ported / bespoke)  "
              f"[{cb}]")
        return 2
    if len(results) == 1 and results[0][0] == "NA_NO_STATUSIN":
        print(f"  statusfb: n/a  no `.status_in(` port assignment  [{cb}]")
        return 2

    fatals = [r for r in results if r[0] == "FATAL"]
    opaques = [r for r in results if r[0] == "NA_OPAQUE"]
    for sev, line, expr, max_h in fatals:
        snippet = expr if len(expr) <= 80 else expr[:77] + "..."
        print(f"  statusfb: FAIL {cb}:{line} .status_in concat truncates "
              f"status feedback: max slice status[{max_h}:..] < 127, joy_type"
              f"/joy_2p will reset on every status_set pulse -- expr: "
              f"`{snippet}`")
    for sev, line, expr, _ in opaques:
        snippet = expr if len(expr) <= 80 else expr[:77] + "..."
        print(f"  statusfb: n/a  {cb}:{line} opaque .status_in expr (no "
              f"status slices to reason about): `{snippet}`")
    if fatals:
        return 1
    # Opaques only -> fail-open.
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
