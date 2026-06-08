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
JOYDBMAP="$HERE/lib/joydb_map_check.py"
MT32CHK="$HERE/lib/mt32_gate_check.py"
SNACCHK="$HERE/lib/snac_active_check.py"
CONFSTRCHK="$HERE/lib/confstr_joytype_check.py"
CORESVLINT="$HERE/lib/coresv_lint.sh"
QIPREG="$HERE/lib/qip_registration_check.py"
MARKERNEST="$HERE/lib/marker_nesting_check.py"
VPREC="$HERE/lib/verilog_precedence_check.py"
# Advisory only, NEVER gates: joydb->joystick *semantic* role check
# (Start=joydb[10], Select/Mode/Coin=joydb[11], arcade fire from joydb[4]).
JOYDBSEM="$HERE/lib/joydb_semantic_check.py"
# Advisory only, NEVER gates here: saturn_unlocked AND-gate. A legitimately
# tied test core (InputTest 1'b1) is WEAK absolutely -> only the
# merge_validate baseline/check delta can gate it without a false positive.
SATGATE="$HERE/lib/saturn_gate_check.py"
# Gates (FATAL zero-FP by construction): joydb wrapper instance must bind
# every port of the canonical fork_ci_template/sys/joydb.sv module. A
# merge / hand-edit that drops or typo-renames a binding leaves the
# controller path silently dead.
JOYDBBIND="$HERE/lib/joydb_binding_check.py"
# Gates (FATAL zero-FP by construction): .status_in concat must preserve
# status[127:64] when joy_type lives there, else any status_set pulse zeros
# joy_type/joy_2p (the Genesis/MegaCD/S32X 2026-05-26 class). n/a for cores
# without the joy_type wrapper or without a .status_in port, parse=2
# fail-open.
STATUSFB="$HERE/lib/status_feedback_check.py"
# Gates (FATAL zero-FP by construction): a joydb core's USER_OUT relay must
# fall through to USER_OUT_DRIVE in its selector-Off terminal else, else the
# OSD-open autodetect probe can't drive USER_IO from Off (the NES/SNES/PSX
# 2026-06 class). n/a for non-joydb cores / plain-assign drivers.
UOPROBE="$HERE/lib/userout_probe_check.py"
# shellcheck source=lib/step6.sh
source "$HERE/lib/step6.sh"
# shellcheck source=lib/canonical_drift_check.sh
source "$HERE/lib/canonical_drift_check.sh"

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

pass=0; failn=0; faillist=(); findn=0; findlist=()
semwarn=0; semlist=()                       # advisory joydb-semantic WARNs
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
  csv="$(printf '%s\n' "$pm" | extract_portmap_coresv)"
  if [ -n "$csv" ]; then
    if ! s6="$(step6_verify "$ROOT/$c" "$csv" 2>&1)"; then cfail+="step6 "; fi
    out+="$s6"$'\n'
    # joydb mux mapping correctness (P1/P2 leak / out-of-range bit / missing
    # OSD_STATUS guard = FATAL; P1/P2 bit-set divergence = non-gating
    # FINDING). Reuses the same resolved <core>.sv as step6 — no extra
    # find_core_sv walk.
    jm="$(python3 "$JOYDBMAP" "$ROOT/$c" "$csv" 2>&1)"; jrc=$?
    out+="$jm"$'\n'
    [ "$jrc" -ne 0 ] && cfail+="mapcheck "
    # MT32 anti-contention double-gate (the fork hazard notes).
    # FATAL=missing Gate 1/2; FINDING=non-standard wiring; n/a=non-MT32.
    mg="$(python3 "$MT32CHK" "$ROOT/$c" "$csv" 2>&1)"; mrc=$?
    out+="$mg"$'\n'
    [ "$mrc" -eq 1 ] && cfail+="mt32gate "
    # SNAC priority over UserJoy (the fork hazard notes). FATAL=SNAC
    # core reset to inert 1'b0; FINDING=untabled non-default.
    sn="$(python3 "$SNACCHK" "$ROOT/$c" "$csv" 2>&1)"; src=$?
    out+="$sn"$'\n'
    [ "$src" -eq 1 ] && cfail+="snac "
    # CONF_STR <-> joy_type/joy_2p status-bit alignment (NES 7fc497b class:
    # menu writes a slice the decode never reads). FATAL=mismatch; n/a for
    # bespoke / ext_ctrl-mirror cores. Reuses the resolved <core>.sv.
    cf="$(python3 "$CONFSTRCHK" "$ROOT/$c" "$csv" 2>&1)"; cfrc=$?
    out+="$cf"$'\n'
    [ "$cfrc" -eq 1 ] && cfail+="confstr "
    # Per-core <core>.sv delimiter-balance lint (porter-regex / merge
    # corruption, the 43db15c / 995e9cc class). Pure Python, zero-FP;
    # exit 2 = <core>.sv unresolvable (not a failure).
    cl="$(bash "$CORESVLINT" "$ROOT/$c" "$csv" 2>&1)"; clrc=$?
    out+="$cl"$'\n'
    [ "$clrc" -eq 1 ] && cfail+="coresv "
    # joydb semantic role check — SPLIT tiers:
    #   FATAL (exit 1) = P1/P2 role transpose (ComputerSpace class) ->
    #     GATES this audit, exactly like mapcheck/mt32gate/snac. Caught
    #     here at the maintainer pre-sync gate, never in merge_validate.
    #   WARN  (exit 0) = advisory Start/Select/fire heuristics -> surfaced
    #     as a GitHub ::warning:: + a $GITHUB_STEP_SUMMARY digest, never
    #     changes the exit code.
    # Reuses the resolved <core>.sv.
    if [ -f "$JOYDBSEM" ]; then
      js="$(python3 "$JOYDBSEM" "$ROOT/$c" "$csv" 2>&1)"; jsrc=$?
      out+="$js"$'\n'
      [ "$jsrc" -eq 1 ] && cfail+="joydbsem "
      while IFS= read -r wl; do
        msg="${wl#*joydbsem: WARN }"
        semwarn=$((semwarn+1))
        case " ${semlist[*]-} " in *" $c "*) ;; *) semlist+=("$c");; esac
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
          echo "::warning title=joydb-semantic ($c)::$msg"
          [ -n "${GITHUB_STEP_SUMMARY:-}" ] && \
            printf -- '- **%s**: %s\n' "$c" "$msg" >> "$GITHUB_STEP_SUMMARY"
        fi
      done < <(printf '%s\n' "$js" | grep -E 'joydbsem: WARN' || true)
    fi
  else
    cfail+="no-core-sv "
  fi
  # Canonical sys/* drift (the merge-compat rule): per-core copies must equal
  # Forks_MiSTer/fork_ci_template/sys. Independent of <core>.sv resolution.
  dr="$(canonical_drift_check "$ROOT/$c" 2>&1)" || cfail+="drift "
  out+="$dr"$'\n'
  # Canonical fork sys/*.{v,sv} <-> sys.qip/sys.tcl registration. Core-dir
  # only (no <core>.sv needed), so it runs alongside the drift check.
  # FATAL=1 gates; n/a / parse(2) do not. Surfaces the InputTest/Menu
  # unregistered-key-gate defect for manual triage.
  qr="$(python3 "$QIPREG" "$ROOT/$c" 2>&1)"; qrc=$?
  out+="$qr"$'\n'
  [ "$qrc" -eq 1 ] && cfail+="qipreg "
  # Fork-marker nesting/balance in <core>.sv + sys/sys_top.v (the SNES
  # dc15e64 class step6 #4's count cannot see). Reuses the resolved
  # <core>.sv. FATAL=1 gates; n/a / parse(2) do not.
  mn="$(python3 "$MARKERNEST" "$ROOT/$c" "$csv" 2>&1)"; mnrc=$?
  out+="$mn"$'\n'
  [ "$mnrc" -eq 1 ] && cfail+="markers "
  # ||/&& bare-literal precedence over the WHOLE core .v/.sv tree (the
  # 3a94b0a constant-true-arm class). FATAL=1 gates; n/a(no .v/.sv)/
  # parse(2) do not.
  vp="$(python3 "$VPREC" "$ROOT/$c" 2>&1)"; vprc=$?
  out+="$vp"$'\n'
  [ "$vprc" -eq 1 ] && cfail+="vprec "
  # saturn_unlocked AND-gate -- ADVISORY ONLY here (a legit tied test core
  # is WEAK absolutely; the real gate is the merge_validate delta). Never
  # touches cfail; surfaced below like the joydbsem WARN tier.
  sg="$(python3 "$SATGATE" "$ROOT/$c" "$csv" 2>&1)"
  out+="$sg"$'\n'
  # joydb wrapper port-binding completeness vs canonical joydb.sv module.
  # FATAL=1 gates (no legit "missing port" case -- the porter emits a full
  # instance; bespoke cores have no wrapper -> n/a). parse(2) does not.
  jb="$(python3 "$JOYDBBIND" "$ROOT/$c" "$csv" 2>&1)"; jbrc=$?
  out+="$jb"$'\n'
  [ "$jbrc" -eq 1 ] && cfail+="joydbbind "
  # .status_in feedback-width gate (status-in-truncation hazard).
  sf="$(python3 "$STATUSFB" "$ROOT/$c" "$csv" 2>&1)"; sfrc=$?
  out+="$sf"$'\n'
  [ "$sfrc" -eq 1 ] && cfail+="statusfb "
  # USER_OUT OSD-probe fall-through gate (selector-Off autodetect hazard).
  uo="$(python3 "$UOPROBE" "$ROOT/$c" "$csv" 2>&1)"; uorc=$?
  out+="$uo"$'\n'
  [ "$uorc" -eq 1 ] && cfail+="uoprobe "
  if [ -z "$cfail" ]; then
    pass=$((pass+1))
    if finds="$(printf '%s\n' "$out" | grep -E '(joydbmap|mt32gate|snac): FINDING')"; then
      findn=$((findn+1)); findlist+=("$c")
      [ "$quiet" = 1 ] || echo "PASS  $c  (finding)"
      printf '%s\n' "$finds" | sed 's/^/      /'
    else
      [ "$quiet" = 1 ] || echo "PASS  $c"
    fi
  else
    failn=$((failn+1)); faillist+=("$c"); echo "FAIL  $c  [${cfail% }]"
    echo "$out" | grep -E 'FAIL|FATAL|portmap:|joydbmap:|mt32gate:|snac:|confstr:|coresv-lint:|joydbsem:|drift:|qipreg:|marker-nest:|vprec:|satgate:|joydb-bind:|statusfb:|uoprobe:' \
      | sed 's/^/      /'
  fi
  # Advisory joydb-semantic WARNs + satgate WEAK are shown regardless of
  # pass/fail and never change the exit code.
  printf '%s\n' "$out" | grep -E 'joydbsem: WARN' | sed 's/^/      SEM /' \
    || true
  printf '%s\n' "$out" | grep -E 'satgate: WEAK' | sed 's/^/      SAT /' \
    || true
done

echo
echo "==== fleet audit: ${pass} PASS / ${failn} FAIL / $((pass+failn)) cores" \
     "(${findn} with non-gating findings) ===="
if [ "$findn" -ne 0 ]; then
  printf '  findings: %s\n' "${findlist[*]}"
fi
if [ "$semwarn" -ne 0 ]; then
  printf '  joydb-semantic WARN (advisory, non-gating): %s\n' "${semlist[*]}"
fi
if [ "$failn" -ne 0 ]; then
  printf '  failing: %s\n' "${faillist[*]}"
  exit 1
fi
exit 0
