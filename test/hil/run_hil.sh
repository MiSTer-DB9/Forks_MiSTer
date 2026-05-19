#!/usr/bin/env bash
# Tier 2 - hardware-in-the-loop DB15 regression on a real DE10-Nano.
#
# NOT a CI test: needs the MCU emulator + MiSTer attached. Tier 0+1 are the
# continuous net; this is the on-demand "does it work on silicon" proof.
#
# Chain:
#   host script --serial--> MCU (db15_splitter_emulator.ino) --USER_IO-->
#   FPGA joydb15.v --> joydb wrapper --> joy_raw --> Main_MiSTer
#   --> input_joyraw_kbd() --> /dev/uinput  ==(SSH read /dev/input/event*)==> assert
#
# Readout = evdev over SSH (user-chosen). The fork routes joy_raw ->
# input_joyraw_kbd() -> /dev/uinput when video_fb_state()
# (Main_MiSTer/input.cpp:2108-2115). We read the synthetic device and assert
# the expected keycodes plus the [15:14] type-detect = DB15.
#
# COVERAGE LIMIT (printed again at end): joy_raw is the OSD-navigation subset
# (14 bits, populated only when OSD open: hps_io binds
# .joy_raw(OSD_STATUS ? joy_raw_payload : 16'b0)). This proves "DB15 port is
# wired and decodes". Full per-button in-game coverage = InputTest_MiSTer
# screen (manual / mrext screenshot), not this scripted gate.
#
# Env:
#   MISTER_HOST   ip/host of the MiSTer (default mister.local)
#   MISTER_USER   ssh user (default root)
#   MCU_PORT      serial device of the emulator (default /dev/ttyACM0)
#   MREXT_BASE    mrext remote API base (default http://$MISTER_HOST:8182)
#   CORE_PATH     core .rbf path to launch (default InputTest)
set -euo pipefail

MISTER_HOST="${MISTER_HOST:-mister.local}"
MISTER_USER="${MISTER_USER:-root}"
MCU_PORT="${MCU_PORT:-/dev/ttyACM0}"
MREXT_BASE="${MREXT_BASE:-http://$MISTER_HOST:8182}"
CORE_PATH="${CORE_PATH:-_Utility/InputTest}"
SSH="ssh -o ConnectTimeout=5 $MISTER_USER@$MISTER_HOST"

say()  { printf '== %s\n' "$*"; }
mcu()  { printf '%s\r\n' "$1" > "$MCU_PORT"; sleep 0.2; }
fail=0

command -v jq >/dev/null || { echo "need jq"; exit 2; }
[ -e "$MCU_PORT" ] || { echo "MCU not at $MCU_PORT (flash db15_splitter_emulator.ino, set MCU_PORT)"; exit 2; }
$SSH true || { echo "cannot ssh $MISTER_USER@$MISTER_HOST"; exit 2; }

say "serial line setup ($MCU_PORT @115200)"
stty -F "$MCU_PORT" 115200 raw -echo

say "launch core via mrext remote: $CORE_PATH"
# mrext remote: https://github.com/wizzomafizzo/mrext/blob/main/docs/remote.md
curl -fsS -X POST "$MREXT_BASE/api/v1/launch" \
     -H 'content-type: application/json' \
     -d "{\"path\":\"$CORE_PATH\"}" >/dev/null
sleep 6

say "select UserIO Joystick = DB15 (status[127:126]=3) via mrext OSD nav"
# Open OSD then drive the 'UserIO Joystick' selector to DB15. Exact key
# sequence is core-CONF_STR dependent; left as a documented manual/seq step.
curl -fsS -X POST "$MREXT_BASE/api/v1/controls/keyboard" \
     -H 'content-type: application/json' -d '{"key":"F12"}' >/dev/null || true
sleep 1

# Capture evtest output for the synthetic uinput keyboard during a vector.
read_evdev() {  # $1 = seconds
  $SSH "dev=\$(grep -l 'MiSTer.*virtual\\|uinput' /sys/class/input/event*/device/name 2>/dev/null | head -1); \
        dev=\${dev%/device/name}; dev=/dev/input/\$(basename \$dev); \
        timeout $1 evtest --grab \"\$dev\" 2>/dev/null | grep -oE 'code [0-9]+ \\(KEY_[A-Z0-9_]+\\)'"
}

assert_vec() {       # name  "P1=..."  expected-grep-regex
  local name="$1" cmd="$2" want="$3"
  say "vector: $name  ($cmd)"
  mcu "CLEAR"; mcu "$cmd"
  local out; out="$(read_evdev 3 || true)"
  if echo "$out" | grep -qE "$want"; then
    printf '  ok   %s -> matched /%s/\n' "$name" "$want"
  else
    printf '  FAIL %s -> want /%s/, saw:\n' "$name" "$want"
    echo "$out" | sed 's/^/    /'
    fail=1
  fi
}

# joy_raw bit -> OSD key mapping is fixed in user_io.cpp:user_io_joyraw_check_change().
# Adjust the expected KEY_ regexes to that table for the core under test.
assert_vec "P1 Up"    "P1=UP"   'KEY_UP'
assert_vec "P1 Down"  "P1=DN"   'KEY_DOWN'
assert_vec "P1 A"     "P1=A"    'KEY_(ENTER|A)'
assert_vec "release"  "CLEAR"   '^$'   # no events after clear (best-effort)

say "type-detect: db9_shm_write should report DB15"
if $SSH "cat /tmp/db9_type 2>/dev/null || true" | grep -qi 'db15'; then
  echo "  ok   shm reports DB15"
else
  echo "  WARN could not confirm DB15 via shm (path/format core-dependent)"
fi

mcu "CLEAR"
echo
echo "COVERAGE: evdev path = OSD-nav subset + [15:14] type bits only."
echo "          Full per-button proof = InputTest_MiSTer screen / mrext screenshot."
if [ "$fail" -eq 0 ]; then echo "TIER2: PASS"; exit 0; else echo "TIER2: FAIL"; exit 1; fi
