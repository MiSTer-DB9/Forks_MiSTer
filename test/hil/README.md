# Tier 2 — DB15 hardware-in-the-loop

Proves a ported core decodes a real DB15 stream on actual silicon. On-demand,
not CI.

## ⚠ Electrical safety — read first

DE10-Nano `USER_IO` is **3.3 V**. Use a **3.3 V MCU** (RP2040 / Teensy 4 /
ESP32) or a level shifter. A 5 V Arduino wired straight to `USER_IO` can
damage the FPGA I/O bank. Verify pin voltages on **your** board before
connecting anything.

## Two rig options

### A. Serial emulator (no extra hardware) — `db15_splitter_emulator.ino`

MCU emulates the splitter's serial side directly on `USER_IO`.

| FPGA `USER_IO` | DB15 signal | MCU pin (sketch) | Dir |
|---|---|---|---|
| `[1]` | JOY_CLK  | `PIN_CLK` (2)  | FPGA→MCU |
| `[0]` | JOY_LOAD | `PIN_LOAD` (3) | FPGA→MCU |
| `[5]` | JOY_DATA | `PIN_DATA` (4) | MCU→FPGA |
| GND | GND | GND | — |

**Timing:** JOY_CLK ≈ 3 MHz (~333 ns/bit). A 16 MHz AVR (Uno/Nano) cannot
service the edge ISR that fast — use RP2040/Teensy 4. The sketch is
interrupt-driven; on a marginal MCU sweep a 1-edge phase offset if the frame
mis-aligns (the decoder samples its internal `joy_count`; see slot table in
the `.ino`).

### B. Button-contact into a real splitter (timing-safe)

If you own an Antonio Villena DB15 splitter, have the MCU (or simple
switches) pull the **DB9-level button contacts** low into the splitter; the
splitter does the fast serialization. No tight timing on the MCU side. Wire
the splitter's DB15 to `USER_IO` as the core expects. Recommended when only a
slow MCU is available.

## Flash + run

```
arduino-cli compile -b rp2040:rp2040:rpipico db15_splitter_emulator.ino
arduino-cli upload  -b rp2040:rp2040:rpipico -p /dev/ttyACM0 db15_splitter_emulator.ino

MISTER_HOST=mister.local MCU_PORT=/dev/ttyACM0 ./run_hil.sh
```

Serial commands: `P1=A,UP` · `P2=B` · `CLEAR` · `DUMP`.

## Readout & coverage limit

`run_hil.sh` launches a core via the **mrext remote API**
(<https://github.com/wizzomafizzo/mrext/blob/main/docs/remote.md>), selects
UserIO Joystick = DB15, asserts button vectors over serial, then reads the
synthetic `/dev/uinput` keyboard over SSH (`evtest --grab`) and checks the
mapped keycodes + the `[15:14]` type-detect = DB15.

`joy_raw` is the **OSD-navigation subset** (14 bits, populated only when the
OSD is open: hps_io binds `.joy_raw(OSD_STATUS ? joy_raw_payload : 16'b0)`).
This proves "the DB15 port is wired and decodes". Full per-button in-game
confirmation is the `InputTest_MiSTer` on-screen display (manual, or an mrext
screenshot) — not part of the scripted gate.
