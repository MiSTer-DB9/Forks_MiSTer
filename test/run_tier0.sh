#!/usr/bin/env bash
# Tier 0 - porter / framework regression (pure software, hermetic, seconds).
#
# port_core_full.py + upgrade_pro_additive.py form a deterministic, idempotent
# text transform; apply_db9_framework.sh additionally copies the canonical
# fork_ci_template/sys/* verbatim. A regression in any of those silently
# breaks every core on the next CI sync.
#
# Hermetic strategy (no network, no synthetic fixture to keep in sync with
# 900+ lines of regex anchors): take a real, already-ported in-tree core as
# BOTH input and golden. Re-applying the framework to it must be a no-op
# (the scripts are documented idempotent). Any diff = porter regression OR
# canonical-source drift vs what is checked into cores. Plus the factored
# Step-6 checklist and the existing cross-fork audits.
#
# Default golden core: InputTest_MiSTer (small, dedicated input core, ported).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORKS="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$FORKS/.." && pwd)"
# Default golden = SMS_MiSTer: small console core, SerJoystick family, key
# gate properly wired (.saturn_unlocked(saturn_unlocked)) — representative.
# (InputTest_MiSTer ties saturn_unlocked=1'b1 by design, so it is NOT a
#  representative golden for the key-gate wiring check.)
CORE="${TIER0_CORE:-SMS_MiSTer}"
CORE_SV="${TIER0_CORE_SV:-SMS.sv}"
SRC="$ROOT/$CORE"
SYS_CANON="$FORKS/fork_ci_template/sys"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tier0.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '  %s\n' "$*"; }
[ -d "$SRC" ] || { echo "core not found: $SRC"; exit 2; }

DST="$WORK/$CORE"
echo "== Tier 0: stage clean copy of $CORE =="
rsync -a --exclude '.git' "$SRC/" "$DST/"
git -C "$DST" init -q
git -C "$DST" -c user.email=t@t -c user.name=t add -A
git -C "$DST" -c user.email=t@t -c user.name=t commit -qm baseline
note "baseline committed ($(git -C "$DST" rev-parse --short HEAD))"

echo "== Tier 0: apply_db9_framework (pass 1) =="
( cd "$FORKS" && bash apply_db9_framework.sh "$DST" ) >"$WORK/apply1.log" 2>&1 \
  || { note "apply pass 1 FAILED"; sed 's/^/    /' "$WORK/apply1.log"; exit 1; }
note "applied"

echo "== Tier 0: golden / idempotency — porter must be a no-op on $CORE_SV =="
if git -C "$DST" diff --quiet -- "$CORE_SV"; then
  note "ok   $CORE_SV unchanged by re-port (idempotent)"
else
  note "FAIL $CORE_SV changed by re-application — porter regression or core out of sync:"
  git -C "$DST" --no-pager diff -- "$CORE_SV" | sed 's/^/    /' | head -60
  fail=1
fi

echo "== Tier 0: canonical sys/* byte-identical to fork_ci_template/sys =="
for b in joydb9md.v joydb15.v joydb9saturn.v joydb.sv siphash24.v \
         db9_key_gate.sv db9_key_secret.vh; do
  if cmp -s "$SYS_CANON/$b" "$DST/sys/$b"; then
    note "ok   sys/$b identical"
  else
    note "FAIL sys/$b differs from canonical"; fail=1
  fi
done

echo "== Tier 0: idempotency — apply_db9_framework (pass 2) =="
if ! ( cd "$FORKS" && bash apply_db9_framework.sh "$DST" ) >"$WORK/apply2.log" 2>&1; then
  note "FAIL apply pass 2 returned nonzero:"; sed 's/^/    /' "$WORK/apply2.log"; fail=1
elif git -C "$DST" diff --quiet -- "$CORE_SV"; then
  note "ok   second pass also a no-op"
else
  note "FAIL second pass changed $CORE_SV (not idempotent)"; fail=1
fi

echo "== Tier 0: Step-6 checklist (factored) =="
# shellcheck source=lib/step6.sh
source "$HERE/lib/step6.sh"
step6_verify "$DST" "$CORE_SV" || fail=1

echo "== Tier 0: existing cross-fork audits =="
run_audit() {
  local name="$1"; shift
  local rc=0
  "$@" >"$WORK/$name.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    note "ok   $name"
  else
    note "FAIL $name (rc=$rc)"; tail -15 "$WORK/$name.log" | sed 's/^/    /'; fail=1
  fi
}
run_audit hps_io_width      "$FORKS/../the relocated test/lib helper"
run_audit status_collisions "$FORKS/../the relocated test/lib helper"
run_audit gate_e2e          "$FORKS/../the relocated test/lib helper"

echo
if [ "$fail" -eq 0 ]; then echo "TIER0: PASS"; exit 0; else echo "TIER0: FAIL"; exit 1; fi
