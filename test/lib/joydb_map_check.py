#!/usr/bin/env python3
# joydb -> joystick mapping correctness check.
#
# The per-core joystick mux that folds the unified wrapper outputs
# (joydb_1 / joydb_2, [15:0] each) into the core's joystick_N is hand-written
# in every <core>.sv and the porter (port_core_full.py wrap_joystick_mux)
# only wraps it in the OSD_STATUS guard -- it never validates the body. Two
# real bug classes live there, both pure-static-detectable:
#
#   * P1/P2 data-bus LEAK -- ao486 shipped
#       wire [13:0] joystick_1 = joydb_2ena ? (... joydb_1[7:0]) : ...;
#     so player 2 mirrored player 1 (fixed in ao486 2b63c66). Invariant: the
#     active (selected) arm of `joydb_Mena ? <arm> : <fallback>` may only
#     reference joydb_M[...] data -- the fallback legitimately chains USB
#     wires and other-player joydb_Kena *enables* (never joydb_K[...] data).
#   * P1<->P2 bit-order DIVERGENCE -- Arcade-Galaga ships
#       P1 {joydb_1[11],joydb_1[9],joydb_1[10],joydb_1[4:0]}
#       P2 {joydb_2[11],joydb_2[10],joydb_2[9],joydb_2[4:0]}
#     (buttons 9/10 swapped on P2). Reported, not gated (some asymmetry is
#     legitimate -- maintainer triages).
#
# Canonical joydb_1/joydb_2 bit layout (fork_ci_template/sys/joydb.sv):
#   [3:0]=URDL  [4..9]=A/B/C/X/Y/Z (DB15: A..F)  [10]=Start
#   [11]=Mode/Select/Coin (universal function bit; also Saturn R-trigger)
#   [12]=Saturn L-trigger  [13] unused  [15:14] NEVER live in joydb_1/2.
#
# Severities:
#   FATAL   (exit 1, gates run_fleet_audit / merge_validate): leak,
#           out-of-range bit ([>=14]), missing OSD_STATUS guard on a
#           controller-data arm.
#   FINDING (exit 0, reported only, core still PASSes): P1/P2 bit-SET
#           divergence -- the P2 arm references a different *set* of joydb
#           bits than P1 (e.g. Arcade-Tecmo P2 drops bit [9]; SNES multitap).
#           A pure *order* swap between P1 and P2 is NOT reported: it is the
#           deliberate, fleet-wide arcade convention (each player's
#           joydb[10]=Start routes to that player's own Start line, which
#           sits at a different joystick bit for P1 vs P2 -- see
#           Arcade-Galaga `// CO S2 S1`), correct by design on 60+ cores.
#
# Robust mechanical only -- no per-core CONF_STR / upstream-joystick semantic
# model, so zero false positives on the FATAL tier (per the fleet-audit
# 0-false-positive contract).
#
# Usage:  joydb_map_check.py <core_dir> [<core_sv_basename>]
#         (2nd arg lets the fleet runner reuse the .sv emu_portmap_check.py
#          already resolved -- no second find_core_sv tree walk per core.)
# Exit:   0 = clean (findings allowed); 1 = FATAL defect; 2 = parse/layout.

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
# Single source of truth for top-.sv resolution + comment stripping.
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

# Head of a joystick mux arm: `... = joydb_<M>ena ?`. Width / var name / wire
# vs assign all vary across cores, so anchor only on the `joydb_Mena ?` token
# and recover the lvalue name by a short backward scan (for divergence
# pairing). The body is parsed with a depth balancer, never a flat regex
# (arms contain `[hi:lo]` slices and nested `?:`).
ENA_RE = re.compile(r"joydb_([12])ena\s*\?")
LVALUE_RE = re.compile(r"([A-Za-z_]\w*)\s*=\s*$")
# A joydb DATA reference = bus index followed by a bit-select `[`. `joydb_1ena`
# (no `[`) is an enable, not data, and must not match.
DATA_RE = re.compile(r"joydb_(\d+)\s*\[\s*(\d+)\s*(?::\s*(\d+)\s*)?\]")
# A bare whole-bus reference (`joydb_2` not followed by `ena` or `[`).
BARE_RE = re.compile(r"joydb_(\d+)(?!\w|\s*\[)")

FATAL = "FATAL"
FINDING = "FINDING"
# joydb_1/joydb_2 are [15:0] but only [13:0] is ever live; a ref whose high
# index reaches this is a wiring bug.
OOR_BIT = 14


def _scan_arm(text, after_q):
    """Return (arm_text, end_idx) for the ternary whose `?` ends at `after_q`
    (index just past that `?`). The active arm runs until the `:` that
    returns ternary depth to 0, tracking () {} [] and nested `?:`. None if
    unbalanced / runs into `;` with no matching `:`."""
    par = brace = brack = 0
    tern = 1                       # the joydb_Mena `?` we just consumed
    i = after_q
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(":
            par += 1
        elif c == ")":
            par -= 1
        elif c == "{":
            brace += 1
        elif c == "}":
            brace -= 1
        elif c == "[":
            brack += 1
        elif c == "]":
            brack -= 1
        elif par == 0 and brace == 0 and brack == 0:
            if c == "?":
                tern += 1
            elif c == ":":
                tern -= 1
                if tern == 0:
                    return text[after_q:i], i
            elif c == ";":
                return None        # statement ended before the ternary `:`
        i += 1
    return None


def _tokens(arm):
    """Ordered list of (bus, hi, lo) data refs + set of bare bus indexes."""
    toks = []
    for m in DATA_RE.finditer(arm):
        bus = int(m.group(1))
        hi = int(m.group(2))
        lo = int(m.group(3)) if m.group(3) is not None else hi
        toks.append((bus, hi, lo))
    bare = {int(m.group(1)) for m in BARE_RE.finditer(arm)}
    return toks, bare


def _fmt_bits(bset):
    """Render a sorted (hi, lo) tuple set as ["hi:lo" | "hi", ...]."""
    return [f"{h}:{l}" if h != l else str(h) for (h, l) in bset]


def analyze(core_sv):
    """Yield (severity, message) for each issue. severity in {FATAL, FINDING}.
    Raises ValueError on a layout the parser cannot trust (caller -> exit 2)."""
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    issues = []
    p1_shapes = []                 # ordered controller-data arms, M==1
    p2_shapes = []                 # ordered controller-data arms, M==2

    for m in ENA_RE.finditer(text):
        ena = int(m.group(1))
        head = text[:m.start()]
        lv = LVALUE_RE.search(head[-160:])
        var = lv.group(1) if lv else f"<{m.start()}>"
        scan = _scan_arm(text, m.end())
        if scan is None:
            raise ValueError(
                f"unbalanced joydb_{ena}ena ternary near `{var}` "
                f"(offset {m.start()})")
        arm, _ = scan
        toks, bare = _tokens(arm)

        # --- FATAL: P1/P2 leak (wrong bus referenced in the selected arm) ---
        wrong = sorted({b for (b, _h, _l) in toks if b != ena} | (bare - {ena}))
        for b in wrong:
            issues.append((
                FATAL,
                f"P1/P2 leak: `{var}` selected arm is gated by joydb_{ena}ena "
                f"but reads joydb_{b}[...] data (ao486 2b63c66 class) -- "
                f"player {ena} would mirror player {b}"))

        # --- FATAL: out-of-range bit ([15:14] never live in joydb_1/2) ---
        for (b, hi, lo) in toks:
            if max(hi, lo) >= OOR_BIT:
                issues.append((
                    FATAL,
                    f"out-of-range bit: `{var}` references joydb_{b}"
                    f"[{hi}:{lo}] -- bits 15:14 are never valid in "
                    f"joydb_1/joydb_2"))

        own = tuple(sorted((hi, lo) for (b, hi, lo) in toks if b == ena))
        if not own:
            continue               # pure routing arm (joystick_N_USB etc.)

        # --- FATAL: missing OSD_STATUS guard on a controller-data arm ---
        if "OSD_STATUS" not in arm:
            issues.append((
                FATAL,
                f"missing OSD_STATUS guard: `{var}` joydb_{ena}ena arm feeds "
                f"controller data with no `OSD_STATUS ?` mute -- ghost inputs "
                f"reach the core/OSD while the menu is open"))

        # `own` (sorted bit-set of this arm's own-bus refs) feeds the
        # P1<->P2 structural-divergence finding below. Order is intentionally
        # discarded (see header: P2 button order legitimately differs).
        (p1_shapes if ena == 1 else p2_shapes).append((var, own))

    # --- FINDING: P1<->P2 bit-SET divergence (paired in source order) ---
    # Different *set* of joydb bits between players => one player is missing
    # or has an extra button (Arcade-Tecmo / SNES class). A pure reorder of
    # the same set is the correct arcade convention and is NOT reported.
    for (v1, s1), (v2, s2) in zip(p1_shapes, p2_shapes):
        if s1 != s2:
            issues.append((
                FINDING,
                f"P1/P2 bit-set divergence: `{v1}` (P1) uses joydb bits "
                f"{_fmt_bits(s1)} but `{v2}` (P2) uses {_fmt_bits(s2)} -- "
                f"players reference different buttons, not just a reorder "
                f"(Arcade-Tecmo class)"))
    return issues


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: joydb_map_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2]:
        core_sv = os.path.join(core_dir, argv[2])
        if not os.path.isfile(core_sv):
            core_sv = find_core_sv(core_dir)
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  joydbmap-coresv: "
          f"{os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  joydbmap: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        issues = analyze(core_sv)
    except (OSError, ValueError) as e:
        print(f"  joydbmap: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    fatal = [msg for sev, msg in issues if sev == FATAL]
    finds = [msg for sev, msg in issues if sev == FINDING]
    for msg in fatal:
        print(f"  joydbmap: FAIL {msg}")
    for msg in finds:
        print(f"  joydbmap: FINDING {msg}")
    if not fatal:
        tail = f", {len(finds)} finding(s)" if finds else ""
        print(f"  joydbmap: ok   joydb mux mapping clean  [{cb}]{tail}")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
