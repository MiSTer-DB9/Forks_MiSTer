#!/usr/bin/env python3
# `USER_OUT` OSD-open-probe drive check.
#
# Enforces the fix in the fork hazard notes /
# the fork hazard notes probe path: the joydb wrapper's OSD-open autodetect FSM
# emits its DB9MD/DB15/Saturn probe strobes on `USER_OUT_DRIVE`. The parent
# core must let those strobes reach the USER_IO pins while the OSD is open and
# the "UserIO Joystick" selector is Off -- otherwise autodetect-from-Off is
# dead (DB15 never gets its 4021 CLK/LOAD, DB9MD select line is never strobed).
#
# The regression class (NES/SNES, 2026-06): a hand-expanded SerJoystick
# `always_comb` relay whose selector-gated branches (joy_db15_en /
# joy_db9md_en / joy_saturn_en) drive `USER_OUT[n] = USER_OUT_DRIVE[n]`, but
# whose terminal `else` (selector = Off, no SNAC) drives `USER_OUT[n] = 1'b1`
# (idle-high) instead of falling through to USER_OUT_DRIVE. With the selector
# Off the relay takes that else, so the probe never drives the pins.
#
# The correct shape (SMS/Genesis/TNKIII/Atari800/Ti994a): the const-idle pin
# straps live in a *guard* branch (`if (snac_active)` / `if (SIO_MODE)` /
# `if (tipi_en)`) and the terminal `else` is `USER_OUT = USER_OUT_DRIVE;`. So
# the discriminator is guard-agnostic and robust: FAIL only when the *terminal*
# (condition-less) `else` of a USER_OUT-driving block sets USER_OUT to a
# constant idle while an earlier branch in the file drives it from
# USER_OUT_DRIVE. The const-idle in the guarded SNAC/peripheral branch is fine
# -- it is never the terminal else.
#
# Also catches the selector-gated strap form
#   assign USER_OUT[2] = joy_saturn_en ? USER_OUT_DRIVE[2] : 1'b1;
# (SNES Saturn 2P-mux SEL, pre-fix): a USER_OUT ternary whose condition is a
# selector signal and whose idle arm is a constant -> the probe can't drive
# that pin when the selector is Off.
#
# Severities (mirrors status_feedback_check.py / snac_active_check.py):
#   FATAL (exit 1): joydb core with a selector-Off idle-high USER_OUT path.
#   n/a   (exit 2, fail-open): core does not instantiate joydb (no probe FSM),
#         or drives USER_OUT only via a plain `assign USER_OUT = ...DRIVE` with
#         no const-idle terminal-else / selector strap to reason about.
#
# Usage: userout_probe_check.py <core_dir> [<core_sv_basename>]
# Exit:  0 = PASS; 1 = FATAL; 2 = parse / n/a (fail-open).

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv  # noqa: E402
# Reuse the line-count-preserving block-comment stripper + line counter so
# reported FATAL line numbers stay accurate past a multi-line /* */ block
# (emu_portmap_check.strip_comments collapses those, shifting the count).
from status_feedback_check import _strip_block_comments, _line_no  # noqa: E402

# joydb instance head -> core has the OSD-open probe FSM. No instance -> n/a.
JOYDB_INST_RE = re.compile(r"\bjoydb\s+joydb\s*\(", re.S)

# Constant idle-high USER_OUT value (whole bus or single pin).
_IDLE = r"(?:1'b1|8'hFF|8'hff|7'b1111111|'1)"

# A USER_OUT assignment that drives from the wrapper (the correct fall-through).
USER_OUT_DRIVE_ASSIGN_RE = re.compile(
    r"\bUSER_OUT\s*(?:\[\s*\d+\s*\]\s*)?(?:=|<=)\s*USER_OUT_DRIVE")

# A USER_OUT assignment to a constant idle value.
USER_OUT_IDLE_ASSIGN_RE = re.compile(
    r"\bUSER_OUT\s*(?:\[\s*\d+\s*\]\s*)?(?:=|<=)\s*" + _IDLE + r"\s*[;]")

# Selector-gated strap ternary:
#   assign USER_OUT[n] = <cond w/ a selector signal> ? <...> : <const idle> ;
# The true-arm is `[^;]*` (greedy, single statement) so a bus part-select
# (`data[7:0]`) or nested ternary in it doesn't make the `:` before <const
# idle> get missed -- greedy match binds to the LAST `:` before the `;`.
SELECTOR_TOKEN = r"joy_(?:db9md_en|db15_en|saturn_en|any_en|type)"
STRAP_TERNARY_RE = re.compile(
    r"\bassign\s+USER_OUT\s*\[\s*\d+\s*\]\s*=\s*"
    r"(?P<cond>[^?;]*?)\?[^;]*:\s*" + _IDLE + r"\s*;")

# begin/end (and case/function/task) nesting tokens + always/else/if for the
# depth-aware relay walk. Longer `end*` forms precede `end` so the alternation
# binds them first.
_BLK = re.compile(
    r"\b(always_comb|always_ff|always_latch|always|begin|endcase|endfunction"
    r"|endtask|end|casez|casex|case|function|task|else|if)\b")
_OPEN = {"begin", "case", "casez", "casex", "function", "task"}
_CLOSE = {"end", "endcase", "endfunction", "endtask"}


def _match_block_body(toks, i):
    """toks[i] is an opener; return index j of its matching closer (depth 0),
    or len(toks) if unbalanced."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j][0]
        if t in _OPEN:
            depth += 1
        elif t in _CLOSE:
            depth -= 1
            if depth == 0:
                return j
    return len(toks)


def _terminal_else_findings(text):
    """For each always block that drives USER_OUT, locate the LAST top-level
    (depth-1, condition-less) `else` and flag it when its balanced body drives
    USER_OUT to a constant idle and never to USER_OUT_DRIVE. Nested SNAC /
    peripheral `else` arms (depth > 1) and the guarded `if` arms are ignored,
    so only the selector-Off fall-through is judged."""
    toks = [(m.group(1), m.start(), m.end()) for m in _BLK.finditer(text)]
    findings = []
    n = len(toks)
    a = 0
    while a < n:
        if not toks[a][0].startswith("always"):
            a += 1
            continue
        # First `begin` after the always keyword opens the block body.
        b = a + 1
        while b < n and toks[b][0] != "begin":
            # a non-begin opener (e.g. `if` without begin) -> single-stmt
            # always, no relay to inspect.
            if toks[b][0] in _OPEN or toks[b][0].startswith("always"):
                break
            b += 1
        if b >= n or toks[b][0] != "begin":
            a += 1
            continue
        body_close = _match_block_body(toks, b)
        # Walk body tokens, tracking depth relative to the outer begin.
        depth = 0
        last_else = -1
        for k in range(b, min(body_close + 1, n)):
            t = toks[k][0]
            if t in _OPEN:
                depth += 1
            elif t in _CLOSE:
                depth -= 1
            elif t == "else" and depth == 1:
                # condition-less iff the next token is not `if`.
                nxt = toks[k + 1][0] if k + 1 < n else ""
                if nxt != "if":
                    last_else = k
        if last_else >= 0:
            # Extract the else arm's text span.
            nxt_i = last_else + 1
            if nxt_i < n and toks[nxt_i][0] == "begin":
                close = _match_block_body(toks, nxt_i)
                span = text[toks[nxt_i][2]:toks[close][1]]
            else:
                # single statement: to next ';'
                start = toks[last_else][2]
                semi = text.find(";", start)
                span = text[start:semi if semi >= 0 else len(text)]
            if "USER_OUT" in span and not USER_OUT_DRIVE_ASSIGN_RE.search(span):
                im = USER_OUT_IDLE_ASSIGN_RE.search(span)
                if im:
                    line = _line_no(text, toks[last_else][1])
                    findings.append((
                        "FATAL", line,
                        "terminal `else` of the USER_OUT relay drives "
                        "USER_OUT to constant idle instead of USER_OUT_DRIVE "
                        "-- OSD-open autodetect from selector=Off can't drive "
                        "the USER_IO pins"))
        a = body_close + 1
    return findings


def analyze(core_sv):
    """Return list of (severity, line, detail). Empty = PASS; the only
    non-PASS severities are 'FATAL' and the 'NA_*' sentinels."""
    # Strip comments line-count-preservingly: /* */ via the shared stripper,
    # then // to end-of-line (both keep every \n so line numbers stay true).
    raw = open(core_sv, "r", errors="replace").read()
    text = re.sub(r"//[^\n]*", "", _strip_block_comments(raw))

    if not JOYDB_INST_RE.search(text):
        return [("NA_NO_JOYDB", 0, "")]

    findings = _terminal_else_findings(text)

    # --- Selector-gated strap ternary with a constant idle arm.
    for m in STRAP_TERNARY_RE.finditer(text):
        cond = m.group("cond")
        if re.search(SELECTOR_TOKEN, cond):
            line = _line_no(text, m.start())
            findings.append((
                "FATAL", line,
                "USER_OUT[n] strap is gated on a selector signal with a "
                "constant idle arm -- the OSD-open probe can't drive that "
                "pin when the selector is Off; use USER_OUT_DRIVE[n]"))

    if findings:
        return findings
    # PASS if the core drives USER_OUT from the wrapper somewhere; else there is
    # no relay to reason about (plain-assign / bespoke driver) -> n/a.
    if USER_OUT_DRIVE_ASSIGN_RE.search(text):
        return []                                     # PASS
    return [("NA_NO_DRIVE", 0, "")]                   # nothing to reason about


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: userout_probe_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2]:
        core_sv = os.path.join(core_dir, argv[2])
        if not os.path.isfile(core_sv):
            core_sv = find_core_sv(core_dir)
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  uoprobe-coresv: {os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  uoprobe: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        results = analyze(core_sv)
    except OSError as e:
        print(f"  uoprobe: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    if not results:
        print(f"  uoprobe: ok   USER_OUT falls through to USER_OUT_DRIVE for "
              f"the OSD probe  [{cb}]")
        return 0

    if len(results) == 1 and results[0][0] == "NA_NO_JOYDB":
        print(f"  uoprobe: n/a  no joydb instance (no OSD probe FSM)  [{cb}]")
        return 2
    if len(results) == 1 and results[0][0] == "NA_NO_DRIVE":
        print(f"  uoprobe: n/a  no USER_OUT_DRIVE relay to reason about  "
              f"[{cb}]")
        return 2

    fatals = [r for r in results if r[0] == "FATAL"]
    for _sev, line, detail in fatals:
        print(f"  uoprobe: FAIL {cb}:{line} {detail}")
    return 1 if fatals else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
