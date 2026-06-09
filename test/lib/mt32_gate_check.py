#!/usr/bin/env python3
# MT32-pi <-> USER_IO anti-contention double-gate check.
#
# Enforces the two mandatory gates documented in
# the fork hazard notes. Any core that ships MT32-pi
# support (sys/mt32pi.sv) AND DB9 shares the USER_IO pins between the MT32
# I2C link and the DB9/DB15/Saturn controller. Without BOTH gates the MT32
# slave logic mis-reads DB9 button states as I2C traffic, latches
# mt32_available, and floods Main_MiSTer with OSD redraws (laggy/hung OSD).
# Upstream MT32 refactors merge in continuously and can silently revert a
# gate -- exactly the silent-on-merge class the fleet audit exists to catch,
# and currently caught by nothing.
#
#   Gate 1  USER_IN_MT32 must AND-include `mt32_disable` (bare `joy_any_en`
#           is insufficient -- at boot status bits aren't loaded yet so
#           joy_any_en=0 leaves MT32 reading raw DB9 signals).
#   Gate 2  the USER_OUT MT32 fallback (USER_OUT <= USER_OUT_MT32 / mt32_out)
#           must be governed by a gate token (mt32_use / mt32_disable /
#           mt32_on_primary), never an unconditional `else`.
#
# Recognised correct variants (all in the fork hazard notes):
#   * always_comb : `else if (mt32_use) begin USER_OUT[6:0] = USER_OUT_MT32;`
#                   (Minimig / AtariST / X68000)
#   * assign      : `... : mt32_use ? mt32_out : 8'hFF;`  (ao486)
#   * TRS-80      : both gated on `mt32_disable` directly.
#
# Severities (mirrors joydb_map_check.py's contract):
#   FATAL   (exit 1, gates run_fleet_audit / merge_validate): a definitive
#           defect -- USER_IN_MT32 assignment whose RHS lacks mt32_disable,
#           or a USER_OUT<-MT32 site with no gate token governing it.
#   FINDING (exit 0, reported only): MT32-capable core whose expected gate
#           anchor (USER_IN_MT32 / a USER_OUT<-MT32 site) is absent --
#           non-standard wiring, maintainer review, NOT a definitive defect
#           (keeps the FATAL tier 0-false-positive per the fleet contract).
#
# Usage:  mt32_gate_check.py <core_dir> [<core_sv_basename>]
#         (2nd arg lets the fleet runner reuse the .sv emu_portmap_check.py
#          already resolved -- no second find_core_sv tree walk per core.)
# Exit:   0 = clean / n-a / findings-only; 1 = FATAL; 2 = parse/layout.

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
# Single source of truth for top-.sv resolution + comment stripping.
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

FATAL = "FATAL"
FINDING = "FINDING"

# A core is MT32-capable if it ships the MT32-pi module or references the
# MT32 USER_IO plumbing in its top .sv. Either alone is conclusive; cores
# without MT32 never carry these tokens, so n/a is never a false skip.
MT32_TOKEN_RE = re.compile(r"\bmt32pi\b|USER_OUT_MT32|USER_IN_MT32|\bmt32_use\b")
# Gate tokens that legitimately govern the USER_OUT MT32 fallback / the
# USER_IN_MT32 mask (mt32_on_primary covers the SECOND_MT32 path).
GATE_RE = re.compile(r"\b(?:mt32_use|mt32_disable|mt32_on_primary)\b")
# Each `USER_IN_MT32 = <rhs> ;` assignment.
USER_IN_MT32_RE = re.compile(r"USER_IN_MT32\s*=\s*([^;]+);")
# A USER_OUT assignment (blocking or continuous) whose RHS drives the MT32
# source onto the user port. `mt32_out` and `USER_OUT_MT32` are the only
# MT32->USER_OUT source names used across the fleet.
USER_OUT_SRC_RE = re.compile(
    r"USER_OUT\s*(?:\[[^\]]*\])?\s*(?:<=|=)\s*[^;]*?"
    r"\b(USER_OUT_MT32|mt32_out)\b")
# How far back the governing condition may sit before a USER_OUT<-MT32
# assignment. Covers `else if (mt32_use) begin\n<indent>` and the inline
# `mt32_use ? ` ternary; short enough that an unrelated prior-statement gate
# token rarely intrudes on the documented bare-`else` defect.
WIN = 90


def analyze(core_sv):
    """Return (issues, mt32_capable). issues = list of (severity, message);
    severity in {FATAL, FINDING}. Raises ValueError on an untrustworthy
    layout (caller -> exit 2)."""
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    issues = []

    if not MT32_TOKEN_RE.search(text):
        return issues, False                # not MT32-capable -> n/a

    # --- Gate 1: USER_IN_MT32 RHS must include mt32_disable ---------------
    g1_sites = list(USER_IN_MT32_RE.finditer(text))
    if not g1_sites:
        issues.append((
            FINDING,
            "Gate 1 anchor absent: MT32-capable core has no `USER_IN_MT32` "
            "assignment -- non-standard MT32 input wiring, review"))
    for m in g1_sites:
        rhs = m.group(1)
        if "mt32_disable" not in rhs:
            issues.append((
                FATAL,
                f"Gate 1 missing: `USER_IN_MT32 = {rhs.strip()}` does not "
                f"AND-include `mt32_disable` -- MT32 reads raw DB9 signals "
                f"at boot (USER_IO bus contention)"))

    # --- Gate 2: USER_OUT<-MT32 fallback must be governed by a gate -------
    g2_sites = list(USER_OUT_SRC_RE.finditer(text))
    if not g2_sites:
        issues.append((
            FINDING,
            "Gate 2 anchor absent: MT32-capable core has no USER_OUT <- "
            "(USER_OUT_MT32|mt32_out) site -- non-standard MT32 output "
            "wiring, review"))
    for m in g2_sites:
        # Span = governing-condition window .. up to the MT32 source token.
        src_pos = m.start(1)
        span = text[max(0, m.start() - WIN):src_pos]
        if not GATE_RE.search(span):
            snippet = re.sub(r"\s+", " ", m.group(0)).strip()
            issues.append((
                FATAL,
                f"Gate 2 missing: `{snippet}` USER_OUT MT32 fallback is not "
                f"governed by mt32_use/mt32_disable/mt32_on_primary -- MT32 "
                f"drives I2C onto USER_IO during the boot window"))
    return issues, True


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: mt32_gate_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2]:
        core_sv = os.path.join(core_dir, argv[2])
        if not os.path.isfile(core_sv):
            core_sv = find_core_sv(core_dir)
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  mt32gate-coresv: "
          f"{os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  mt32gate: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        issues, capable = analyze(core_sv)
    except (OSError, ValueError) as e:
        print(f"  mt32gate: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    fatal = [msg for sev, msg in issues if sev == FATAL]
    finds = [msg for sev, msg in issues if sev == FINDING]
    for msg in fatal:
        print(f"  mt32gate: FAIL {msg}")
    for msg in finds:
        print(f"  mt32gate: FINDING {msg}")
    if fatal:
        return 1
    if not capable:
        print(f"  mt32gate: n/a  no MT32-pi support  [{cb}]")
    elif not issues:
        print(f"  mt32gate: ok   both anti-contention gates present  [{cb}]")
    else:
        print(f"  mt32gate: ok   no FATAL ({len(finds)} finding(s))  [{cb}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
