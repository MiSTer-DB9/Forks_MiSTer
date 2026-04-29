#!/usr/bin/env bash
# MiSTer-DB9 fork: status[125-127] collision tripwire.
#
# Fail if the current worktree contains any CONF_STR O[125-127] directive
# or status[125-127] reference outside fork-marker blocks. The fork claims
# bits 125-127 for joy_type / joy_2p; if upstream ever uses them, every
# match outside the fork's [MiSTer-DB9 BEGIN/END] / [MiSTer-DB9-Pro BEGIN/END]
# regions signals an upstream encroachment that the per-core sync must
# halt on so a human can renumber that one core's bit positions.

set -euo pipefail

mapfile -t SCAN_FILES < <(find . \
    -path ./.git -prune -o \
    -path ./releases -prune -o \
    -name 'joydb*.sv' -prune -o \
    -name 'joydb*.v'  -prune -o \
    \( -name '*.sv' -o -name '*.v' -o -name '*.vhd' \) -print)

(( ${#SCAN_FILES[@]} == 0 )) && { echo "check_status_collision: no source files found."; exit 0; }

HITS=$(awk '
    FNR == 1 { depth = 0 }
    /\[MiSTer-DB9(-Pro)? BEGIN\]/ { depth++; next }
    /\[MiSTer-DB9(-Pro)? END\]/   { if (depth > 0) depth--; next }
    depth == 0 {
        if (match($0, /O\[12[5-7](:[0-9]+)?\]/) || \
            match($0, /O\[[0-9]+:12[5-7]\]/)) {
            printf("%s:%d: %s\n", FILENAME, FNR, $0)
        }
        if (match($0, /status\[12[5-7](:[0-9]+)?\]/) && \
            !match($0, /\[127:0\][[:space:]]+status/)) {
            printf("%s:%d: %s\n", FILENAME, FNR, $0)
        }
    }
' "${SCAN_FILES[@]}")

if [[ -n "$HITS" ]]; then
    {
        echo "UPSTREAM STATUS BIT COLLISION DETECTED"
        printf '%s\n' "$HITS"
        echo
        echo "Upstream has introduced status[125-127] or CONF_STR O[125-127] usage"
        echo "outside fork marker blocks. The fork's joy_type/joy_2p reservations"
        echo "at these bits will collide. Manual remediation:"
        echo "  1. Renumber this core's joy_type/joy_2p to free bits below 125."
        echo "  2. Update CONF_STR strings to match."
        echo "  3. Re-run sync_release.sh."
    } >&2
    exit 1
fi

echo "check_status_collision: OK (no upstream encroachment on bits 125-127)."
