#!/usr/bin/env bash
# Per-core <core>.sv HDL syntax lint (porter / merge regression).
#
# tier1 lints the canonical Forks_MiSTer/fork_ci_template/sys sources, but the
# porter (port_core_full.py) and an upstream merge both rewrite the per-core
# <core>.sv that tier1 never sees. A regex bug there has shipped broken Verilog
# straight to the ~15-min Quartus build before failing — e.g. an OSD_STATUS
# guard wrap that produced `joydb_1[4) : 0]}` (commit 43db15c), or a greedy
# regex that stripped a SNAC fall-through arm (995e9cc). This is the cheap
# pre-Quartus syntax guard for that class.
#
# Parse-only, no full rtl tree: elaboration WILL report unresolved leaf
# modules — expected, NOT a failure. We gate ONLY on the substring
# "syntax error", which both linters use verbatim for a malformed token
# stream (broken bracket, dangling ternary, unbalanced brace) and which the
# missing-module / unable-to-bind / cannot-find-module elaboration noise never
# contains.
#
# Linter selection (in order):
#   1. verilator --lint-only -sv  — PREFERRED. Its SystemVerilog grammar is
#      Quartus-complete, so a clean core parses clean (no false positive on
#      the `'{ ... }` assignment-pattern array literal Genesis/AtariST/ao486
#      use). With verilator this is a TRUE pass/fail oracle.
#   2. iverilog -tnull -g2012/-g2005 — FALLBACK. iverilog's SV grammar is
#      INCOMPLETE vs Quartus and rejects valid `'{...}` literals, so on the
#      iverilog path a clean core can report "syntax error" even though it
#      builds. There it degrades to a REGRESSION-DELTA gate (merge_validate's
#      baseline/check cancels any token present pre-merge, so only a NEWLY
#      introduced syntax error wedges — exactly how step6/snac/mt32 behave).
#   3. neither tool present — SKIP, exit 2 (fail-open). merge_validate.sh runs
#      in the per-fork sync container, whose contract is "no Quartus, no
#      iverilog, no network"; this check must not add a HARD dependency there.
#      Where a linter IS guaranteed (Tier-0 maintainer tree, regression_tests
#      CI with verilator installed) it is a real gate; the sync path keeps it
#      best-effort, consistent with merge_validate's existing fail-open tier.
#
#   coresv_lint.sh <core_dir> [<core_sv_basename>]
#
# Emits one machine line `  coresv-lint: PASS|FAIL|SKIP` (matches the
# `portmap-coresv:` / `snac-coresv:` convention the runners already parse).
# Exit: 0 = PASS (or n/a), 1 = FAIL (syntax error), 2 = could not resolve
#       <core>.sv OR no linter available (callers are fail-open on 2, exactly
#       like the python checks' parse-error tier).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTMAP="$HERE/emu_portmap_check.py"
# extract_portmap_coresv() — single source of truth for the `portmap-coresv:`
# parse (step6.sh has a run-only guard, safe to source).
# shellcheck source=/dev/null
source "$HERE/step6.sh"

usage() { echo "usage: coresv_lint.sh <core_dir> [<core_sv_basename>]" >&2; exit 2; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
CORE_DIR="${1%/}"
[ -d "$CORE_DIR" ] || { echo "  coresv-lint: FAIL core dir not found: $CORE_DIR"; exit 2; }

# Resolve the top <core>.sv exactly the way merge_validate / run_fleet_audit
# already do: trust an explicitly-passed basename, else ask emu_portmap_check
# (single source of truth for "which .sv is the real top" — handles .qip/.qsf).
csv=""
if [ "$#" -eq 2 ] && [ -n "$2" ] && [ -f "$CORE_DIR/$2" ]; then
  csv="$2"
else
  csv="$(python3 "$PORTMAP" "$CORE_DIR" 2>/dev/null \
         | extract_portmap_coresv | head -1)"
fi
if [ -z "$csv" ] || [ ! -f "$CORE_DIR/$csv" ]; then
  echo "  coresv-lint: FAIL no <core>.sv resolvable in $CORE_DIR"
  exit 2
fi

# build_id.v is generated at build time by sys/build_id.tcl (Quartus) and is
# gitignored, so it is absent in a checked-out tree. `\`include "build_id.v"`
# then fails and cascades into a SPURIOUS "syntax error" on the next line on
# every clean core. Stub it in a private incdir (only used when the core has
# no real build_id.v at its own source dir, which takes precedence).
STUB="$(mktemp -d "${TMPDIR:-/tmp}/coresv_lint.XXXXXX")"
LOG="$STUB/lint.log"
trap 'rm -rf "$STUB"' EXIT
printf '`define BUILD_DATE "000000"\n' > "$STUB/build_id.v"

# Core's own include / library dirs so as much as possible elaborates (more
# resolved => more parse coverage); a missing dir is harmless.
INCDIRS=("$STUB")
for d in sys rtl; do [ -d "$CORE_DIR/$d" ] && INCDIRS+=("$CORE_DIR/$d"); done

if command -v verilator >/dev/null 2>&1; then
  TOOL=verilator
  # +incdir+a+b+c ; -y libdir per dir. --top-module emu: emu_portmap_check
  # resolved the .sv that declares `module emu` (handles bespoke cores too).
  vargs=(--lint-only -sv -Wno-fatal --top-module emu)
  inc="+incdir"; for d in "${INCDIRS[@]}"; do inc+="+$d"; done
  vargs+=("$inc")
  for d in "${INCDIRS[@]}"; do vargs+=(-y "$d"); done
  verilator "${vargs[@]}" "$CORE_DIR/$csv" >"$LOG" 2>&1 || true
elif command -v iverilog >/dev/null 2>&1; then
  TOOL=iverilog
  # Dialect MUST match the extension (the fork docs): .v -> 2005, .sv -> 2012.
  case "$csv" in *.sv) GVER=-g2012 ;; *) GVER=-g2005 ;; esac
  ivopts=()
  for d in "${INCDIRS[@]}"; do ivopts+=(-I "$d"); done
  for d in sys rtl; do [ -d "$CORE_DIR/$d" ] && ivopts+=(-y "$CORE_DIR/$d"); done
  iverilog -tnull "$GVER" "${ivopts[@]}" "$CORE_DIR/$csv" >"$LOG" 2>&1 || true
else
  echo "  coresv-lint: SKIP  no verilator/iverilog (fail-open) [$csv]"
  exit 2
fi

if grep -q 'syntax error' "$LOG"; then
  echo "  coresv-lint: FAIL ($csv, $TOOL) — Verilog syntax error:"
  grep -nE 'syntax error' "$LOG" | sed 's/^/    /' | head -20
  exit 1
fi

echo "  coresv-lint: PASS  ($csv, $TOOL)"
exit 0
