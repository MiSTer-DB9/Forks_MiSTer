#!/usr/bin/env bash
# joydb -> joystick *semantic* mapping sweep over every ported core.
#
# Focused companion to run_fleet_audit.sh: runs ONLY lib/joydb_semantic
# _check.py across the fleet (dirs with sys/joydb.sv, same enumeration
# run_fleet_audit.sh uses), so a maintainer can eyeball the joydb role
# mapping (Start=joydb[10], Select/Mode/Coin=joydb[11], arcade fire from
# joydb[4]) without the other fleet checks in the way. Same single source
# of truth (lib/joydb_semantic_check.py) the fleet audit and
# merge_validate.sh use.
#
# Two tiers, mirroring the analyzer:
#   FATAL : P1/P2 role transpose (Arcade-ComputerSpace/GnW class) -- same
#           joydb bit-set, swapped concat order, a role bit at a mismatched
#           position, single shared role in CONF_STR. GATES run_fleet_audit
#           (hard) and merge_validate.sh (regression-only delta).
#   WARN  : advisory Start/Select/fire heuristics -- surfaced, never gates.
#
# Like run_fleet_audit.sh this is a maintainer umbrella tool: it needs the
# MiSTer-DB9 working tree with the sibling core repos checked out.
#
#   run_joydb_semantic.sh [--core NAME]
#
# Default = all ported cores. --core NAME = just that one.
# Exit 0 = no FATAL (WARN/INFO allowed). Exit 1 = at least one FATAL.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # umbrella MiSTer-DB9/
CHECK="$HERE/lib/joydb_semantic_check.py"
cd "$ROOT"

only=""
case "${1:-}" in
    --core) only="${2:-}"; [[ -z "$only" ]] && { echo "usage: run_joydb_semantic.sh [--core NAME]" >&2; exit 2; } ;;
    "")     ;;
    *)      echo "usage: run_joydb_semantic.sh [--core NAME]" >&2; exit 2 ;;
esac

if [[ -n "$only" ]]; then
    cores=("$only")
else
    mapfile -t cores < <(for d in */sys/joydb.sv; do
        [[ -e "$d" ]] && echo "${d%/sys/joydb.sv}"; done | sort)
fi

clean=0; fatal=0; warn=0; info=0; parse=0
fatallist=(); warnlist=()
for c in "${cores[@]}"; do
    [[ -d "$c" ]] || { echo "skip (missing): $c"; continue; }
    out="$(python3 "$CHECK" "$c" 2>&1)"; rc=$?
    has_warn=0; grep -q 'joydbsem: WARN' <<<"$out" && has_warn=1
    case "$rc" in
        1)  fatal=$((fatal+1)); fatallist+=("$c")
            echo "== FATAL $c =="
            grep -E 'joydbsem: (FATAL|WARN|J1)' <<<"$out" ;;
        0)  if [[ $has_warn -eq 1 ]]; then
                warn=$((warn+1)); warnlist+=("$c")
                echo "== WARN $c =="
                grep -E 'joydbsem: (WARN|J1)' <<<"$out"
            else
                grep -q 'joydbsem: INFO' <<<"$out" && info=$((info+1))
                clean=$((clean+1))
            fi ;;
        *)  parse=$((parse+1))
            echo "== $c (parse) =="
            grep -E 'joydbsem: (FAIL|FINDING)' <<<"$out" || echo "$out" ;;
    esac
done

echo
echo "==== joydb semantic: ${clean} clean / ${fatal} FATAL / ${warn} WARN / ${parse} parse-skip / ${#cores[@]} cores (${info} INFO) ===="
(( warn  > 0 )) && echo "WARN cores (advisory):  ${warnlist[*]}"
if (( fatal > 0 )); then
    echo "FATAL cores (gating):   ${fatallist[*]}"
    exit 1
fi
exit 0
