#!/usr/bin/env python3
# SNAC `snac_active` per-core wiring check.
#
# Enforces the fork hazard notes. The joydb wrapper
# boilerplate ships `wire snac_active = 1'b0;` (no-op for non-SNAC cores).
# Cores WITH SNAC must replace the RHS with the core's SNAC-enable
# expression so SNAC preempts the joydb wrapper on the shared USER_IO pins;
# otherwise the wrapper fights SNAC -> ghost OSD clicks, spurious inputs,
# connector contention.
#
# apply_db9_framework.sh resets the RHS to `1'b0` on every run and the
# porter is supposed to preserve a custom RHS (extract_snac_active_rhs in
# port_core_full.py). A re-run / merge that loses it is silent -- exactly
# the regression class the fleet audit exists to catch. Table-driven, keyed
# by core directory name (the fork hazard notes' per-core table).
#
# Severities (mirrors joydb_map_check.py's contract):
#   FATAL   (exit 1): a known SNAC core whose snac_active RHS is still the
#           inert default `1'b0` -- SNAC does not preempt the wrapper.
#   FINDING (exit 0): a NON-tabled core whose RHS is non-default -- possibly
#           a newly-SNAC core not yet added to the table; maintainer review,
#           not a definitive defect (keeps the FATAL tier 0-false-positive).
#
# Usage:  snac_active_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = clean / n-a / finding; 1 = FATAL; 2 = parse/layout.

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv, strip_comments  # noqa: E402

FATAL = "FATAL"
FINDING = "FINDING"

# Per-core SNAC-enable RHS, verbatim from the fork hazard notes. The value is
# shown to the maintainer for context; the GATE is only "RHS != inert
# default" (exact-expr equality is fragile across legitimate refactors and
# would risk false positives -- the regression we must catch is the porter
# resetting a wired core back to 1'b0).
SNAC_CORES = {
    "NES_MiSTer": "raw_serial",
    "SNES_MiSTer": "raw_serial",
    "SMS_MiSTer": "raw_serial",
    "Saturn_MiSTer": "snac | saturn_via_smpc",
    "TurboGrafx16_MiSTer": "snac",
    "Genesis_MiSTer": "status[45]",
    "MegaCD_MiSTer": "status[46]",
    "MegaDrive_MiSTer": "|status[63:62]",
    "S32X_MiSTer": "status[45]",
    "PSX_MiSTer": "snacPort1 | snacPort2",
    "Atari7800_MiSTer": "is_snac0 | is_snac1",
    "SGB_MiSTer": "snac_snes | snac_gb",
}

SNAC_ACTIVE_RE = re.compile(r"wire\s+snac_active\s*=\s*([^;]+);")
# Inert default forms the porter emits / a reset would leave behind.
DEFAULT_RE = re.compile(r"^1'[bdh]0$|^0$|^1'b0$")


def _norm(rhs):
    return re.sub(r"\s+", "", rhs.strip())


def analyze(core_name, core_sv):
    """Return (issues, rhs). rhs is the snac_active RHS string, or None if
    the core has no `wire snac_active` line at all. Most ported cores
    (~133/145) predate the wrapper-thin boilerplate and gate joy_type
    directly off status[127:126] with no snac_active wire -- that is normal
    for a non-SNAC core (n/a), and a defect only for a tabled SNAC core
    (which must gate joy_type so SNAC preempts the wrapper)."""
    text = strip_comments(open(core_sv, "r", errors="replace").read())
    tabled = core_name in SNAC_CORES
    m = SNAC_ACTIVE_RE.search(text)
    if not m:
        if tabled:
            return [(FATAL,
                     f"{core_name} is a SNAC core but has no `wire "
                     f"snac_active = ...;` -- joy_type is ungated, so SNAC "
                     f"will not preempt the joydb wrapper on shared USER_IO "
                     f"(expected RHS `{SNAC_CORES[core_name]}`)")], None
        return [], None                 # non-SNAC, no snac gate -> n/a
    rhs = m.group(1).strip()
    is_default = bool(DEFAULT_RE.match(_norm(rhs)))
    issues = []
    if tabled and is_default:
        issues.append((
            FATAL,
            f"`wire snac_active = {rhs};` is still the inert default but "
            f"{core_name} is a SNAC core -- expected the SNAC-enable "
            f"expr (`{SNAC_CORES[core_name]}`); SNAC will not preempt the "
            f"joydb wrapper on shared USER_IO (ghost inputs)"))
    elif not tabled and not is_default:
        issues.append((
            FINDING,
            f"`wire snac_active = {rhs};` is non-default but {core_name} "
            f"is not in the SNAC table -- newly-SNAC core not yet tabled? "
            f"review + add to the fork hazard notes / SNAC_CORES"))
    return issues, rhs


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: snac_active_check.py <core_dir> [<core_sv_basename>]",
              file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    core_name = os.path.basename(core_dir)
    if len(argv) == 3 and argv[2]:
        core_sv = os.path.join(core_dir, argv[2])
        if not os.path.isfile(core_sv):
            core_sv = find_core_sv(core_dir)
    else:
        core_sv = find_core_sv(core_dir)
    print(f"  snac-coresv: {os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  snac: FAIL no <core>.sv declaring `module emu` in "
              f"{core_dir}")
        return 2

    try:
        issues, rhs = analyze(core_name, core_sv)
    except OSError as e:
        print(f"  snac: FAIL parse error ({e})")
        return 2

    cb = os.path.basename(core_sv)
    fatal = [msg for sev, msg in issues if sev == FATAL]
    finds = [msg for sev, msg in issues if sev == FINDING]
    for msg in fatal:
        print(f"  snac: FAIL {msg}")
    for msg in finds:
        print(f"  snac: FINDING {msg}")
    if fatal:
        return 1
    if core_name in SNAC_CORES:
        print(f"  snac: ok   SNAC core, snac_active = `{rhs}`  [{cb}]")
    elif finds:
        print(f"  snac: ok   no FATAL ({len(finds)} finding(s))  [{cb}]")
    elif rhs is None:
        print(f"  snac: n/a  non-SNAC core, no snac gate  [{cb}]")
    else:
        print(f"  snac: n/a  non-SNAC core, snac_active inert  [{cb}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
