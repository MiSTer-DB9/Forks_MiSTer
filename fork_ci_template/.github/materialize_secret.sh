#!/usr/bin/env bash
# [MiSTer-DB9-Pro BEGIN] - materialize MASTER_ROOT secret for v1.5 key gate
#
# Sourced by push_release.sh / sync_release.sh before the build step.
# This template ships canonically in Forks_MiSTer/fork_ci_template/.github/
# and is sync-copied into every fork's .github/ (including Main_MiSTer).
#
# Auto-detects target by what's in pwd:
#   - HPS build  (Main_MiSTer):   has  ./db9_key.cpp        → write  db9_key_secret.h
#   - FPGA build (HDL cores):     has  ./sys/db9_key_gate.sv → write  sys/db9_key_secret.vh
#   - Both:                       writes both (harmless: each build only consumes one)
#
# Verilog `256'h<HEX>` parses MSB-first; C/Python siphash24 reads bytes 0..15
# as LE integers. The .vh literal is byte-reversed so Verilog's bit 0..7 of
# MASTER_ROOT == byte 0 of master_root.bin.
#
# Fail modes (both converge on "all gated features locked"):
#   - HPS  : no header written → __has_include skips → DB9_KEY_ENABLE undef
#            → db9_key_refresh() is a no-op stub (fail-CLOSED).
#   - FPGA : 256'h0 placeholder shipped in fork_ci_template/sys/ stays in
#            place → SipHash never matches a signed key (fail-OPEN, but
#            functionally equivalent: every key file rejected).
set -euo pipefail

if [[ -z "${MASTER_ROOT_HEX:-}" ]] || [[ ! "${MASTER_ROOT_HEX}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "[DB9-Key v1.5] WARNING: MASTER_ROOT_HEX not set or malformed — build will ship locked"
    exit 0
fi

wrote_anything=0

# ---- HPS-side: db9_key_secret.h ----
if [[ -f db9_key.cpp ]]; then
    python3 - <<PY
import os
b = bytes.fromhex(os.environ["MASTER_ROOT_HEX"].strip())
rows = ",\n\t".join(", ".join(f"0x{x:02x}" for x in b[i:i+8]) for i in range(0, 32, 8))
with open("db9_key_secret.h", "w") as f:
    f.write("// CI-injected v1.5 MASTER_ROOT (do not commit)\n")
    f.write("#pragma once\n#include <stdint.h>\n")
    f.write(f"static const uint8_t MASTER_ROOT[32] = {{\n\t{rows}\n}};\n")
PY
    echo "[DB9-Key v1.5] db9_key_secret.h materialized"
    wrote_anything=1
fi

# ---- FPGA-side: sys/db9_key_secret.vh ----
if [[ -f sys/db9_key_gate.sv ]]; then
    LE_HEX=$(echo -n "${MASTER_ROOT_HEX}" | fold -w2 | tac | tr -d '\n')
    cat > sys/db9_key_secret.vh <<EOF
// CI-injected per build run; do not commit. Generated from MASTER_ROOT_HEX.
// HEX is byte-reversed so Verilog's bit 0..7 of MASTER_ROOT = byte 0 of master_root.bin.
\`ifndef DB9_KEY_SECRET_VH
\`define DB9_KEY_SECRET_VH
\`define MASTER_ROOT 256'h${LE_HEX}
\`endif
EOF
    echo "[DB9-Key v1.5] sys/db9_key_secret.vh materialized (LE-encoded)"
    wrote_anything=1
fi

if [[ "${wrote_anything}" = "0" ]]; then
    echo "[DB9-Key v1.5] no target detected (no db9_key.cpp, no sys/db9_key_gate.sv) — nothing to do"
fi
# [MiSTer-DB9-Pro END]
