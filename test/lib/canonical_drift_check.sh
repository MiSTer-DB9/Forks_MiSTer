#!/usr/bin/env bash
# Canonical sys/* drift check.
#
# The shared fork sources in Forks_MiSTer/fork_ci_template/sys/ are the single
# source of truth (the fork rules). Every ported core's
# sys/<file> copy is regenerated verbatim from canonical by setup_cicd.sh's
# SYS_HELPERS loop and by local apply_db9_framework.sh runs -- per-core copies
# must NEVER be edited directly (the next sync silently overwrites them).
#
# Tier-0 only byte-checks the single golden core. This check closes that gap
# fleet-wide: a stale sync, a hand-edit to a per-core copy, or a botched
# framework run leaves a core diverged from canonical and untested. Pure
# sha256 compare, ~7 files x ~145 cores -> sub-second.
#
#   canonical_drift_check <core_dir>     # sourced (function) or executed
#
# Returns 0 if every present canonical file matches, 1 on drift. One line per
# file. db9_key_secret.vh is the only file legitimately CI-materialised from
# a secret, so a mismatch there is a non-gating FINDING (review), not FATAL.

CANON_FILES=(
  db9_key_gate.sv
  joydb.sv
  joydb15.v
  joydb9md.v
  joydb9saturn.v
  siphash24.v
)
# Materialised from MASTER_ROOT_HEX in CI -> mismatch is expected post-CI.
CANON_SOFT=(db9_key_secret.vh)

# Canonical sys/ resolved once at source/exec time (constant across the
# ~145-core fleet loop): a fork repo dereferenced via cp -rL carries only
# the materialised copies and no canonical to diff against -> stays empty,
# the function then no-ops as n/a (drift is an umbrella/Tier-0 check;
# merge_validate.sh deliberately does not call it).
_CANON_DRIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fork_ci_template/sys" \
  2>/dev/null && pwd)" || _CANON_DRIFT_DIR=""

canonical_drift_check() {
  local dir="${1%/}"
  local canon="$_CANON_DRIFT_DIR" rc=0 f cf pf p="drift:"
  [ -n "$canon" ] || {
    printf '  %s n/a  no canonical sys/ reference (not an umbrella tree)\n' \
      "$p"; return 0; }

  _d_ok()  { printf '  %s ok   %s\n' "$p" "$1"; }
  _d_bad() { printf '  %s FAIL %s\n' "$p" "$1"; rc=1; }
  _d_fnd() { printf '  %s FINDING %s\n' "$p" "$1"; }

  local checked=0
  for f in "${CANON_FILES[@]}"; do
    pf="$dir/sys/$f"; cf="$canon/$f"
    [ -f "$pf" ] || continue          # file not used by this core
    checked=$((checked+1))
    if [ ! -f "$cf" ]; then
      _d_bad "$f present in core but absent in canonical sys/"
    elif cmp -s "$pf" "$cf"; then
      :
    else
      _d_bad "$f drifted from canonical (per-core copy edited or stale sync)"
    fi
  done
  for f in "${CANON_SOFT[@]}"; do
    pf="$dir/sys/$f"; cf="$canon/$f"
    [ -f "$pf" ] && [ -f "$cf" ] || continue
    cmp -s "$pf" "$cf" || _d_fnd "$f differs from canonical (CI-materialised \
secret expected; review only)"
  done

  [ "$rc" -eq 0 ] && _d_ok "canonical sys/ in sync ($checked file(s) checked)"
  return $rc
}

# Standalone execution: canonical_drift_check.sh <core_dir>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  canonical_drift_check "$@"; exit $?
fi
