#!/usr/bin/env bash
# Tier 1 - canonical HDL data-path regression (pure software, CI, seconds).
#
# 1. Dialect-matched lint of every canonical Forks_MiSTer/fork_ci_template/sys
#    source (.v -> iverilog -g2005, .sv -> -g2012). Linting a .v with -g2012
#    silently accepts SV-only constructs Quartus then rejects (the fork docs), so
#    the dialect MUST match the extension.
# 2. Self-checking DB15 decoder + unified-wrapper testbenches.
#
# Canonical sys/* is copied verbatim into every ported core, so one pass here
# protects every port. DB15-only by design (simplest path); extend with
# tb_joydb9md.v / Saturn later.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYS="$(cd "$HERE/../fork_ci_template/sys" && pwd)"
SIM="$HERE/sim"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tier1.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '  %s\n' "$*"; }

echo "== Tier 1: canonical sys/ lint =="
# $1=glob (*.v|*.sv)  $2=dialect (-g2005|-g2012)  $3=label
# Standalone files lint alone; key-gate-coupled ones need siblings/secret ->
# retry with the full sys set + incdir.
lint_dialect() {
  local f b
  for f in "$SYS"/$1; do
    b=$(basename "$f")
    if iverilog -tnull "$2" -I "$SYS" "$f" >"$WORK/lint.log" 2>&1; then
      note "lint OK   ($3) $b"
    elif iverilog -tnull "$2" -I "$SYS" "$SYS"/*.sv "$SYS"/*.v "$SYS"/*.vh \
         >"$WORK/lint.log" 2>&1; then
      note "lint OK   ($3, with sys deps) $b"
    else
      note "lint FAIL ($3) $b"; sed 's/^/    /' "$WORK/lint.log"; fail=1
    fi
  done
}
lint_dialect '*.v'  -g2005 v2005
lint_dialect '*.sv' -g2012 sv2012

echo "== Tier 1: tb_joydb15 (DB15 decoder, v2005) =="
if iverilog -g2005 -o "$WORK/tb15.vvp" -s tb_joydb15 \
     "$SIM/tb_joydb15.v" "$SYS/joydb15.v" >"$WORK/c15.log" 2>&1 \
   && vvp "$WORK/tb15.vvp" 2>&1 | tee "$WORK/r15.log" \
   && grep -q "TIER1 tb_joydb15: PASS" "$WORK/r15.log"; then
  note "tb_joydb15 PASS"
else
  note "tb_joydb15 FAIL"; sed 's/^/    /' "$WORK/c15.log" 2>/dev/null || true; fail=1
fi

echo "== Tier 1: tb_joydb_wrapper (joydb.sv, sv2012) =="
if iverilog -g2012 -o "$WORK/tbw.vvp" -s tb_joydb_wrapper \
     "$SIM/tb_joydb_wrapper.sv" "$SYS/joydb.sv" "$SYS/joydb15.v" \
     "$SYS/joydb9md.v" "$SYS/joydb9saturn.v" "$SYS/joydb_remap.sv" >"$WORK/cw.log" 2>&1 \
   && vvp "$WORK/tbw.vvp" 2>&1 | tee "$WORK/rw.log" \
   && grep -q "TIER1 tb_joydb_wrapper: PASS" "$WORK/rw.log"; then
  note "tb_joydb_wrapper PASS"
else
  note "tb_joydb_wrapper FAIL"; sed 's/^/    /' "$WORK/cw.log" 2>/dev/null || true; fail=1
fi

echo "== Tier 1: joydb_map_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_joydb_map_check.py" >"$WORK/jm.log" 2>&1 \
   && grep -q "JOYDBMAP selftest: PASS" "$WORK/jm.log"; then
  note "joydb_map_check selftest PASS"
else
  note "joydb_map_check selftest FAIL"; sed 's/^/    /' "$WORK/jm.log"; fail=1
fi

echo "== Tier 1: mt32_gate_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_mt32_gate_check.py" >"$WORK/mg.log" 2>&1 \
   && grep -q "MT32GATE selftest: PASS" "$WORK/mg.log"; then
  note "mt32_gate_check selftest PASS"
else
  note "mt32_gate_check selftest FAIL"; sed 's/^/    /' "$WORK/mg.log"; fail=1
fi

echo "== Tier 1: snac_active_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_snac_active_check.py" >"$WORK/sn.log" 2>&1 \
   && grep -q "SNAC selftest: PASS" "$WORK/sn.log"; then
  note "snac_active_check selftest PASS"
else
  note "snac_active_check selftest FAIL"; sed 's/^/    /' "$WORK/sn.log"; fail=1
fi

echo "== Tier 1: key-gate end-to-end (db9_sign.py <-> siphash24.v) =="
# Hermetic: signer trio in test/lib, canonical gate HDL in
# fork_ci_template/sys. Catches the 27e624f class (db9_key_gate shift-reg /
# feature_mask regression) + Python<->Verilog SipHash byte-order drift.
if bash "$HERE/test_gate_e2e.sh" >"$WORK/ge.log" 2>&1 \
   && grep -q "v1.5 key gate end-to-end PASS" "$WORK/ge.log"; then
  note "test_gate_e2e PASS"
else
  note "test_gate_e2e FAIL"; sed 's/^/    /' "$WORK/ge.log" | tail -25; fail=1
fi

echo "== Tier 1: confstr_joytype_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_confstr_joytype_check.py" >"$WORK/cf.log" 2>&1 \
   && grep -q "CONFSTR selftest: PASS" "$WORK/cf.log"; then
  note "confstr_joytype_check selftest PASS"
else
  note "confstr_joytype_check selftest FAIL"; sed 's/^/    /' "$WORK/cf.log"; fail=1
fi

echo "== Tier 1: qip_registration_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_qip_registration_check.py" >"$WORK/qr.log" 2>&1 \
   && grep -q "QIPREG selftest: PASS" "$WORK/qr.log"; then
  note "qip_registration_check selftest PASS"
else
  note "qip_registration_check selftest FAIL"; sed 's/^/    /' "$WORK/qr.log"; fail=1
fi

echo "== Tier 1: marker_nesting_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_marker_nesting_check.py" >"$WORK/mn.log" 2>&1 \
   && grep -q "MARKERNEST selftest: PASS" "$WORK/mn.log"; then
  note "marker_nesting_check selftest PASS"
else
  note "marker_nesting_check selftest FAIL"; sed 's/^/    /' "$WORK/mn.log"; fail=1
fi

echo "== Tier 1: verilog_precedence_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_verilog_precedence_check.py" >"$WORK/vp.log" 2>&1 \
   && grep -q "VPREC selftest: PASS" "$WORK/vp.log"; then
  note "verilog_precedence_check selftest PASS"
else
  note "verilog_precedence_check selftest FAIL"; sed 's/^/    /' "$WORK/vp.log"; fail=1
fi

echo "== Tier 1: saturn_gate_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_saturn_gate_check.py" >"$WORK/sg.log" 2>&1 \
   && grep -q "SATGATE selftest: PASS" "$WORK/sg.log"; then
  note "saturn_gate_check selftest PASS"
else
  note "saturn_gate_check selftest FAIL"; sed 's/^/    /' "$WORK/sg.log"; fail=1
fi

echo "== Tier 1: joydb_binding_check selftest (synth fixtures, no iverilog) =="
if python3 "$HERE/lib/test_joydb_binding_check.py" >"$WORK/jb.log" 2>&1 \
   && grep -q "JOYDBBIND selftest: PASS" "$WORK/jb.log"; then
  note "joydb_binding_check selftest PASS"
else
  note "joydb_binding_check selftest FAIL"; sed 's/^/    /' "$WORK/jb.log"; fail=1
fi

echo "== Tier 1: forks_ini_check selftest (fixtures, no iverilog) =="
if python3 "$HERE/lib/test_forks_ini_check.py" >"$WORK/fi.log" 2>&1 \
   && grep -q "FORKSINI selftest: PASS" "$WORK/fi.log"; then
  note "forks_ini_check selftest PASS"
else
  note "forks_ini_check selftest FAIL"; sed 's/^/    /' "$WORK/fi.log"; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "TIER1: PASS"; exit 0; else echo "TIER1: FAIL"; exit 1; fi
