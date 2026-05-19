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

echo "== Tier 0: siphash24.{c,h} mirror byte-identical to Main_MiSTer =="
# test/lib/siphash24.{c,h} is a hermetic mirror so test_gate_e2e.sh can prove
# C<->Verilog parity without Main_MiSTer in the CI checkout. It MUST stay
# byte-identical to the shipped Main_MiSTer source or the parity proof is
# vacuous (same contract as the canonical sys/* cmp above).
MAIN_SIP="$ROOT/Main_MiSTer"
if [ -d "$MAIN_SIP" ]; then
  for b in siphash24.c siphash24.h; do
    if cmp -s "$MAIN_SIP/$b" "$HERE/lib/$b"; then
      note "ok   lib/$b mirrors Main_MiSTer"
    else
      note "FAIL lib/$b drifted from Main_MiSTer/$b (refresh the mirror)"; fail=1
    fi
  done
else
  note "skip siphash24 mirror cmp (Main_MiSTer not in umbrella tree)"
fi

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
# Per-core <core>.sv delimiter-balance lint on the freshly re-ported golden.
# A porter-regex regression that corrupts a delimiter (the 43db15c / 995e9cc
# class) fails Tier-0 here instead of 15 min into the Quartus build. Pure
# Python (no verilator/iverilog); exit 2 = <core>.sv unresolvable -> skip.
csl_rc=0
csl_out="$(bash "$HERE/lib/coresv_lint.sh" "$DST" "$CORE_SV" 2>&1)" || csl_rc=$?
case "$csl_rc" in
  0) note "ok   coresv_lint  ${csl_out##*  }" ;;
  2) note "skip coresv_lint  (${csl_out##*: }; <core>.sv unresolvable)" ;;
  *) note "FAIL coresv_lint"; printf '%s\n' "$csl_out" | sed 's/^/    /'; fail=1 ;;
esac
# Fork-marker nesting/balance on the re-ported golden (SNES dc15e64 class:
# orphan/wrong-family/unclosed markers step6 #4's count cannot see).
mn_rc=0
mn_out="$(python3 "$HERE/lib/marker_nesting_check.py" "$DST" "$CORE_SV" 2>&1)" || mn_rc=$?
case "$mn_rc" in
  0) note "ok   marker_nest  ${mn_out##*  }" ;;
  2) note "skip marker_nest  (<core>.sv unresolvable)" ;;
  *) note "FAIL marker_nest"; printf '%s\n' "$mn_out" | sed 's/^/    /'; fail=1 ;;
esac
# ||/&& bare-literal precedence over the golden's whole .v/.sv tree
# (3a94b0a constant-true-arm class).
vp_rc=0
vp_out="$(python3 "$HERE/lib/verilog_precedence_check.py" "$DST" 2>&1)" || vp_rc=$?
case "$vp_rc" in
  0) note "ok   vprec  ${vp_out##*  }" ;;
  2) note "skip vprec  (no .v/.sv)" ;;
  *) note "FAIL vprec"; printf '%s\n' "$vp_out" | sed 's/^/    /'; fail=1 ;;
esac
# saturn_unlocked AND-gate -- ADVISORY ONLY (SMS golden wires the real
# signal -> PASS; a tied test core would be WEAK, which is legit and only
# delta-gated in merge_validate, so Tier-0 never fails on it).
sg_out="$(python3 "$HERE/lib/saturn_gate_check.py" "$DST" "$CORE_SV" 2>&1)" || true
note "info saturn_gate  $(printf '%s\n' "$sg_out" | sed -n 's/^  satgate: //p')"
run_audit hps_io_width      "$HERE/lib/audit_hps_io_width.sh"
run_audit status_collisions "$HERE/lib/audit_status_collisions.sh"
run_audit gate_e2e          "$HERE/test_gate_e2e.sh"

echo
if [ "$fail" -eq 0 ]; then echo "TIER0: PASS"; exit 0; else echo "TIER0: FAIL"; exit 1; fi
