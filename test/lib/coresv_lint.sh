#!/usr/bin/env bash
# Per-core <core>.sv structural lint (porter / merge regression).
#
# tier1 lints the canonical Forks_MiSTer/fork_ci_template/sys sources, but the
# porter (port_core_full.py) and an upstream merge both rewrite the per-core
# <core>.sv that tier1 never sees. A regex bug there has shipped broken Verilog
# straight to the ~15-min Quartus build before failing — e.g. an OSD_STATUS
# guard wrap that produced `joydb_1[4) : 0]}` (commit 43db15c), or a greedy
# regex that stripped a SNAC fall-through arm (995e9cc). This is the cheap
# pre-Quartus guard for that class.
#
# MECHANISM: a comment/string-masked DELIMITER-BALANCE check of the top
# <core>.sv — every (), [], {} must nest and close. That is exactly what a
# porter-regex / merge corruption breaks (`[4) : 0]}` mismatches a bracket;
# a severed arm drops a brace), and a delimiter imbalance cannot occur in
# Verilog Quartus accepts (the core would not synthesise). It is therefore
# ZERO false-positive by construction.
#
# Why not a parser (verilator/iverilog): tried, rejected. Across the full
# fleet, FOSS parsers reject many Quartus-VALID idioms — a trailing comma in
# a concatenation `{a,b,}` (SAM-Coupe, QBert), a string literal as a concat
# operand `{32'd0,x,"RT"}` (GBA), and (when leaf RTL is reachable) V2001
# `.do(...)` named ports (`do` is an SV keyword: SNES/Amstrad/SGB). None of
# those are bitstream defects; all produced pure false positives that wedged
# the absolute fleet audit. verilator is not a Quartus oracle. Balance is.
#
# A masked balance check (only `"`-strings / `//` / `/* */` are blanked,
# length-preserving — Verilog `'` is a base literal/cast, never a string)
# is immune to every one of those idioms (they are all delimiter-balanced)
# yet still catches the 43db15c/995e9cc corruption class. Pure Python, no
# verilator / iverilog / network — so it is a REAL gate everywhere,
# including the per-fork sync container (no longer best-effort/SKIP there).
#
#   coresv_lint.sh <core_dir> [<core_sv_basename>]
#
# Emits one machine line `  coresv-lint: PASS|FAIL` (matches the
# `portmap-coresv:` / `snac-coresv:` convention the runners already parse).
# Exit: 0 = PASS, 1 = FAIL (delimiter imbalance), 2 = could not resolve
#       <core>.sv (callers are fail-open on 2, exactly like the python
#       checks' parse-error tier).

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

python3 - "$CORE_DIR/$csv" "$csv" <<'PY'
import re, sys

path, label = sys.argv[1], sys.argv[2]
# latin1 round-trips every byte (no UTF-8 decode error, no line-ending
# mutation) — we only ever inspect ASCII delimiters.
src = open(path, "rb").read().decode("latin1")

def mask(s):
    # length-preserving blanking of // , /* */ and "..." so a delimiter
    # inside a comment or string is never counted. ONLY double quotes are
    # strings — Verilog `'` is a base literal (`1'b0`, `'h1F`) or assignment
    # pattern (`'{...}`), never a string, so it must NOT open a masked span.
    out, i, n = [], 0, len(s)
    while i < n:
        t = s[i:i + 2]
        if t == "//":
            j = s.find("\n", i); j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif t == "/*":
            j = s.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append(" " * (j - i)); i = j
        elif s[i] == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            j = min(j + 1, n); out.append(" " * (j - i)); i = j
        else:
            out.append(s[i]); i += 1
    return "".join(out)

m = mask(src)
PAIR = {")": "(", "]": "[", "}": "{"}
OPEN = set("([{")
stack = []          # (char, line)
line = 1
fail = None
for ch in m:
    if ch == "\n":
        line += 1
        continue
    if fail:
        continue
    if ch in OPEN:
        stack.append((ch, line))
    elif ch in PAIR:
        if not stack:
            fail = (line, f"unmatched closing '{ch}' "
                          f"(no open delimiter)")
        elif stack[-1][0] != PAIR[ch]:
            o, ol = stack[-1]
            fail = (line, f"'{ch}' closes a '{o}' opened at line {ol} "
                          f"(mismatched delimiter — porter/merge "
                          f"corruption, e.g. the 43db15c `[4) : 0]}}` class)")
        else:
            stack.pop()
if not fail and stack:
    o, ol = stack[-1]
    fail = (ol, f"'{o}' opened here is never closed "
                f"(severed block — the 995e9cc class)")

def region_of(ln):
    # nearest preceding fork marker, for a localised message.
    best = None
    for mt in re.finditer(r"\[MiSTer-DB9(?:-Pro)? (?:BEGIN|END)\][^\n]*",
                          src):
        if src.count("\n", 0, mt.start()) + 1 <= ln:
            best = mt.group(0)
    return best

if fail:
    ln, why = fail
    print(f"  coresv-lint: FAIL ({label}) — line {ln}: {why}")
    reg = region_of(ln)
    if reg:
        print(f"    nearest fork marker above: {reg}")
    ctx = src.splitlines()[max(0, ln - 1)] if ln <= len(
        src.splitlines()) else ""
    if ctx.strip():
        print(f"    {ln}: {ctx.strip()[:100]}")
    sys.exit(1)

print(f"  coresv-lint: PASS  ({label}, delimiter-balance)")
sys.exit(0)
PY
