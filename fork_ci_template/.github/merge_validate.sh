#!/usr/bin/env bash
# MiSTer-DB9 fork: post-merge port-validation gate (regression-only).
#
# Runs the fast static port-wiring checks (emu_portmap_check.py + the Step-6
# checklist) at the same post-merge / pre-Quartus slot as
# check_status_collision.sh, but as a DELTA gate: it fails only if the upstream
# merge INTRODUCED a new failure relative to the pre-merge tree. Pre-existing
# latent issues and legitimately bespoke cores (e.g. Menu_MiSTer, whose
# wrapper-shape checks already emit n/a) never wedge the pipeline.
#
# This catches the class check_status_collision.sh does not — e.g. a core
# whose <core>.sv references status[127:126] while its sys/hps_io.v is only
# 64-bit (Step-6 #10), the dead-UserIO-selector defect that motivated this
# gate. Pure grep/awk/python over one core dir: ~1-2 s, no Quartus, no
# iverilog, no network.
#
#   merge_validate.sh baseline <core_dir>   # snapshot the PRE-merge failures
#   merge_validate.sh check    <core_dir>   # fail iff merge added a failure
#
# Exit: check → 0 (no regression / no baseline = fail-open), 1 (regression).
#       baseline → always 0 (informational; never blocks the sync).
#
# emu_portmap_check.py / step6.sh / joydb_map_check.py / mt32_gate_check.py /
# snac_active_check.py are symlinks to the canonical Forks_MiSTer/test/lib
# copies (single source of truth, also driving run_fleet_audit.sh);
# setup_cicd.sh's `cp -rL` dereferences them into each fork, exactly like
# retry.sh / rerere_train.sh. canonical_drift_check is intentionally NOT
# wired here: it compares a fork's sys/* against Forks_MiSTer's
# fork_ci_template/sys canonical, which does not exist inside a fork repo
# (the fork only carries the already-materialised copies). Drift is a
# fleet/umbrella check (run_fleet_audit.sh + Tier-0), not a per-fork merge
# gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTMAP="${SCRIPT_DIR}/emu_portmap_check.py"
JOYDBMAP="${SCRIPT_DIR}/joydb_map_check.py"
MT32CHK="${SCRIPT_DIR}/mt32_gate_check.py"
SNACCHK="${SCRIPT_DIR}/snac_active_check.py"
JOYDBSEM="${SCRIPT_DIR}/joydb_semantic_check.py"
CONFSTRCHK="${SCRIPT_DIR}/confstr_joytype_check.py"
CORESVLINT="${SCRIPT_DIR}/coresv_lint.sh"
QIPREG="${SCRIPT_DIR}/qip_registration_check.py"
MARKERNEST="${SCRIPT_DIR}/marker_nesting_check.py"
VPREC="${SCRIPT_DIR}/verilog_precedence_check.py"
SATGATE="${SCRIPT_DIR}/saturn_gate_check.py"
JOYDBBIND="${SCRIPT_DIR}/joydb_binding_check.py"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/step6.sh"

# Step-6 ids that are merge-functional and therefore block on regression.
# Excluded on purpose: 1 (EOL) / 2 (legacy JOY_FLAG) / 8 (.qsf staged) — git
# index-state noise at `git merge --no-commit`, not a wiring break; still
# printed by step6_verify as info, just never gated here. 11 (Saturn-first
# CONF_STR order) IS blocking — an upstream CONF_STR reorder is a real
# OSD-cycle ghost-input hazard (the fork hazard notes).
BLOCKING_STEP6=" 3 4 4b 5 6 7 10 11 "

BASELINE_FILE="${RUNNER_TEMP:-/tmp}/db9_merge_validate_baseline.txt"

usage() { echo "usage: $0 {baseline|check} <core_dir>" >&2; exit 2; }

# Print the sorted, unique set of BLOCKING failure tokens for <core_dir>:
#   portmap        emu_portmap_check.py exited non-zero (defect/parse error)
#   no-core-sv     no <core>.sv resolvable (portmap could not pick a top)
#   step6-<id>     a blocking Step-6 check FAILed (id in BLOCKING_STEP6)
#   mapcheck       joydb_map_check.py FATAL (P1/P2 leak / out-of-range bit /
#                  missing OSD_STATUS guard). Its non-gating FINDINGs (bit-set
#                  divergence) never produce a token, so they cannot wedge.
#   mt32gate       mt32_gate_check.py FATAL (USER_IN_MT32 missing
#                  mt32_disable, or an ungoverned USER_OUT MT32 fallback).
#   snac           snac_active_check.py FATAL (a SNAC core's snac_active was
#                  reset to the inert 1'b0 default by an upstream merge).
#   confstr        confstr_joytype_check.py FATAL (CONF_STR UserIO option
#                  writes a status slice the joy_type/joy_2p decode never
#                  reads -- NES 7fc497b dead-controller class; n/a for
#                  bespoke/ext_ctrl cores, parse=2 fail-open).
#   coresv         coresv_lint.sh FAIL (delimiter imbalance in <core>.sv --
#                  the porter-regex / merge corruption class, e.g. 43db15c
#                  `[4) : 0]}`. Comment/string-masked (), [], {} balance;
#                  pure Python, zero false positive by construction. 2 =
#                  <core>.sv unresolvable (fail-open).
#   qipreg         qip_registration_check.py FATAL (a canonical fork
#                  sys/*.{v,sv} present but unregistered in sys.qip/sys.tcl,
#                  or a dangling registration -- Quartus silently skips the
#                  file; the InputTest/Menu class. n/a for pristine cores,
#                  parse=2 fail-open).
#   joydbsem       joydb_semantic_check.py FATAL (P1/P2 role transpose:
#                  same joydb bit-set, swapped concat order, a role bit at
#                  a mismatched position, single shared role in CONF_STR --
#                  Arcade-ComputerSpace/GnW class). Its advisory WARN tier
#                  (Start/Select/fire heuristics) exits 0 -> never
#                  tokenised, so a benign upstream CONF_STR rename cannot
#                  wedge: only a merge that NEWLY introduces a transpose
#                  trips it (regression-only delta cancels pre-existing).
#   markers        marker_nesting_check.py FATAL (orphan END / wrong-family
#                  close / unclosed BEGIN in <core>.sv or sys/sys_top.v --
#                  the SNES dc15e64 class step6 #4's count cannot see).
#                  n/a for pristine cores, parse=2 fail-open.
#   vprec          verilog_precedence_check.py FATAL (a bare non-zero
#                  literal as the whole operand of ||/&& -- the 3a94b0a
#                  constant-true-arm class; scans the WHOLE core .v/.sv
#                  tree). Delta is essential: it sees upstream-origin RTL,
#                  so a pre-existing upstream quirk must cancel; only a
#                  merge that NEWLY introduces one trips it.
#   satgate        saturn_gate_check.py WEAK (a Saturn-capable wrapper core
#                  whose .saturn_unlocked is a constant tie or unconnected
#                  -> key gate decorative). Delta is the ONLY zero-FP form:
#                  a legitimately-tied test core (InputTest 1'b1) is WEAK
#                  in BOTH trees so the delta cancels it; only a
#                  real->tied/absent change a merge introduces trips it.
#   joydbbind      joydb_binding_check.py FATAL (the `joydb joydb` instance
#                  fails to bind one or more ports of the canonical
#                  fork_ci_template/sys/joydb.sv module -- a merge / hand-
#                  edit dropped or typo-renamed e.g. .joy_raw / .joydb_2ena
#                  / .USER_OUT_DRIVE, leaving the controller path silently
#                  dead while every other check stays green. Zero-FP by
#                  construction (canonical defines truth); n/a for bespoke
#                  cores (no wrapper), parse=2 fail-open.
# All checks' non-gating FINDINGs exit 0 -> never tokenised, cannot wedge.
compute_tokens() {
  local dir="$1"
  local pm rc=0 csv s6 jrc=0 mrc=0 src=0 jsrc=0 cfrc=0 crc=0 qrc=0
  local mnrc=0 vprc=0 sgrc=0 jbrc=0 toks=() id
  # canonical_drift_check is deliberately absent here (no canonical sys/ in
  # a fork repo — see header). Drift is gated by run_fleet_audit.sh / Tier-0.
  pm="$(python3 "$PORTMAP" "$dir" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] && toks+=("portmap")
  csv="$(printf '%s\n' "$pm" | extract_portmap_coresv)"
  if [ -z "$csv" ]; then
    toks+=("no-core-sv")
  else
    s6="$(step6_verify "$dir" "$csv" 2>&1)" || true
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      case "$BLOCKING_STEP6" in
        *" $id "*) toks+=("step6-$id") ;;
      esac
    done < <(printf '%s\n' "$s6" | sed -n 's/^  step6: FAIL \([^ ]*\).*/\1/p')
    python3 "$JOYDBMAP" "$dir" "$csv" >/dev/null 2>&1 || jrc=$?
    [ "$jrc" -ne 0 ] && toks+=("mapcheck")
    python3 "$MT32CHK" "$dir" "$csv" >/dev/null 2>&1 || mrc=$?
    [ "$mrc" -eq 1 ] && toks+=("mt32gate")   # 1=FATAL; 2=parse (fail-open)
    python3 "$SNACCHK" "$dir" "$csv" >/dev/null 2>&1 || src=$?
    [ "$src" -eq 1 ] && toks+=("snac")       # 1=FATAL; 2=parse (fail-open)
    python3 "$JOYDBSEM" "$dir" "$csv" >/dev/null 2>&1 || jsrc=$?
    [ "$jsrc" -eq 1 ] && toks+=("joydbsem")  # 1=FATAL; 2=parse (fail-open)
    python3 "$CONFSTRCHK" "$dir" "$csv" >/dev/null 2>&1 || cfrc=$?
    [ "$cfrc" -eq 1 ] && toks+=("confstr")   # 1=FATAL; 2=parse (fail-open)
    bash "$CORESVLINT" "$dir" "$csv" >/dev/null 2>&1 || crc=$?
    [ "$crc" -eq 1 ] && toks+=("coresv")     # 1=syntax err; 2=parse (fail-open)
    python3 "$QIPREG" "$dir" >/dev/null 2>&1 || qrc=$?
    [ "$qrc" -eq 1 ] && toks+=("qipreg")     # 1=FATAL; 2=parse (fail-open)
    python3 "$MARKERNEST" "$dir" "$csv" >/dev/null 2>&1 || mnrc=$?
    [ "$mnrc" -eq 1 ] && toks+=("markers")   # 1=FATAL; 2=parse (fail-open)
    python3 "$VPREC" "$dir" >/dev/null 2>&1 || vprc=$?
    [ "$vprc" -eq 1 ] && toks+=("vprec")     # 1=FATAL; 2=parse (fail-open)
    python3 "$SATGATE" "$dir" "$csv" >/dev/null 2>&1 || sgrc=$?
    [ "$sgrc" -eq 1 ] && toks+=("satgate")   # 1=WEAK (delta-cancels legit tie)
    python3 "$JOYDBBIND" "$dir" "$csv" >/dev/null 2>&1 || jbrc=$?
    [ "$jbrc" -eq 1 ] && toks+=("joydbbind") # 1=FATAL; 2=parse (fail-open)
  fi
  # No blocking failures → empty output, success. Same empty output on a rare
  # internal error; the caller is fail-open by design (delta cancels anything
  # present in both baseline and check), so the two are intentionally fungible.
  [ "${#toks[@]}" -eq 0 ] && return 0
  printf '%s\n' "${toks[@]}" | sort -u
}

[ "$#" -eq 2 ] || usage
MODE="$1"
CORE_DIR="${2%/}"
[ -d "$CORE_DIR" ] || { echo "merge_validate: core dir not found: $CORE_DIR" >&2; exit 2; }

case "$MODE" in
  baseline)
    compute_tokens "$CORE_DIR" > "$BASELINE_FILE" || true
    echo "merge_validate: pre-merge baseline ($(wc -l < "$BASELINE_FILE" | tr -d ' ') blocking failure(s)):"
    sed 's/^/  /' "$BASELINE_FILE" || true
    exit 0
    ;;
  check)
    cur="$(compute_tokens "$CORE_DIR" || true)"
    if [ ! -f "$BASELINE_FILE" ]; then
      echo "merge_validate: no pre-merge baseline at ${BASELINE_FILE} —" \
           "skipping regression gate (fail-open)." >&2
      exit 0
    fi
    # Regression = a blocking token present now but absent pre-merge.
    regressions="$(comm -23 \
      <(printf '%s\n' "$cur" | grep -v '^$' | sort -u) \
      <(grep -v '^$' "$BASELINE_FILE" | sort -u) || true)"
    if [ -n "$regressions" ]; then
      {
        echo "UPSTREAM MERGE BROKE PORT VALIDATION"
        echo "The upstream merge introduced these NEW port-wiring failure(s)"
        echo "in ${CORE_DIR} (absent before the merge):"
        printf '%s\n' "$regressions" | sed 's/^/  /'
        echo
        echo "These are the run_fleet_audit.sh checks (emu_portmap_check.py /"
        echo "Step-6). Inspect with: Forks_MiSTer/test/run_fleet_audit.sh --core <name>"
        echo "Likely cause: an upstream change clobbered a fork DB9 port,"
        echo "marker, joydb wiring, or status-bit placement (e.g. joy_type"
        echo "moved past this core's sys/hps_io.v width — Step-6 #10)."
      } >&2
      exit 1
    fi
    echo "merge_validate: OK (merge introduced no new port-wiring failures)."
    exit 0
    ;;
  *) usage ;;
esac
