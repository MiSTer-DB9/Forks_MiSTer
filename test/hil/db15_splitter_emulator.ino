// Tier-2 HIL: DB15-splitter emulator for porting regression on real silicon.
//
// Emulates the serial side of an Antonio Villena DB15 splitter so a ported
// core's joydb15.v decoder can be exercised without a physical controller.
// Reactive slave: the DE10-Nano FPGA generates JOY_CLK (~3 MHz) and JOY_LOAD;
// this MCU shifts a host-programmed 24-button frame onto JOY_DATA in the slot
// order joydb15.v:34-58 expects.
//
//   FPGA USER_IO[1] = JOY_CLK   -> MCU input  (interrupt)
//   FPGA USER_IO[0] = JOY_LOAD  -> MCU input
//   FPGA USER_IO[5] = JOY_DATA  -> MCU output (active-LOW: pressed => 0)
//
// ===========================================================================
//  ⚠  ELECTRICAL: DE10-Nano USER_IO is 3.3 V. Use a 3.3 V MCU (RP2040 /
//     Teensy 4 / ESP32) or a level shifter. A 5 V board wired directly to
//     USER_IO can damage the FPGA bank. Verify on YOUR hardware first.
//
//  ⚠  TIMING: JOY_CLK is ~333 ns/bit. Classic 16 MHz AVR (Uno/Nano) cannot
//     service an edge that fast (ISR latency ~2-3 us). Use RP2040 (this
//     sketch's target), Teensy 4, or an FPGA/CPLD. If you only have an AVR,
//     use the alternative "DB9 button-contact into a REAL splitter" rig in
//     hil/README.md — that path has no tight timing.
// ===========================================================================
//
// Frame slot table (index = JOY_CLK rising edges since JOY_LOAD low pulse;
// joydb15.v samples its internal joy_count at the matching phase). Bit value
// is the active-LOW line: pressed button -> 0.
//
//   slot  signal        slot  signal        slot  signal
//   2  P1 D    7  P1 L   12 P2 Dn  17 P1 St  22 P2 D
//   3  P1 C    8  P1 Dn  13 P2 Up  18 P2 F   23 P2 C
//   4  P1 B    9  P1 Up  14 P1 F   19 P2 E   24 P2 B
//   5  P1 A   10  P2 R   15 P1 E   20 P2 Sel 25 P2 A
//   6  P1 R   11  P2 L   16 P1 Sel 21 P2 St
//
// Host protocol over USB serial (115200, line-based):
//   "P1=A,UP\n"  set P1 buttons (names: U D L R A B C D2 E F ST SE; D2 = "D")
//   "P2=B\n"     set P2 buttons
//   "CLEAR\n"    release everything
//   "DUMP\n"     echo current 26-bit frame as hex (debug)
// Button name -> joystick[11:0] bit (same layout as joydb15 output):
//   R0 L1 Dn2 Up3 A4 B5 C6 D7 E8 F9 St10 Se11

#include <Arduino.h>

#define PIN_CLK   2   // <- wire to FPGA USER_IO[1]
#define PIN_LOAD  3   // <- wire to FPGA USER_IO[0]
#define PIN_DATA  4   // -> wire to FPGA USER_IO[5]

volatile uint16_t p1 = 0, p2 = 0;     // pressed bitmaps, joystick[11:0] layout
volatile uint8_t  frame[26];          // active-LOW line per slot (1 = idle)
volatile uint8_t  idx = 0;
volatile bool     prevLoad = true;

static inline uint8_t lineFor(uint8_t slot) {
  // returns 0 when the mapped button is pressed (active-low), else 1
  switch (slot) {
    case 2:  return !((p1 >> 7)  & 1);  case 3:  return !((p1 >> 6)  & 1);
    case 4:  return !((p1 >> 5)  & 1);  case 5:  return !((p1 >> 4)  & 1);
    case 6:  return !((p1 >> 0)  & 1);  case 7:  return !((p1 >> 1)  & 1);
    case 8:  return !((p1 >> 2)  & 1);  case 9:  return !((p1 >> 3)  & 1);
    case 10: return !((p2 >> 0)  & 1);  case 11: return !((p2 >> 1)  & 1);
    case 12: return !((p2 >> 2)  & 1);  case 13: return !((p2 >> 3)  & 1);
    case 14: return !((p1 >> 9)  & 1);  case 15: return !((p1 >> 8)  & 1);
    case 16: return !((p1 >> 11) & 1);  case 17: return !((p1 >> 10) & 1);
    case 18: return !((p2 >> 9)  & 1);  case 19: return !((p2 >> 8)  & 1);
    case 20: return !((p2 >> 11) & 1);  case 21: return !((p2 >> 10) & 1);
    case 22: return !((p2 >> 7)  & 1);  case 23: return !((p2 >> 6)  & 1);
    case 24: return !((p2 >> 5)  & 1);  case 25: return !((p2 >> 4)  & 1);
    default: return 1;                  // slots 0,1 idle
  }
}

static void rebuildFrame() {
  for (uint8_t s = 0; s < 26; s++) frame[s] = lineFor(s);
}

// JOY_CLK rising-edge ISR: present next slot bit. JOY_LOAD low resets index
// (frame boundary). Kept minimal — no Serial/float/alloc in the ISR.
void IRAM_ATTR onClk() {
  if (digitalRead(PIN_LOAD) == LOW) { idx = 0; }
  digitalWrite(PIN_DATA, frame[idx] ? HIGH : LOW);
  if (idx < 25) idx++;
}

static uint8_t bitOfName(const char *n) {
  if (!strcmp(n,"R"))  return 0;  if (!strcmp(n,"L"))  return 1;
  if (!strcmp(n,"D"))  return 2;  if (!strcmp(n,"DN")) return 2; // Down
  if (!strcmp(n,"U"))  return 3;  if (!strcmp(n,"UP")) return 3;
  if (!strcmp(n,"A"))  return 4;  if (!strcmp(n,"B"))  return 5;
  if (!strcmp(n,"C"))  return 6;  if (!strcmp(n,"D2")) return 7; // button D
  if (!strcmp(n,"E"))  return 8;  if (!strcmp(n,"F"))  return 9;
  if (!strcmp(n,"ST")) return 10; if (!strcmp(n,"SE")) return 11;
  return 0xFF;
}

static uint16_t parseList(char *s) {
  uint16_t m = 0;
  for (char *t = strtok(s, ","); t; t = strtok(NULL, ",")) {
    for (char *p = t; *p; ++p) *p = toupper(*p);
    uint8_t b = bitOfName(t);
    if (b != 0xFF) m |= (1u << b);
  }
  return m;
}

void setup() {
  pinMode(PIN_CLK,  INPUT);
  pinMode(PIN_LOAD, INPUT);
  pinMode(PIN_DATA, OUTPUT);
  digitalWrite(PIN_DATA, HIGH);          // idle line high
  rebuildFrame();
  attachInterrupt(digitalPinToInterrupt(PIN_CLK), onClk, RISING);
  Serial.begin(115200);
  Serial.println("DB15-EMU READY");
}

void loop() {
  static char buf[64]; static uint8_t n = 0;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      buf[n] = 0; n = 0;
      if (!strncmp(buf, "P1=", 3))      { p1 = parseList(buf + 3); rebuildFrame(); Serial.println("OK"); }
      else if (!strncmp(buf, "P2=", 3)) { p2 = parseList(buf + 3); rebuildFrame(); Serial.println("OK"); }
      else if (!strcmp(buf, "CLEAR"))   { p1 = p2 = 0; rebuildFrame(); Serial.println("OK"); }
      else if (!strcmp(buf, "DUMP"))    { Serial.print("FRAME "); for (uint8_t s=0;s<26;s++) Serial.print(frame[s]); Serial.println(); }
      else if (n == 0 && buf[0])        { Serial.println("ERR"); }
    } else if (n < sizeof(buf) - 1) {
      buf[n++] = c;
    }
  }
}
