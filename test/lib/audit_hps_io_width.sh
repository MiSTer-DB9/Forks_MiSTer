#!/usr/bin/env bash
# MiSTer-DB9 fork: hps_io status-width vs core max-bit audit.
#
# Catches the failure mode where a core's top .sv references status[N] for
# some N greater than the width declared by `output reg [W:0] status,` in
# its sys/hps_io.sv. When that happens, Main_MiSTer's UIO writes to bits
# above W are silently dropped, so any feature wired to those bits (joy_type,
# joy_2p, anything else parked at the top of the 128-bit window) never
# reaches the FPGA. The Saturn port migrated joy_type/joy_2p to bits
# 127:126/125 across the fork, so cores whose hps_io.sv lagged behind
# upstream's 128-bit widening shipped a Saturn selector that did nothing.
#
# Two correct outcomes per core:
#   (a) sys/hps_io.sv is already 128-bit (matches the joy_type encoding the
#       porter installs); or
#   (b) the core .sv keeps joy_type/joy_2p in free bits below the hps_io
#       width (Minimig pattern: status[63:62]/[61]).
#
# Anything else = "broken": grep for bits above the hps_io width and report.
#
# Exit 0 = clean. Exit 1 = at least one core mismatched.

set -uo pipefail

# Lives in Forks_MiSTer/test/lib (committed, managed) beside run_fleet_audit's
# helpers — NOT the unmanaged umbrella test/lib. Still a fleet audit
# over the sibling core dirs, so REPO_ROOT is the umbrella tree:
# test/lib -> test -> Forks_MiSTer -> MiSTer-DB9/.
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

dirty=0
for core in */; do
    core="${core%/}"
    case "$core" in
        Forks_MiSTer|porting|releases|.github|Documentation) continue ;;
    esac
    [[ -d "$core" ]] || continue
    hps="$core/sys/hps_io.sv"
    [[ -f "$hps" ]] || continue

    width=$(grep -m1 -oE 'output reg \[(31|63|127):0\] status,' "$hps" \
            | grep -oE '[0-9]+' | head -1)
    [[ -z "$width" ]] && continue

    # Pull max bit referenced as status[N] / status[hi:lo] in core top files
    # (sys/ excluded — only the per-core .sv / .v carries the encoding).
    mapfile -t topsv < <(find "$core" -maxdepth 1 \( -name '*.sv' -o -name '*.v' \) 2>/dev/null)
    (( ${#topsv[@]} == 0 )) && continue

    maxbit=$(grep -hoE 'status\[[0-9]+(:[0-9]+)?\]' "${topsv[@]}" 2>/dev/null \
             | grep -oE '[0-9]+' | sort -n | tail -1)
    [[ -z "$maxbit" ]] && maxbit=0

    if (( maxbit > width )); then
        echo "BROKEN  $core: sys/hps_io.sv has status[$width:0] but core uses status[$maxbit]"
        dirty=1
    fi
done

if (( dirty == 0 )); then
    echo "audit_hps_io_width: OK (every core's hps_io status width covers its max status bit)."
fi
exit $dirty
