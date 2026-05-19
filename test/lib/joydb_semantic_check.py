#!/usr/bin/env python3
# joydb -> joystick *semantic* mapping advisory check.
#
# Companion to Forks_MiSTer/test/lib/joydb_map_check.py, but answers a
# different question. joydb_map_check.py is the fleet-gate mechanical check:
# P1/P2 data-bus leak, out-of-range bit, missing OSD_STATUS guard, P1/P2
# bit-set divergence -- a strict 0-false-positive contract that, by its own
# header, refuses any "per-core CONF_STR / upstream-joystick semantic model".
#
# This tool fills the gap that leaves: are the right *joydb bits* chosen for
# the conventional roles?
#
#   * Start  must come from joydb_N[10].
#   * Select / Mode / Coin must come from joydb_N[11].
#   * Arcade cores: the fire/action buttons must start at joydb_N[4] (= A).
#
# Each joydb bit is self-identifying regardless of where it sits in the
# per-core concat, so this is a pure static bit-MEMBERSHIP analysis -- no
# upstream joystick_0 layout model is needed, and (unlike a Verilator/iverilog
# harness) no per-core elaboration is required.
#
# Canonical joydb_1/joydb_2 layout (fork_ci_template/sys/joydb.sv):
#   [3:0]=URDL  [4]=A [5]=B [6]=C [7]=X [8]=Y [9]=Z
#   [10]=Start  [11]=Mode/Select/Coin (also Saturn R-trig)
#   [12]=Saturn L-trig  [13] unused  [15:14] never live.
#
# Split severity model (see the FATAL/WARN/INFO contract just below).
# run_fleet_audit.sh gates on FATAL and surfaces WARN as a GitHub
# ::warning:: annotation. merge_validate.sh also tokenises FATAL, but
# REGRESSION-ONLY (delta vs the pre-merge baseline): a benign upstream
# CONF_STR rename cannot wedge the release pipeline because it does not
# NEWLY introduce a transpose; only a merge that actually creates one
# trips it. WARN exits 0 -> never tokenised -> never wedges anything.
#
# Two tiers:
#   FATAL : P1/P2 role transpose -- same joydb bit-set, different concat
#           order, a role bit (Start[10]/Select[11]) at a mismatched
#           position, and CONF_STR has a single shared role (no Start
#           1P/2P). Arcade-ComputerSpace/GnW bug class. Gates the
#           maintainer fleet audit (hard) and merge_validate.sh
#           (regression-only delta).
#   WARN  : advisory role checks (Start/Select/fire). Surfaced as GitHub
#           ::warning:: annotations + a $GITHUB_STEP_SUMMARY digest in
#           run_fleet_audit; never tokenised, never gates anything.
#   INFO  : legitimate-but-notable (no Select/Coin; 8-bit DB9 budget;
#           CONF_STR J-line absent so role presence unverifiable).
#
# Usage:  joydb_semantic_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = clean / WARN / INFO (advisory) ; 1 = >=1 FATAL (gates) ;
#         2 = parse / no core .sv.

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
# Reuse the canonical arm parser + .sv resolver from the sibling fleet-test
# checks -- one source of truth for "what is a joydb controller-data arm".
from joydb_map_check import ENA_RE, LVALUE_RE, _scan_arm, _tokens  # noqa: E402
from emu_portmap_check import find_core_sv, strip_comments         # noqa: E402

FATAL = "FATAL"                      # gating tier (run_fleet_audit only)
WARN = "WARN"                        # advisory, GitHub ::warning::
INFO = "INFO"

BIT_START = 10                       # joydb[10] = Start
BIT_SELECT = 11                      # joydb[11] = Mode / Select / Coin
BIT_A = 4                            # joydb[4]  = A (first fire/action)
# Primary fire/action = A,B,C,X,Y (4..8). Z (joydb[9]) is the conventional
# *auxiliary* bit -- it rides every clean canonical arcade arm
# `{[11],[9],[10],[4:0]}`, so a lone [9] is never a "fire mapped wrong"
# signal and must not trigger the fire-from-A WARN.
PRIMARY_FIRE = (4, 5, 6, 7, 8)
# A DB9 pad delivers at most joydb[0..9]; cores that intentionally cap the
# mux at an 8-bit budget (`{joydb_N[7:0]}` -- ao486, X68000 class) cannot
# carry Start[10]/Select[11] *by design*, not by porting error.
DB9_8BIT_MAX = 8
# CONF_STR J-line tokens that mean "this core has a fire/action button".
_FIRE_WORDS = ("fire", "shot", "shoot", "button", "btn", "thrust", "bomb",
               "jump", "punch", "kick", "action", "attack", "trigger")
# Role bits whose feed must NOT differ between P1 and P2 unless the core's
# CONF_STR routes that role per player (Start 1P / Start 2P style).
ROLE_BITS = (BIT_START, BIT_SELECT)
# A CONF_STR J-line that routes a role per player (so a P1/P2 order swap of
# the role bits is the deliberate, fleet-wide arcade convention -- Galaga
# `Start 1P,Start 2P`, ~60 cores -- NOT the ComputerSpace single-shared
# -Start transpose bug).
_PER_PLAYER_RE = re.compile(
    r"\b1p\b|\b2p\b|\bp1\b|\bp2\b|player\s*[12]\b"
    r"|(?:start|coin|fire|button)\s*[12]\b")


def _expand(toks, bus):
    """Set of bit indexes referenced for `bus` (slices expanded)."""
    bits = set()
    for (b, hi, lo) in toks:
        if b == bus:
            bits |= set(range(min(hi, lo), max(hi, lo) + 1))
    return bits


def _seq(toks, bus):
    """Ordered list of bit indexes for `bus`, in concat (MSB->LSB) order,
    slices expanded high->low (Verilog `[hi:lo]` lists hi first). This is
    the per-player concat *shape* the transpose check compares."""
    out = []
    for (b, hi, lo) in toks:
        if b == bus:
            out.extend(range(max(hi, lo), min(hi, lo) - 1, -1))
    return out


def _per_player(jtoks):
    """True iff the CONF_STR J-line routes a role per player (Start 1P /
    Start 2P / P1 / P2 ...), so a P1/P2 role-bit order swap is the legit
    arcade convention rather than the ComputerSpace single-Start bug."""
    return bool(_PER_PLAYER_RE.search(" ".join(jtoks).lower()))


def _is_arcade(core_dir):
    return os.path.basename(core_dir.rstrip("/")).lower().startswith("arcade")


# The CONF_STR joystick line is `"J1,..."` / `"J,..."` -- the `"` is
# immediately followed by `J`. `"OJ,..."` (a status option whose id is J)
# starts with `O` and must NOT match.
_J_RE = re.compile(r'"J1?,([^"]*)"')


def _conf_j1(core_sv):
    """(raw J-line, token-list). The CONF_STR `J` line is upstream ground
    truth for which buttons the core actually has -- used to gate the
    Start / Select findings so cores with no such button (most computer
    cores) are not false-flagged."""
    try:
        raw = open(core_sv, "r", errors="replace").read()
    except OSError:
        return "", []
    m = _J_RE.search(raw)
    if not m:
        return "", []
    toks = [t.strip() for t in m.group(1).rstrip(";").split(",") if t.strip()]
    return "J1," + m.group(1), toks


def _has(toks, *needles):
    low = " ".join(toks).lower()
    return any(n in low for n in needles)


def analyze(core_sv, core_dir):
    """Yield (severity, message). Raises ValueError on an arm the shared
    parser cannot balance (caller -> exit 2)."""
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    arcade = _is_arcade(core_dir)
    _j1, jtoks = _conf_j1(core_sv)
    # Only assert a role bit when the core's own CONF_STR says that button
    # exists. No Start/Select token (typical of computer cores) => the bit
    # is legitimately absent, do not flag.
    want_start = (not jtoks) or _has(jtoks, "start")
    # "Coin" on a console/computer core is an OSD-mappable extra, not a pad
    # button -- only treat it as a joydb[11] obligation on an arcade core.
    # "Mode"/"Select" are real pad buttons regardless of family.
    want_select = ((not jtoks) or _has(jtoks, "select", "mode")
                   or (arcade and _has(jtoks, "coin")))
    has_fire_btn = (not jtoks) or _has(jtoks, *_FIRE_WORDS)
    jknown = bool(jtoks)
    issues = []
    p1 = []                          # [(var, bits)] in source order, M==1
    p2 = []                          # [(var, bits)] in source order, M==2

    for m in ENA_RE.finditer(text):
        ena = int(m.group(1))
        lv = LVALUE_RE.search(text[:m.start()][-160:])
        var = lv.group(1) if lv else f"<{m.start()}>"
        scan = _scan_arm(text, m.end())
        if scan is None:
            raise ValueError(
                f"unbalanced joydb_{ena}ena ternary near `{var}`")
        arm, _ = scan
        toks, _bare = _tokens(arm)
        bits = _expand(toks, ena)
        if not bits:
            continue                 # pure-routing arm (joystick_N_USB ...)

        # An 8-bit-budget mapping (no joydb bit >= 8 referenced) physically
        # cannot carry Start[10]/Select[11]; that is a deliberate DB9 cap on
        # computer cores, not a porting error -> downgrade to INFO.
        budget_8bit = max(bits) < DB9_8BIT_MAX

        if BIT_START not in bits and want_start:
            issues.append((
                INFO if (not jknown or budget_8bit) else WARN,
                f"`{var}` (P{ena}): CONF_STR declares a Start button but "
                f"joydb_{ena}[10] (Start) is not in the arm "
                f"(bits={sorted(bits)})"
                f"{' [8-bit DB9 budget]' if budget_8bit else ''}"))
        if BIT_SELECT not in bits and want_select:
            issues.append((
                INFO if (not jknown or budget_8bit) else WARN,
                f"`{var}` (P{ena}): CONF_STR declares Select/Mode/Coin "
                f"but joydb_{ena}[11] is not in the arm "
                f"(bits={sorted(bits)})"
                f"{' [8-bit DB9 budget]' if budget_8bit else ''}"))

        if arcade and has_fire_btn:
            # Only primary fire (A,B,C,X,Y) drives the WARN; a lone aux
            # bit [9]=Z is the canonical pattern, never a defect.
            pfire = sorted(b for b in bits if b in PRIMARY_FIRE)
            if pfire and BIT_A not in pfire:
                issues.append((
                    WARN,
                    f"`{var}` (P{ena}): arcade fire does not start at A -- "
                    f"joydb_{ena}[4] absent, first fire = joydb_{ena}"
                    f"[{pfire[0]}] (fire bits {pfire})"))

        (p1 if ena == 1 else p2).append((var, bits, _seq(toks, ena)))

    per_player = _per_player(jtoks)
    for (v1, b1, s1), (v2, b2, s2) in zip(p1, p2):
        # --- FATAL: P1/P2 role transpose (ComputerSpace class) ---
        # Same multiset of bits, same width, but a different concat order,
        # and a *role* bit (Start[10]/Select[11]) sits at a position where
        # P1 and P2 disagree. With a single shared role in CONF_STR this
        # mis-routes one player's Start/Coin to the wrong physical button
        # (Arcade-ComputerSpace dbd3175). When the CONF_STR routes the
        # role per player (Start 1P/2P) the swap is the legit fleet-wide
        # arcade convention -> NOT fatal. CONF_STR unknown -> cannot
        # discriminate -> not gated (conservative).
        if (jknown and not per_player
                and len(s1) == len(s2)
                and sorted(s1) == sorted(s2)
                and s1 != s2):
            bad = sorted({s1[i] for i in range(len(s1))
                          if s1[i] != s2[i]}
                         | {s2[i] for i in range(len(s2))
                            if s1[i] != s2[i]})
            if any(b in ROLE_BITS for b in bad):
                issues.append((
                    FATAL,
                    f"P1/P2 role transpose: `{v1}` and `{v2}` use the same "
                    f"joydb bits in a different order ({s1} vs {s2}); role "
                    f"bit(s) {[b for b in bad if b in ROLE_BITS]} land at "
                    f"mismatched positions and CONF_STR has a single shared "
                    f"role (no Start 1P/2P) -- one player's Start/Coin is "
                    f"mis-routed (Arcade-ComputerSpace class)"))

        # --- WARN: P1/P2 role presence divergence ---
        for bit, role in ((BIT_START, "Start"),
                           (BIT_SELECT, "Select/Mode"),
                           (BIT_A, "A/fire")):
            if (bit in b1) != (bit in b2):
                only = "P1" if bit in b1 else "P2"
                issues.append((
                    WARN,
                    f"P1/P2 role divergence: {role} (bit {bit}) present only "
                    f"in {only} (`{v1}` vs `{v2}`)"))
    return issues


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: joydb_semantic_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2] and \
            os.path.isfile(os.path.join(core_dir, argv[2])):
        core_sv = os.path.join(core_dir, argv[2])
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  joydbsem-coresv: "
          f"{os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  joydbsem: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        issues = analyze(core_sv, core_dir)
    except (OSError, ValueError) as e:
        print(f"  joydbsem: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    j1, _ = _conf_j1(core_sv)
    if j1:
        print(f"  joydbsem: J1   {j1}")
    fatals = [msg for sev, msg in issues if sev == FATAL]
    warns = [msg for sev, msg in issues if sev == WARN]
    infos = [msg for sev, msg in issues if sev == INFO]
    for msg in fatals:
        print(f"  joydbsem: FATAL {msg}")
    for msg in warns:
        print(f"  joydbsem: WARN {msg}")
    for msg in infos:
        print(f"  joydbsem: INFO {msg}")
    if not fatals and not warns:
        tail = f", {len(infos)} info" if infos else ""
        print(f"  joydbsem: ok   Start/Select/fire roles look sane  "
              f"[{cb}]{tail}")
    # Exit gates ONLY on FATAL (the P1/P2 role-transpose tier). WARN is
    # advisory -- it is surfaced (GitHub ::warning::) but never fails.
    return 1 if fatals else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
