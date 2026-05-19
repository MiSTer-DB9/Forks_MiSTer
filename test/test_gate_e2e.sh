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

if ! echo "$OUT" | grep -q '^PASS_TB'; then
    echo
    echo "FAIL: v1.5 key gate end-to-end test failed" >&2
    echo "      Verilog/Python SipHash interop or byte-order regression." >&2
    exit 1
fi

echo "== Step 6: C parity (siphash24.c == db9_sign.py == Verilog) =="
# Steps 4-5 already proved Python signer == Verilog gate (PASS_TB) on the
# signed payload. This closes the triangle: the byte-identical mirror
# siphash24.c (run_tier0 cmp-guards it against Main_MiSTer/siphash24.c) must
# compute the SAME tag as db9_sign.py for (a) the real signed payload and
# (b) the canonical Aumasson vectors. A C-side rotate/endian/finalization
# drift dies Main_MiSTer Saturn unlock fleet-wide while every FPGA test
# stays green — this is the only check that sees it.
if ! command -v cc >/dev/null 2>&1; then
    echo "   SKIP: no cc — C parity not exercised (bare box; CI has cc)"
    echo
    echo "OK: v1.5 key gate end-to-end PASS"
    echo "    (Python signer == Verilog verifier on fresh MASTER_ROOT;"
    echo "     C parity skipped — no compiler)"
    exit 0
fi

if ! cc -O2 -o "$WORK/sip_cli" "$SCRIPTS/siphash24_cli.c" "$SCRIPTS/siphash24.c" \
     2>"$WORK/cc.log"; then
    echo "FAIL: siphash24.c mirror did not compile" >&2
    sed 's/^/    /' "$WORK/cc.log" >&2
    exit 1
fi

# Emit "<sip_key_hex> <payload_hex> <python_tag_hex> <onfile_tag_hex>" for the
# real signed key: sip_key = MASTER_ROOT[:16], payload = key file [0:32],
# python_tag = db9_sign.siphash24(payload, sip_key), onfile = file [40:48].
read -r KHEX PHEX PYTAG ONFILE < <(
  python3 - "$SCRIPTS" "$WORK/master/master_root.bin" "$WORK/test.key" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from db9_sign import siphash24
sip_key = open(sys.argv[2], "rb").read()[:16]
data    = open(sys.argv[3], "rb").read()
payload = data[:32]
print(sip_key.hex(), payload.hex(),
      siphash24(payload, sip_key).hex(), data[40:48].hex())
PY
)
CTAG=$("$WORK/sip_cli" "$KHEX" "$PHEX")
if [ "$CTAG" != "$PYTAG" ] || [ "$CTAG" != "$ONFILE" ]; then
    echo "FAIL: SipHash C<->Python<->key drift on signed payload" >&2
    echo "      C=$CTAG  python=$PYTAG  on-file=$ONFILE" >&2
    exit 1
fi
echo "   signed-payload tag parity OK ($CTAG)"

# Canonical Aumasson vectors (key = 00 01 .. 0f), same triplet db9_sign.py's
# import-time _self_test() pins for Python — here proving C agrees too.
av_fail=0
check_vec() { # <msg_hex> <expected_tag_hex>
    local got; got=$("$WORK/sip_cli" "000102030405060708090a0b0c0d0e0f" "$1")
    if [ "$got" != "$2" ]; then
        echo "FAIL: Aumasson vector msg='$1' C=$got want=$2" >&2
        av_fail=1
    fi
}
check_vec ""                                       "310e0edd47db6f72"
check_vec "00"                                     "fd67dc93c539f874"
check_vec "000102030405060708090a0b0c0d0e"         "e545be4961ca29a1"
[ "$av_fail" -eq 0 ] || exit 1
echo "   Aumasson reference vectors OK (C == spec == db9_sign.py)"

echo
echo "OK: v1.5 key gate end-to-end PASS"
echo "    (Python signer == Verilog verifier == siphash24.c on fresh"
echo "     MASTER_ROOT + Aumasson vectors)"
exit 0
