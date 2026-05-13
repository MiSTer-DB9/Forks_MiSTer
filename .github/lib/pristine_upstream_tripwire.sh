#!/usr/bin/env bash
# shared pristine-upstream tripwire.
#
# Refuses to build an un-ported fork's first BOT-setup push as a stock-
# upstream RBF. Truth source: presence of joydb9saturn.v under any */sys/
# within depth 4 (canonical per porting/STATUS.md, works for both hps_io.sv
# and pre-SV-rename hps_io.v cores; depth-limited find handles non-standard
# layouts like Arcade-Cave's quartus/sys/). Fork-only repos with a sys/
# tree but no DB9 port (and Main_DB9 with no sys/ tree at all) fall through
# the same test.
#
# Returns 0 (pristine, caller should skip) or non-zero (ported, caller
# continues). Echoes the skip message on the pristine branch so callers
# don't have to duplicate it.

is_pristine_upstream() {
    local saturn_hit
    saturn_hit=$(find . -maxdepth 4 -path '*/sys/joydb9saturn.v' -type f -print -quit 2>/dev/null)
    if [[ -n "${saturn_hit}" ]]; then
        return 1
    fi
    # Saturn-hit miss is ambiguous: pristine upstream (skip) vs. fork-only
    # with no sys/ tree at all (Main_DB9 — fall through and build).
    # Disambiguate via a second find only when needed, so the hot path
    # (ported forks) walks once.
    local any_sys
    any_sys=$(find . -maxdepth 4 -type d -name sys -print -quit 2>/dev/null)
    if [[ -z "${any_sys}" ]]; then
        return 1
    fi
    echo "Fork is pristine upstream (no */sys/joydb9saturn.v within depth 4). Run apply_db9_framework.sh before enabling builds. Skipping."
    return 0
}
