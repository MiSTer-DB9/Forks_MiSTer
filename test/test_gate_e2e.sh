#!/usr/bin/env bash
# v1.5 key gate end-to-end regression test.
#
# Exercises the full chain: db9_keygen.py → db9_sign.py → db9_verify.py
# → byte-reversed `define MASTER_ROOT` → Verilog gate (db9_key_gate.sv +
# siphash24.v) under iverilog. Asserts saturn_unlocked goes high on a valid
# key and stays low on a tampered tag.
#
# Catches:
#   - byte-order mismatch between Python signing and Verilog (the
#     fold|tac|tr trick in materialize_secret.sh)
#   - SipHash MAC drift between siphash24.{v,c} and db9_sign.py
#   - gate FSM correctness (40-byte capture, start_sip pulse, eq compare)
#   - feature_mask latch wiring to saturn_unlocked
#
# Lives in the Forks_MiSTer repo (test/) so it is self-contained for the
# regression_tests.yml CI checkout — the umbrella test/lib/ is NOT in
# this repo. The signer trio (db9_keygen/sign/verify.py) is mirrored into
# test/lib/ for a hermetic run; SipHash-2-4 is a fixed spec pinned by
# db9_sign.py's import-time Aumasson `_self_test()` and by this very e2e
# (Python signer must equal siphash24.v), so a stray divergence from the
# production signer (Mint-DB9-Key / test/lib) cannot pass silently.
#
# Run from anywhere (resolves paths off this script's location).
# Requires: python3, iverilog, vvp.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Forks_MiSTer/test
SCRIPTS="$HERE/lib"                                    # hermetic signer trio
# Canonical gate sources (db9_key_gate.sv, siphash24.v) live next door under
# fork_ci_template/sys. Overridable for non-standard checkouts (Tier-0).
SYS="${GATE_E2E_SYS:-$HERE/../fork_ci_template/sys}"

if [[ ! -f "$SCRIPTS/db9_keygen.py" ]]; then
    echo "FAIL: $SCRIPTS/db9_keygen.py not found — wrong layout?" >&2
    exit 1
fi
if [[ ! -f "$SYS/db9_key_gate.sv" || ! -f "$SYS/siphash24.v" ]]; then
    echo "FAIL: canonical gate sources not found in $SYS — wrong layout?" >&2
    echo "      (set GATE_E2E_SYS to override)" >&2
    exit 1
fi
for tool in python3 iverilog vvp; do
    command -v "$tool" >/dev/null || { echo "FAIL: missing $tool" >&2; exit 1; }
done

WORK=$(mktemp -d -t db9-e2e.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "== Step 1: generate fresh MASTER_ROOT =="
python3 "$SCRIPTS/db9_keygen.py" --out "$WORK/master" --force >/dev/null

echo "== Step 2: sign a test key (customer 42, saturn, 1 day) =="
python3 "$SCRIPTS/db9_sign.py" \
    --root "$WORK/master/master_root.bin" \
    --customer-id 42 --features saturn --validity-days 1 \
    --out "$WORK/test.key" >/dev/null

echo "== Step 3: verify roundtrip (Python signer ↔ Python verifier) =="
python3 "$SCRIPTS/db9_verify.py" --root "$WORK/master/master_root.bin" "$WORK/test.key" \
    | tail -1 | grep -q "VERIFICATION OK" \
    || { echo "FAIL: db9_verify rejected a freshly-signed key" >&2; exit 1; }

echo "== Step 4: build Verilog testbench =="
ROOT_HEX=$(cat "$WORK/master/master_root.hex")
LE_HEX=$(echo -n "$ROOT_HEX" | fold -w2 | tac | tr -d '\n')

python3 - "$WORK/test.key" "$WORK/tb.v" "$LE_HEX" <<'PY'
import sys
key_path, tb_path, le_hex = sys.argv[1:]
data = open(key_path, 'rb').read()
spi = data[:32] + data[40:48]                  # 32B payload + 8B auth_tag
words = [spi[2*i] | (spi[2*i+1] << 8) for i in range(20)]

tb = ['`timescale 1ns/1ns',
      f'`define MASTER_ROOT 256\'h{le_hex}',
      'module tb;',
      '  reg clk = 0; always #5 clk = ~clk;',
      '  reg cmd_db9 = 0; reg [5:0] byte_cnt = 0; reg [15:0] io_din = 0;',
      '  wire [31:0] feature_mask; wire saturn_unlocked;',
      '  db9_key_gate #(.MASTER_ROOT(`MASTER_ROOT)) dut (',
      '    .clk(clk), .cmd_db9(cmd_db9), .byte_cnt(byte_cnt), .io_din(io_din),',
      '    .feature_mask(feature_mask), .saturn_unlocked(saturn_unlocked));',
      '  reg [15:0] words [0:19];',
      '  integer i; integer fails = 0;',
      '  task stream;', '    input tamper;', '    begin',
      '      @(posedge clk); @(posedge clk);',
      '      cmd_db9 <= 1;',
      # Hold each byte_cnt for 8 cycles to mimic SPI timing on real silicon
      # (hps_io keeps cmd_db9 high for the entire transaction; only io_strobe
      # pulses per word). Indexed-slice writes are idempotent under this hold;
      # a shift-register implementation would scramble payload here.
      '      for (i = 0; i < 20; i = i + 1) begin',
      '        byte_cnt <= i + 1;',
      '        io_din   <= (tamper && i == 19) ? (words[i] ^ 16\'h0001) : words[i];',
      '        repeat (8) @(posedge clk);',
      '      end',
      '      cmd_db9 <= 0; byte_cnt <= 0;',
      '      repeat (40) @(posedge clk);',
      '    end',
      '  endtask',
      '  initial begin']
for i, w in enumerate(words):
    tb.append(f'    words[{i:2d}] = 16\'h{w:04x};')
tb += [
    '    // Test 1: valid key → unlock',
    '    stream(0);',
    '    if (feature_mask !== 32\'h1 || saturn_unlocked !== 1\'b1) begin',
    '      $display("FAIL valid: feature_mask=%h saturn_unlocked=%b", feature_mask, saturn_unlocked);',
    '      fails = fails + 1;',
    '    end',
    '    // Test 2: tampered tag → still locked',
    '    stream(1);',
    '    if (feature_mask !== 32\'h0 || saturn_unlocked !== 1\'b0) begin',
    '      $display("FAIL tamper: feature_mask=%h saturn_unlocked=%b", feature_mask, saturn_unlocked);',
    '      fails = fails + 1;',
    '    end',
    '    if (fails == 0) $display("PASS_TB");',
    '    else            $display("FAIL_TB %0d", fails);',
    '    $finish;',
    '  end',
    'endmodule',
]
open(tb_path, 'w').write('\n'.join(tb) + '\n')
PY

echo "== Step 5: compile + run Verilog gate sim =="
iverilog -g2012 -o "$WORK/tb.vvp" "$WORK/tb.v" \
    "$SYS/db9_key_gate.sv" "$SYS/siphash24.v"

OUT=$(vvp "$WORK/tb.vvp" 2>&1)
echo "$OUT" | grep -E '^(FAIL|PASS)' || true

if echo "$OUT" | grep -q '^PASS_TB'; then
    echo
    echo "OK: v1.5 key gate end-to-end PASS"
    echo "    (Python signer == Verilog verifier on fresh MASTER_ROOT)"
    exit 0
else
    echo
    echo "FAIL: v1.5 key gate end-to-end test failed" >&2
    echo "      Verilog/Python SipHash interop or byte-order regression." >&2
    exit 1
fi
