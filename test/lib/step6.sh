#!/usr/bin/env bash
# Reusable Step-6 per-core verify checklist.
#
# Single source of truth for the checks documented prose-style in
# the fork workflow notes "Step 6 — Verify each core before committing".
# WORKFLOW.md should reference this file instead of duplicating the bash.
#
#   step6_verify <core_dir> <core_sv_relpath>
#
# Returns 0 if every check passes, 1 otherwise. Prints one line per check.
# Run from inside (or with) a git work tree for the EOL / .qsf / status
# checks. Designed to be sourced or executed.

# Single-source parser for emu_portmap_check.py's machine-readable
# `  portmap-coresv: <basename>` line (the resolved top <core>.sv). Both
# run_fleet_audit.sh and merge_validate.sh feed portmap stdout through this so
# the output contract lives in exactly one place. Reads stdin.
extract_portmap_coresv() { sed -n 's/^  portmap-coresv: //p'; }

step6_verify() {
  local dir="$1" sv="$2"
  local f="$dir/$sv"
  local rc=0
  local p="step6:"

  _ok()   { printf '  %s ok   %s\n' "$p" "$1"; }
  _bad()  { printf '  %s FAIL %s\n' "$p" "$1"; rc=1; }
  _na()   { printf '  %s n/a  %s\n' "$p" "$1"; }

  [ -f "$f" ] || { _bad "core sv not found: $f"; return 1; }

  # Bespoke (non-wrapper) DB9 core: a hand-written inline DB9/DB15/Saturn
  # implementation that deliberately does NOT instantiate the `joydb joydb`
  # wrapper and (for some, e.g. Menu_MiSTer) does the key check in Main_MiSTer
  # instead of the FPGA db9_key_gate. Such a core legitimately lacks the
  # porter-standard shape, so the wrapper-shape checks (4 Pro-present, 4b
  # saturn_unlocked, 5 wrapper-instance, 6 *_DRIVE) are not applicable.
  # Predicate is generic (no core-name allowlist) and tight: no wrapper
  # instance AND the core drives USER_OUT/USER_OSD inline itself. A standard
  # core that merely lost its wrapper has no inline assigns -> still FAILs.
  local bespoke=0
  if ! grep -q 'joydb joydb' "$f" \
     && grep -qE '^[ \t]*assign[ \t]+USER_OUT\b'  "$f" \
     && grep -qE '^[ \t]*assign[ \t]+USER_OSD\b'  "$f"; then
    bespoke=1
  fi

  # 1. No CRLF/EOL noise introduced
  if [ "$(git -C "$dir" diff --stat | tail -1)" = \
       "$(git -C "$dir" diff --ignore-cr-at-eol --stat | tail -1)" ]; then
    _ok "1 no EOL noise"; else _bad "1 EOL noise in diff"; fi

  # 2. No legacy JOY_FLAG mux. The wrapper's `wire [2:0] JOY_FLAG` alias is
  #    intentionally consumed by per-core MT32/SNAC fallback (e.g.
  #    `~|JOY_FLAG[2:1]`), so a raw count is wrong — flag only the legacy
  #    decode mux (`JOY_FLAG[n] ? JOYDB...` / `joydb_N = ... JOY_FLAG`).
  if grep -qE 'JOY_FLAG\[[0-9]\] *\? *JOYDB|joydb_[12][a-z]* *=[^;]*JOY_FLAG' "$f"; then
    _bad "2 legacy JOY_FLAG decode/mux still present"
  else _ok "2 no legacy JOY_FLAG decode (alias wire allowed)"; fi

  # 3. USER_PP present
  if grep -q 'USER_PP' "$f"; then
    _ok "3 USER_PP present"; else _bad "3 USER_PP missing"; fi

  # 4. Marker balance + Pro present + saturn_unlocked wired.
  #    One awk pass for all four marker counts (vs four greps over the file).
  local db9b db9e prb pre
  eval "$(awk '
    /\[MiSTer-DB9 BEGIN\]/{b++} /\[MiSTer-DB9 END\]/{e++}
    /\[MiSTer-DB9-Pro BEGIN\]/{pb++} /\[MiSTer-DB9-Pro END\]/{pe++}
    END{printf "db9b=%d db9e=%d prb=%d pre=%d", b+0, e+0, pb+0, pe+0}' "$f")"
  if [ "$db9b" != "$db9e" ] || [ "$prb" != "$pre" ]; then
    _bad "4 marker imbalance (DB9 $db9b/$db9e Pro $prb/$pre)"
  elif [ "$prb" -ge 1 ]; then
    _ok "4 markers balanced (DB9 $db9b Pro $prb)"
  elif [ "$bespoke" = 1 ]; then
    _na "4 markers balanced, Pro absent (bespoke: key check in Main_MiSTer)"
  else
    _bad "4 no Pro markers (DB9 $db9b/$db9e Pro $prb/$pre)"
  fi
  # 4b. saturn_unlocked must be deliberately connected. A constant tie is
  #     allowed (InputTest_MiSTer ties 1'b1 — always-unlocked test core);
  #     the defect is an absent/undriven connection. Bespoke cores gate
  #     Saturn in Main_MiSTer, not via this port.
  if grep -qE '\.saturn_unlocked *\( *(saturn_unlocked|1.b[01]) *\)' "$f"; then
    _ok "4b saturn_unlocked wired"
  elif [ "$bespoke" = 1 ]; then _na "4b saturn_unlocked n/a (bespoke)"
  else _bad "4b saturn_unlocked not wired"; fi

  # 5. Wrapper instance present, no inline decoders. Bespoke cores
  #    intentionally inline the decode and have no wrapper instance.
  if [ "$bespoke" = 1 ]; then
    _na "5 inline DB9 decode (bespoke: no joydb wrapper by design)"
  elif grep -q 'joydb joydb' "$f" \
     && ! grep -q 'joy_db9md '     "$f" \
     && ! grep -q 'joy_db15 '      "$f" \
     && ! grep -q 'joy_db9saturn ' "$f"; then
    _ok "5 wrapper instance, no inline decoders";
  else _bad "5 wrapper/inline-decoder check"; fi

  # 6. USER_OUT / USER_PP composed from wrapper outputs. Bespoke cores
  #    drive USER_OUT/USER_PP via their own inline assigns, not *_DRIVE.
  if [ "$bespoke" = 1 ]; then
    _na "6 inline USER_OUT/USER_PP drive (bespoke)"
  elif grep -q 'USER_OUT_DRIVE' "$f" && grep -q 'USER_PP_DRIVE' "$f"; then
    _ok "6 USER_OUT_DRIVE/USER_PP_DRIVE composed";
  else _bad "6 *_DRIVE not composed"; fi

  # 7. joy_raw must come from the wrapper payload, not an inline legacy
  #    {joy_type,...} expr. OSD_STATUS guard is canonical but optional
  #    (some arcade cores bind .joy_raw(joy_raw_payload) directly).
  if grep -qE '\.joy_raw *\( *(OSD_STATUS *\? *)?joy_raw_payload' "$f"; then
    _ok "7 joy_raw from wrapper payload"
  elif grep -qE '\.joy_raw *\( *\{ *(joy_type|status\[)' "$f"; then
    _bad "7 joy_raw inline legacy expression (not wrapper payload)"
  elif grep -qE '\.joy_raw *\(' "$f"; then
    _ok "7 joy_raw bound (non-canonical arg — review)"
  else _bad "7 joy_raw not bound"; fi

  # 8. No .qsf STAGED. Quartus regenerates <core>.qsf every build, so it is
  #    perpetually modified-unstaged — normal, not a defect; only a *staged*
  #    .qsf violates "never commit the main qsf".
  if git -C "$dir" diff --cached --name-only 2>/dev/null | grep -qE '\.qsf$'; then
    _bad "8 .qsf STAGED (never commit main qsf)"
  else _ok "8 no .qsf staged"; fi

  # (9 = WORKFLOW.md "git status — expected files only", a manual visual
  #  step with no machine criterion; intentionally not automated here.)

  # 10. hps_io status width covers joy_type encoding
  local hpsf="" hps_w core_max
  for cand in "$dir/sys/hps_io.sv" "$dir/sys/hps_io.v"; do
    [ -f "$cand" ] && { hpsf="$cand"; break; }
  done
  if [ -n "$hpsf" ]; then
    hps_w=$(grep -m1 -oE 'output reg \[(31|63|127):0\] status,' "$hpsf" \
            | grep -oE '[0-9]+' | head -1)
    core_max=$(grep -hoE 'status\[[0-9]+(:[0-9]+)?\]' "$f" \
               | grep -oE '[0-9]+' | sort -n | tail -1)
    if [ "${core_max:-0}" -le "${hps_w:-0}" ]; then
      _ok "10 status width ok (core_max ${core_max:-0} <= hps ${hps_w:-0})";
    else
      _bad "10 status width: core uses [$core_max] > hps_io [$hps_w]"; fi
  else
    _bad "10 sys/hps_io.{sv,v} not found"; fi

  return $rc
}

# Allow standalone execution: step6.sh <core_dir> <core_sv_relpath>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  step6_verify "$@"; exit $?
fi
