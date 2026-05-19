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
# emu_portmap_check.py + step6.sh are symlinks to the canonical
# Forks_MiSTer/test/lib copies (single source of truth, also driving
# run_fleet_audit.sh); setup_cicd.sh's `cp -rL` dereferences them into each
# fork, exactly like retry.sh / rerere_train.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTMAP="${SCRIPT_DIR}/emu_portmap_check.py"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/step6.sh"

# Step-6 ids that are merge-functional and therefore block on regression.
# Excluded on purpose: 1 (EOL) / 2 (legacy JOY_FLAG) / 8 (.qsf staged) — git
# index-state noise at `git merge --no-commit`, not a wiring break; still
# printed by step6_verify as info, just never gated here.
BLOCKING_STEP6=" 3 4 4b 5 6 7 10 "

BASELINE_FILE="${RUNNER_TEMP:-/tmp}/db9_merge_validate_baseline.txt"

usage() { echo "usage: $0 {baseline|check} <core_dir>" >&2; exit 2; }

# Print the sorted, unique set of BLOCKING failure tokens for <core_dir>:
#   portmap        emu_portmap_check.py exited non-zero (defect/parse error)
#   no-core-sv     no <core>.sv resolvable (portmap could not pick a top)
#   step6-<id>     a blocking Step-6 check FAILed (id in BLOCKING_STEP6)
compute_tokens() {
  local dir="$1"
  local pm rc=0 csv s6 toks=() id
  pm="$(python3 "$PORTMAP" "$dir" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] && toks+=("portmap")
  csv="$(printf '%s\n' "$pm" | sed -n 's/^  portmap-coresv: //p')"
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
  fi
  [ "${#toks[@]}" -eq 0 ] && return 0
  printf '%s\n' "${toks[@]}" | sort -u
}

[ "$#" -eq 2 ] || usage
MODE="$1"
CORE_DIR="${2%/}"
[ -d "$CORE_DIR" ] || { echo "merge_validate: core dir not found: $CORE_DIR" >&2; exit 2; }

case "$MODE" in
  baseline)
    if compute_tokens "$CORE_DIR" > "$BASELINE_FILE"; then :; fi
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
