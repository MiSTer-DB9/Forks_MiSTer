#!/usr/bin/env bash
# MiSTer-DB9 fork: status-bit collision tripwire.
#
# Fail if the current worktree contains any CONF_STR O[N] directive or
# status[N] reference outside fork-marker blocks for a bit the fork has
# claimed. The default claimed set is 125-127 (canonical joy_type/joy_2p
# slot used by ~all cores).
#
# Cores parking joy_type/joy_2p outside that range (e.g. Minimig at
# status[63:62]/[61], AY-3-8500 same, TI-99_4A at status[63:62]/[59])
# must declare a per-file override using a single comment line in any
# scanned source file:
#
#     // [MiSTer-DB9 RESERVED status bits: 63:62 59]
#
# Bits may be space- or comma-separated; each token is either a single
# bit (`59`) or an inclusive range (`63:62`). Per-file overrides REPLACE
# the default — a core that wants both default and outlier bits must list
# them all (defensive, but rare in practice).
#
# When a non-marker line in the same file references one of the claimed
# bits via `O[bit]` or `status[bit]`, the script fails so the per-core
# sync halts and a human can renumber.

set -euo pipefail

mapfile -t SCAN_FILES < <(find . \
    -path ./.git -prune -o \
    -path ./.gemini -prune -o \
    -path ./.claude -prune -o \
    -path ./.headroom -prune -o \
    -path ./releases -prune -o \
    -name 'joydb*.sv' -prune -o \
    -name 'joydb*.v'  -prune -o \
    \( -name '*.sv' -o -name '*.v' -o -name '*.vhd' \) -print)

(( ${#SCAN_FILES[@]} == 0 )) && { echo "check_status_collision: no source files found."; exit 0; }

HITS=$(awk '
    function add_bit(b)            { claimed[FILENAME, b+0] = 1 }
    function add_range(lo, hi,  t) { if (lo > hi) { t=lo; lo=hi; hi=t } for (t = lo; t <= hi; t++) add_bit(t) }
    function set_default(           b) {
        for (b = 125; b <= 127; b++) add_bit(b)
    }
    function parse_reservation(line,   body, n, toks, i, parts) {
        # Strip everything before "RESERVED status bits:" then split tokens
        sub(/^.*RESERVED status bits:[ \t]*/, "", line)
        sub(/[ \t]*\][ \t]*$/, "", line)
        gsub(/,/, " ", line)
        n = split(line, toks, /[ \t]+/)
        for (i = 1; i <= n; i++) {
            if (toks[i] == "") continue
            if (index(toks[i], ":")) {
                split(toks[i], parts, ":")
                add_range(parts[1]+0, parts[2]+0)
            } else if (toks[i] ~ /^[0-9]+$/) {
                add_bit(toks[i]+0)
            }
        }
        has_override[FILENAME] = 1
    }
    FNR == 1 {
        # Reset per-file state and seed default reservation. If the file
        # also carries an explicit override, it will overwrite this set
        # entirely on first encounter.
        delete file_seen_default
    }
    /\[MiSTer-DB9 RESERVED status bits:/ {
        if (!has_override[FILENAME]) {
            # Drop default before applying override (override is authoritative)
            for (b = 125; b <= 127; b++) delete claimed[FILENAME, b]
        }
        parse_reservation($0)
        next
    }
    FNR == 1 {
        # Seed default after the first pass so an override on line 1 wins.
        # Use a sentinel to avoid re-seeding.
        if (!has_override[FILENAME] && !file_seen_default[FILENAME]) {
            set_default()
            file_seen_default[FILENAME] = 1
        }
    }
    /\[MiSTer-DB9(-Pro)? BEGIN\]/ { depth++; next }
    /\[MiSTer-DB9(-Pro)? END\]/   { if (depth > 0) depth--; next }
    depth > 0 { next }
    {
        # Width declaration like `wire [127:0] status,` or `output reg [63:0] status,`
        # is not a bit reference — skip.
        if ($0 ~ /\[[0-9]+:0\][ \t]+status[ \t;,]/) next

        line = $0
        hit = 0

        # CONF_STR O[bit] / O[hi:lo] — anchor with a non-letter prefix so
        # USER_IO, JOY_*, etc. do not match. Letter "O" must be at start
        # of line or preceded by a non-word character.
        s = line
        while (match(s, /(^|[^A-Za-z_0-9])O\[[0-9]+(:[0-9]+)?\]/)) {
            m = substr(s, RSTART, RLENGTH)
            sub(/^[^O]*O\[/, "", m); sub(/\]$/, "", m)
            if (index(m, ":")) {
                split(m, p, ":")
                lo = p[1]+0; hi = p[2]+0
                if (lo > hi) { t=lo; lo=hi; hi=t }
                for (b = lo; b <= hi; b++) if (claimed[FILENAME, b]) { hit = 1; break }
            } else if (claimed[FILENAME, m+0]) hit = 1
            if (hit) break
            s = substr(s, RSTART + RLENGTH)
        }

        if (!hit) {
            # status[bit] / status[hi:lo] reference — only single-bit and
            # narrow ranges (<= 4 bits wide) are treated as collisions.
            # Wider ranges are bulk slices like `status[127:99]` inside
            # status_in shuffles and would over-flag.
            s = line
            while (match(s, /status\[[0-9]+(:[0-9]+)?\]/)) {
                m = substr(s, RSTART, RLENGTH); sub(/^status\[/, "", m); sub(/\]$/, "", m)
                if (index(m, ":")) {
                    split(m, p, ":")
                    lo = p[1]+0; hi = p[2]+0
                    if (lo > hi) { t=lo; lo=hi; hi=t }
                    if (hi - lo <= 3) {
                        for (b = lo; b <= hi; b++) if (claimed[FILENAME, b]) { hit = 1; break }
                    }
                } else if (claimed[FILENAME, m+0]) hit = 1
                if (hit) break
                s = substr(s, RSTART + RLENGTH)
            }
        }

        if (hit) printf("%s:%d: %s\n", FILENAME, FNR, line)
    }
' "${SCAN_FILES[@]}")

if [[ -n "$HITS" ]]; then
    {
        echo "UPSTREAM STATUS BIT COLLISION DETECTED"
        printf '%s\n' "$HITS"
        echo
        echo "Upstream has introduced O[N] / status[N] usage on a bit reserved"
        echo "by this fork (default 125-127, or a per-file override declared"
        echo "via '// [MiSTer-DB9 RESERVED status bits: ...]'). Manual remediation:"
        echo "  1. Renumber this core's joy_type/joy_2p (and update the RESERVED"
        echo "     directive) to a free slot."
        echo "  2. Update CONF_STR strings + status[] references to match."
        echo "  3. Re-run sync_release.sh."
    } >&2
    exit 1
fi

echo "check_status_collision: OK (no upstream encroachment on fork-claimed bits)."
