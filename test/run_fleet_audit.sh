#!/usr/bin/env bash
# Fleet-wide structural correctness audit of every ported core.
#
# Answers "be sure every already-ported core is wired correctly, without
# hand-testing 140+ cores". For each ported core (predicate: sys/joydb.sv
# present) it runs, as-is (never re-applies the porter):
#
#   1. emu_portmap_check.py  — GENERIC port-map contract: every fork-added
#      ([MiSTer-DB9*]-wrapped) emu port in <core>.sv must be connected in
#      the active build's sys_top.v emu instance, and no connection may
#      reference a non-existent port. This is the Arcade-Tecmo class (the
#      missing .USER_OSD(user_osd) that left user_osd undriven and Start+C
#      silently dead) generalized — no hardcoded port names.
#   2. step6_verify          — the per-<core>.sv Step-6 checklist.
#
# DB15-only scoping is sufficient: DB9MD/DB15/Saturn all ride the same
# joydb.sv wrapper and the same emu/sys_top nets, so a wiring break breaks
# all three; the wrapper logic itself is proven once by Tier 1.
#
# Pure static analysis over ~145 cores -> seconds. No Quartus, no hardware,
# no network. Maintainer pre-sync gate (needs the umbrella working tree with
# sibling core repos). Exit nonzero if any core fails.
#
#   run_fleet_audit.sh [--core NAME] [--changed] [--quiet]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # umbrella MiSTer-DB9/
PORTMAP="$HERE/lib/emu_portmap_check.py"
# shellcheck source=lib/step6.sh
source "$HERE/lib/step6.sh"

only=""; changed=0; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --core)    only="$2"; shift 2 ;;
    --changed) changed=1; shift ;;
    --quiet)   quiet=1; shift ;;
    *) echo "usage: run_fleet_audit.sh [--core NAME] [--changed] [--quiet]" >&2; exit 2 ;;
  esac
done

# Enumerate ported cores = dirs with sys/joydb.sv.
mapfile -t cores < <(cd "$ROOT" && for d in */sys/joydb.sv; do
  [ -e "$d" ] && echo "${d%/sys/joydb.sv}"; done | sort)
[ -n "$only" ] && cores=("$only")

pass=0; failn=0; faillist=()
for c in "${cores[@]}"; do
  cd "$ROOT"
  [ -d "$c" ] || { echo "skip (missing): $c"; continue; }
  if [ "$changed" = 1 ] && git -C "$c" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$c" diff --quiet && git -C "$c" diff --cached --quiet && continue
  fi
  cfail=""; out=""
  # Single invocation: the checker emits the resolved top <core>.sv on a
  # `portmap-coresv:` line, so step6 reuses it without a second process.
  if ! pm="$(python3 "$PORTMAP" "$ROOT/$c" 2>&1)"; then cfail+="portmap "; fi
  out+="$pm"$'\n'
  csv="$(printf '%s\n' "$pm" | sed -n 's/^  portmap-coresv: //p')"
  if [ -n "$csv" ]; then
    if ! s6="$(step6_verify "$ROOT/$c" "$csv" 2>&1)"; then cfail+="step6 "; fi
    out+="$s6"$'\n'
  else
    cfail+="no-core-sv "
  fi
  if [ -z "$cfail" ]; then
    pass=$((pass+1)); [ "$quiet" = 1 ] || echo "PASS  $c"
  else
    failn=$((failn+1)); faillist+=("$c"); echo "FAIL  $c  [${cfail% }]"
    echo "$out" | grep -E 'FAIL|portmap:' | sed 's/^/      /'
  fi
done

echo
echo "==== fleet audit: ${pass} PASS / ${failn} FAIL / $((pass+failn)) cores ===="
if [ "$failn" -ne 0 ]; then
  printf '  failing: %s\n' "${faillist[*]}"
  exit 1
fi
exit 0
