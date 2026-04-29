#!/usr/bin/env python3
"""Full per-core port to wrapper-thin Saturn-aware form.

Auto-detects DB9-only baseline patterns in `<core>.sv` and upgrades to the
joydb-wrapper form. Generalizes what `porting/scripts/port_batch_*.py` does
for the 20 manually-listed cores so any standard-pattern core can be ported
without a per-core entry. Used by `apply_db9_framework.sh` after the sys/
framework lands, to make end-to-end porting one shot.

Transformations (each gated by detection — skipped if not matched):
  1. Replace JOY_FLAG/JOY_MDIN/JOY_DATA/USER_OUT/USER_MODE/USER_OSD assigns
     with the joydb wrapper instance + status-bit-derived joy_type/joy_2p.
  2. Strip the legacy joydb_1/2 mux (driven by JOY_FLAG).
  3. Strip joy_db9md / joy_db15 instances + JOYDB*_1/2 reg decls.
  4. Update CONF_STR (`OUV/OT`, `oUV/oT`, `O[127:126]/O[125]`) to Saturn-first.
  5. Widen `wire [31:0] status;` or `wire [63:0] status;` to `[127:0]`.
  6. Wrap joystick mux RHS expressions in `OSD_STATUS ? 32'b0 : (...)` guard.
  7. Replace `.joy_raw(...)` binding with the `joy_raw_payload` form +
     `.saturn_unlocked(saturn_unlocked)` binding in hps_io.
  8. Replace the default `assign USER_PP = 8'h00;` (added by
     `upgrade_pro_additive.py`) with `assign USER_PP = USER_PP_DRIVE;` from
     the wrapper.

Idempotent: bails early if `joydb joydb` instance is already present.

Usage:
    port_core_full.py <core_dir>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _eol_io import read_text, write_text  # noqa: E402


def find_emu_sv(core_dir: Path) -> Path | None:
    for sv in core_dir.glob('*.sv'):
        try:
            t = sv.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        if re.search(r'^\s*module\s+emu\s*[\(#]', t, re.MULTILINE):
            return sv
    return None


# ---- Wrapper boilerplate (drop-in replacement for JOY_FLAG block) ----

WRAPPER_BLOCK = """// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joydb wrapper
wire         CLK_JOY = CLK_50M;                 // Assign clock between 40-50Mhz
wire   [1:0] joy_type        = status[127:126]; // 0=Off, 1=Saturn, 2=DB9MD, 3=DB15
wire         joy_2p          = status[125];
wire         joy_db9md_en    = (joy_type == 2'd2);
wire         joy_db15_en     = (joy_type == 2'd3);
wire         joy_any_en      = |joy_type;
// Legacy 3-bit alias for fork-specific MT32 / SNAC fallback code. Non-canonical
// RHS variants (ext_iec_en, mt32_disable) need a hand-port — alias is raw.
wire   [2:0] JOY_FLAG        = {joy_db9md_en, joy_db15_en, joy_2p};
// [MiSTer-DB9 END]

// [MiSTer-DB9-Pro BEGIN] - Saturn key gate
wire         saturn_unlocked;                   // driven by hps_io UIO_DB9_KEY (0xFE)
// [MiSTer-DB9-Pro END]

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joydb wrapper wires + instance
wire   [7:0] USER_OUT_DRIVE;
wire   [7:0] USER_PP_DRIVE;
wire  [15:0] joydb_1, joydb_2;
wire         joydb_1ena, joydb_2ena;
wire  [15:0] joy_raw_payload;

joydb joydb (
  .clk             ( CLK_JOY         ),
  .USER_IN         ( USER_IN         ),
  .joy_type        ( joy_type        ),
  .joy_2p          ( joy_2p          ),
  .saturn_unlocked ( saturn_unlocked ),
  .USER_OUT_DRIVE  ( USER_OUT_DRIVE  ),
  .USER_PP_DRIVE   ( USER_PP_DRIVE   ),
  .USER_OSD        ( USER_OSD        ),
  .joydb_1         ( joydb_1         ),
  .joydb_2         ( joydb_2         ),
  .joydb_1ena      ( joydb_1ena      ),
  .joydb_2ena      ( joydb_2ena      ),
  .joy_raw         ( joy_raw_payload )
);

assign USER_OUT = USER_OUT_DRIVE;
// [MiSTer-DB9 END]
"""


# ---- Step 1: replace JOY_FLAG block with wrapper instance ----
#
# Structural matcher (not regex over the whole block): the legacy DB9 baseline
# always opens with `wire CLK_JOY = CLK_50M*` and closes with
# `assign USER_OSD = (joydb_1|JOY_DB1|joydb)[10] & ...[6]`. Everything in
# between (JOY_FLAG with custom RHS, `ifdef SECOND_MT32` brackets, commented
# variants, USER_MODE/USER_OUT in any order with multi-line ternaries) is
# implementation noise that the new wrapper hides. We collapse [start..end]
# into WRAPPER_BLOCK in one shot — robust to all the historical RHS variants
# (ext_iec_en gate, mt32_use gate, db9md_ena custom expression, 2-bit GBA form,
# USER_MODE/USER_OSD/USER_OUT reorderings).
#
# Optional outer `[MiSTer-DB9 BEGIN/END]` markers are absorbed into the span
# so the replacement leaves no orphan markers behind.

CLK_JOY_START_RE = re.compile(
    r'^[ \t]*wire[ \t]+CLK_JOY[ \t]*=[ \t]*CLK_50M[^\n]*\n',
    flags=re.MULTILINE,
)

USER_OSD_END_RE = re.compile(
    r'^[ \t]*assign[ \t]+USER_OSD[ \t]*=[ \t]*'
    r'(?:joydb_1|JOY_DB1|joydb)\[10\][^\n]*\n',
    flags=re.MULTILINE,
)


def replace_joy_flag_block(text: str) -> tuple[str, bool]:
    m_start = CLK_JOY_START_RE.search(text)
    if not m_start:
        return text, False
    m_end = USER_OSD_END_RE.search(text, m_start.end())
    if not m_end:
        return text, False

    start = m_start.start()
    end   = m_end.end()

    # Absorb a `// [MiSTer-DB9 BEGIN] ...` marker line immediately preceding
    # CLK_JOY so it doesn't survive as an orphan.
    pre = text[:start]
    pre_lines = pre.split('\n')
    if pre_lines and re.match(r'[ \t]*//[^\n]*\[MiSTer-DB9 BEGIN\]', pre_lines[-2] if len(pre_lines) >= 2 else ''):
        # last element is empty (trailing \n); -2 is the marker line
        start -= len(pre_lines[-2]) + 1

    # Absorb a `// [MiSTer-DB9 END] ...` marker line immediately following USER_OSD.
    rest = text[end:]
    end_marker = re.match(r'[ \t]*//[^\n]*\[MiSTer-DB9 END\][^\n]*\n', rest)
    if end_marker:
        end += end_marker.end()

    return text[:start] + WRAPPER_BLOCK + text[end:], True


# ---- Step 1b: replace legacy joydbmix wrapper instance ----
#
# Older arcade cores (Centipede, Finalizer, Gauntlet, IremM72, IronHorse, Jackal,
# Jailbreak, QBert, ScooterShooter, TaitoSystemSJ, GnW, ...) hide the JOY_FLAG /
# joy_db9md / joy_db15 wiring inside `sys/joydbmix.sv` and instantiate it from
# `<core>.sv` as `joydbmix joydbmix(...)` with `.JOY_FLAG(status[63:61])`. The
# new `sys/joydb.sv` wrapper supersedes joydbmix (adds Saturn + saturn_unlocked +
# USER_PP_DRIVE), so we swap the instance + the surrounding `wire [15:0] joydb_1,
# joydb_2; wire joydb_1ena, joydb_2ena;` decls for WRAPPER_BLOCK in one shot.

JOYDBMIX_BLOCK_RE = re.compile(
    r'(?:^[ \t]*//[^\n]*\[MiSTer-DB9 BEGIN\][^\n]*\n)?'
    r'^[ \t]*wire[ \t]+\[15:0\][ \t]+joydb_1[ \t]*,[ \t]*joydb_2;[^\n]*\n'
    r'^[ \t]*wire[ \t]+joydb_1ena[ \t]*,[ \t]*joydb_2ena;[^\n]*\n'
    # `(` may be on the same line as `joydbmix joydbmix` or on the next line.
    r'^[ \t]*joydbmix[ \t]+joydbmix[ \t]*(?:\([^\n]*\n|\n[ \t]*\([ \t]*\n)'
    r'(?:^[^\n]*\n)*?'                             # body lines (port hookups)
    r'^[ \t]*\)[ \t]*;[^\n]*\n'
    r'(?:^[ \t]*//[^\n]*\[MiSTer-DB9 END\][^\n]*\n)?',
    flags=re.MULTILINE,
)


def replace_joydbmix_block(text: str) -> tuple[str, bool]:
    m = JOYDBMIX_BLOCK_RE.search(text)
    if not m:
        return text, False
    return text[:m.start()] + WRAPPER_BLOCK + text[m.end():], True


# ---- Step 2: strip joydb_1/2 mux block ----

JOYDB_MUX_RE = re.compile(
    r'(?:^[ \t]*//[^\n]*\[MiSTer-DB9 BEGIN\][^\n]*\n)?'
    # Leading whitespace tolerated (Saturn `\t`, CDi `    `, Dorodon `\t\t`).
    r'^[ \t]*wire[ \t]+\[15:0\][ \t]+joydb_1[ \t]*=[ \t]*JOY_FLAG\[2\][ \t]*\?[ \t]*JOYDB9MD_1[ \t]*:[ \t]*JOY_FLAG\[1\][ \t]*\?[ \t]*JOYDB15_1[ \t]*:[ \t]*\'0;[^\n]*\n'
    # joydb_2 mux line is optional (1P cores: FlappyBird, Arduboy) AND may be
    # commented out (Apple-II). Match either: blank-line absent / live wire / `//`-prefixed.
    r'(?:^[ \t]*(?://[ \t]*)?wire[ \t]+\[15:0\][ \t]+joydb_2[ \t]*=[ \t]*JOY_FLAG\[2\][ \t]*\?[ \t]*JOYDB9MD_2[ \t]*:[ \t]*JOY_FLAG\[1\][ \t]*\?[ \t]*JOYDB15_2[ \t]*:[ \t]*\'0;[^\n]*\n)?'
    r'^[ \t]*wire[ \t]+joydb_1ena[ \t]*=[ \t]*\|JOY_FLAG\[2:1\][^\n]*\n'
    r'(?:^[ \t]*(?://[ \t]*)?wire[ \t]+joydb_2ena[ \t]*=[ \t]*\|JOY_FLAG\[2:1\][ \t]*&[ \t]*JOY_FLAG\[0\];[^\n]*\n)?'
    r'(?:^[ \t]*//[^\n]*\[MiSTer-DB9 END\][^\n]*\n)?',
    flags=re.MULTILINE,
)


def strip_joydb_mux(text: str) -> tuple[str, bool]:
    new_text, n = JOYDB_MUX_RE.subn('', text, count=1)
    return new_text, n > 0


# GBA uses a 2-bit JOY_FLAG (no 2P bit) and a single-player `joydb` wire (no
# `_1` suffix). Strip that variant separately.
JOYDB_MUX_GBA_RE = re.compile(
    r'^[ \t]*wire[ \t]+\[15:0\][ \t]+joydb[ \t]*=[ \t]*JOY_FLAG\[1\][ \t]*\?[ \t]*JOYDB9MD_1[ \t]*:[ \t]*JOY_FLAG\[0\][ \t]*\?[ \t]*JOYDB15_1[ \t]*:[ \t]*\'0;[^\n]*\n'
    r'^[ \t]*wire[ \t]+joydbena[ \t]*=[ \t]*\|JOY_FLAG\[1:0\][^\n]*\n',
    flags=re.MULTILINE,
)


def strip_joydb_mux_gba(text: str) -> tuple[str, bool]:
    new_text, n = JOYDB_MUX_GBA_RE.subn('', text, count=1)
    return new_text, n > 0


# GBA-style cores reference `joydbena` and `joydb[N]` (legacy 1P bare names) in
# joy_unmod. After strip_joydb_mux_gba removes the decls, the references are
# orphans — `joydbena` is undeclared and `joydb` collides with the wrapper
# module/instance name. Rename the references to the wrapper's _1 form. Bare
# `joydb` (no bracket) is left alone — that's the wrapper instance.
def rename_legacy_joydb_refs(text: str) -> tuple[str, int]:
    n = 0
    new_text, k = re.subn(r'\bjoydbena\b', 'joydb_1ena', text)
    if k:
        text = new_text
        n += k
    new_text, k = re.subn(r'\bjoydb\[', 'joydb_1[', text)
    if k:
        text = new_text
        n += k
    return text, n


# 1P cores never read `joydb_2`, so `joy_2p` is unused as a 2P-mux enable.
# Some upstream cores repurpose `status[125]` for their own toggle (e.g. GBA's
# Buttons Mapping option); aliasing `joy_2p = status[125]` then accidentally
# couples joy_2p to that toggle. Force `joy_2p = 1'b0` for 1P cores.
def fix_joy_2p_for_1p(text: str) -> tuple[str, bool]:
    pat = re.compile(
        r"^([ \t]*)wire[ \t]+joy_2p[ \t]*=[ \t]*status\[125\];[^\n]*$",
        flags=re.MULTILINE,
    )
    if not pat.search(text):
        return text, False
    return pat.sub(
        r"\1wire         joy_2p          = 1'b0;          // 1P-only: joy_2p unused",
        text, count=1,
    ), True


# ---- Step 3: strip joy_db9md / joy_db15 instances + reg decls ----

DB9MD_INST_RE = re.compile(
    r'(?:^[ \t]*//----[^\n]*\n^[ \t]*//----[^\n]*\n)?'
    r'^reg \[15:0\] JOYDB9MD_1,JOYDB9MD_2;[^\n]*\n'
    r'^joy_db9md\s+joy_db9md\s*\(.*?\n\)\s*;[^\n]*\n',
    flags=re.MULTILINE | re.DOTALL,
)
DB15_INST_RE = re.compile(
    r'(?:^[ \t]*//----[^\n]*\n^[ \t]*//----[^\n]*\n)?'
    r'^reg \[15:0\] JOYDB15_1,JOYDB15_2;[^\n]*\n'
    r'^joy_db15\s+joy_db15\s*\(.*?\n\)\s*;[^\n]*\n',
    flags=re.MULTILINE | re.DOTALL,
)


# Standalone `assign USER_OUT = JOY_FLAG[2] ? {...,JOY_SPLIT,...,JOY_MDSEL} :
# JOY_FLAG[1] ? {...,JOY_CLK,JOY_LOAD} : '1;` that some cores (Atari-system1,
# IremM92, DonkeyKong3, DonkeyKongJunior, Dorodon, Apple-II, SuperBreakout, CDi)
# emit *after* the USER_OSD line, often with a leading `// Active controller
# type:...` comment and a multi-line ternary. The new wrapper provides this
# mux as `USER_OUT_DRIVE`; the wrapper also emits `assign USER_OUT =
# USER_OUT_DRIVE;`, so the standalone block is redundant and would multi-drive.

STANDALONE_USER_OUT_RE = re.compile(
    r'(?:^[ \t]*//[^\n]*JOY_FLAG\[[12]\][^\n]*\n)?'                   # optional preceding comment
    r'^[ \t]*assign[ \t]+USER_OUT[ \t]*=[ \t]*JOY_FLAG\[2\][ \t]*\?[ \t]*'
    r'\{[^{}]*JOY_SPLIT[^{}]*JOY_MDSEL[^{}]*\}[^\n]*\n'              # first line
    r'(?:^[ \t]*:[^\n]*\n){0,3}',                                     # 0-3 continuation lines (multi-line ternary)
    flags=re.MULTILINE,
)


def strip_standalone_user_out(text: str) -> tuple[str, bool]:
    new_text, n = STANDALONE_USER_OUT_RE.subn('', text, count=1)
    return new_text, n > 0


def strip_legacy_instances(text: str) -> tuple[str, list[str]]:
    notes = []
    new_text, n = DB9MD_INST_RE.subn('', text, count=1)
    if n:
        notes.append('stripped joy_db9md instance')
        text = new_text
    new_text, n = DB15_INST_RE.subn('', text, count=1)
    if n:
        notes.append('stripped joy_db15 instance')
        text = new_text
    return text, notes


# ---- Step 4: update CONF_STR to Saturn-first ----

def update_conf_str(text: str, is_1p: bool = False) -> tuple[str, bool]:
    """Replace any of OUV/OT, oUV/oT, or O[127:126]/O[125] DB9 entries with
    the Saturn-first form (`Off,Saturn,DB9MD,DB15`).

    Handles the optional MiSTer CONF_STR page-prefix (e.g. `P2`, `P1F`, `P3S`):
    cores with multi-page menus carry these as a `P<n>...` segment immediately
    before the option letter range. The new Saturn-first emission preserves the
    same prefix on the rewritten line so the entry stays on the original menu page.

    When `is_1p` is True (cores with no `joydb_2 = ...` in the original mux —
    FlappyBird, Arduboy, GBA, ...), skips emitting the `UserIO Players` line:
    the toggle is meaningless because joydb_2 is never consumed."""
    # Allow an optional page prefix like P0..P9, P0F, P0S, P0M, etc.
    # (MiSTer convention: P<n> + optional flags). Captured to preserve.
    pfx = r'(?P<pfx>P[0-9][A-Za-z]?)?'

    # Try (a) modern O[127:126] form (already wrapped in markers maybe).
    a_re = re.compile(
        r'"' + pfx.replace('?P<pfx>', '?P<pfxA>')
        + r'O\[127:126\],UserIO Joystick,Off,(?:DB9MD,DB15|DB15,DB9MD|DB15,DB9)[ \t]*;"'
    )
    m = a_re.search(text)
    if m:
        prefix = m.group('pfxA') or ''
        text = (
            text[:m.start()]
            + f'"{prefix}O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;"'
            + text[m.end():]
        )
        if is_1p:
            text = strip_players_line(text)
        return text, True

    # (b) Legacy letter-encoded form (any OXY/oXY for joystick, any OX/oX for
    # players). The legacy `o` prefix maps to status[63:32], so existing oUV/oO
    # cores actually wrote bits status[63:62]/status[56] — but joydb expects
    # joy_type/joy_2p at status[127:126]/status[125]. We forcibly migrate to
    # the canonical `O[127:126]` / `O[125]` bracket form regardless of the
    # original letters, fixing the bit-mismatch in one shot.
    # Each letter character: digit (0-9) = bits 0-9, A-V = bits 10-31.
    LETTER_PAT = r'[0-9A-Va-v]'
    # Two upstream baselines exist: inline-style cores emit `Off,DB9MD,DB15`;
    # joydbmix-family arcade cores emit `Off,DB15,DB9MD` (or short `Off,DB15,DB9`).
    # Both migrate to the canonical `Off,Saturn,DB9MD,DB15` Saturn-first form.
    joy_re = re.compile(
        r'"(?P<pfxJ>P[0-9][A-Za-z]?)?[Oo]' + LETTER_PAT + r'{2}'
        r',UserIO Joystick,Off,(?:DB9MD,DB15|DB15,DB9MD|DB15,DB9)[ \t]*;",[ \t]*\n'
    )
    ply_re = re.compile(
        r'(?P<indent>[ \t]*)"(?P<pfxP>P[0-9][A-Za-z]?)?[Oo]' + LETTER_PAT
        + r',UserIO Players,[ \t]*1 Player,2 Players[ \t]*;",'
    )
    m = joy_re.search(text)
    if not m:
        return text, False
    m2 = ply_re.search(text, m.end())
    if not m2:
        # 1P-only legacy core may not even emit a Players line — replace just
        # the joystick line in place.
        if is_1p:
            prefix_joy = m.group('pfxJ') or ''
            indent_match = re.match(r'[ \t]*', text[text.rfind('\n', 0, m.start())+1 : m.start()])
            indent = indent_match.group(0) if indent_match else ''
            new_block = (
                f'// [MiSTer-DB9-Pro BEGIN] - Saturn-first joy_type (canonical bit notation)\n'
                f'{indent}"{prefix_joy}O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;"\n'
                f'{indent}// [MiSTer-DB9-Pro END]'
            )
            return text[:m.start()] + new_block + text[m.end():], True
        return text, False
    prefix_joy = m.group('pfxJ') or ''
    prefix_ply = m2.group('pfxP') or ''
    indent     = m2.group('indent')
    if is_1p:
        # Drop the Players line: meaningless when joydb_2 is never consumed.
        new_block = (
            f'{indent}// [MiSTer-DB9-Pro BEGIN] - Saturn-first joy_type (canonical bit notation)\n'
            f'{indent}"{prefix_joy}O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",\n'
            f'{indent}// [MiSTer-DB9-Pro END]\n'
        )
    else:
        new_block = (
            f'{indent}// [MiSTer-DB9-Pro BEGIN] - Saturn-first joy_type (canonical bit notation)\n'
            f'{indent}"{prefix_joy}O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",\n'
            f'{indent}"{prefix_ply}O[125],UserIO Players, 1 Player,2 Players;",\n'
            f'{indent}// [MiSTer-DB9-Pro END]\n'
        )
    return text[:m.start()] + new_block + text[m2.end() + 1:], True


# Strip the `O[125],UserIO Players,...` line for 1P cores already at the
# Saturn-first form. Idempotent: no-op if already stripped.
def strip_players_line(text: str) -> str:
    pat = re.compile(
        r'^[ \t]*"(?:P[0-9][A-Za-z]?)?O\[125\],UserIO Players,[^"]+",?[^\n]*\n',
        flags=re.MULTILINE,
    )
    return pat.sub('', text, count=1)


# ---- Step 5: widen status to [127:0] ----

def widen_status(text: str) -> tuple[str, bool]:
    m = re.search(r'^([ \t]*)wire[ \t]+\[(?:31|63):0\][ \t]+status;[^\n]*\n', text, re.MULTILINE)
    if not m:
        return text, False
    indent = m.group(1)
    new_decl = (
        f'{indent}// [MiSTer-DB9 BEGIN] - widened to 128 bits for joy_type at [127:126] and joy_2p at [125]\n'
        f'{indent}wire [127:0] status;\n'
        f'{indent}// [MiSTer-DB9 END]\n'
    )
    return text[:m.start()] + new_decl + text[m.end():], True


# ---- Step 6: wrap joystick mux with OSD_STATUS guard ----

# Match `wire [31:0] varN = joydb_Nena ? <body> : <fallback>;`
# Body and fallback may span multiple lines. Use DOTALL for the body.
JOYDB_MUX_LINE_RE = re.compile(
    r'^([ \t]*)wire[ \t]+\[31:0\][ \t]+(\w+)[ \t]*=[ \t]*joydb_([12])ena[ \t]*\?[ \t]*'
    r'(.*?)'  # body — non-greedy, may span lines
    r'[ \t]*:[ \t]*'
    r'([^;\n]+(?:\n[^;\n]+)*?);[^\n]*$',  # fallback expression up to final `;`
    flags=re.MULTILINE | re.DOTALL,
)


def wrap_joystick_mux(text: str) -> tuple[str, int]:
    """Add `OSD_STATUS ? 32'b0 : (...)` guard around the body of every
    `wire [31:0] varN = joydb_Nena ? body : fallback;` line."""
    n = 0
    out = []
    pos = 0
    for m in JOYDB_MUX_LINE_RE.finditer(text):
        indent, var, _ena_idx, body, fallback = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
        # Skip if already guarded
        if 'OSD_STATUS' in body:
            continue
        # Build replacement
        body_clean = body.strip()
        # Only wrap if body starts with `{` (typical mux mapping form)
        if not body_clean.startswith('{'):
            continue
        new_line = (
            f'{indent}// [MiSTer-DB9-Pro BEGIN] - DB controllers muted while OSD is open\n'
            f'{indent}wire [31:0] {var} = joydb_{_ena_idx}ena ? (OSD_STATUS ? 32\'b0 : {body_clean}) : {fallback.strip()};\n'
            f'{indent}// [MiSTer-DB9-Pro END]'
        )
        out.append(text[pos:m.start()])
        out.append(new_line)
        pos = m.end()
        n += 1
    out.append(text[pos:])
    return ''.join(out), n


# ---- Step 7: replace .joy_raw(...) line + add saturn_unlocked binding ----

# Match `.joy_raw(...)` with up to one level of nested parens
# (e.g. `.joy_raw(OSD_STATUS? (joydb_1[5:0]|joydb_2[5:0]) : 6'b0)`).
JOY_RAW_BIND_RE = re.compile(
    r'^([ \t]*)\.joy_raw\((?:[^()]|\([^()]*\))*\)([ \t]*,?)[ \t]*(?://[^\n]*)?$',
    flags=re.MULTILINE,
)


def replace_joy_raw(text: str) -> tuple[str, bool]:
    if 'joy_raw_payload' not in text:
        # joy_raw_payload is declared by replace_joy_flag_block — but the
        # binding to hps_io is what we update here.
        pass
    # Skip if hps_io binding already uses joy_raw_payload
    if re.search(r'\.joy_raw\(\s*OSD_STATUS\s*\?\s*joy_raw_payload', text):
        return text, False
    m = JOY_RAW_BIND_RE.search(text)
    if not m:
        return text, False
    indent, comma = m.group(1), m.group(2)
    new_block = (
        f'{indent}// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joy_raw\n'
        f'{indent}.joy_raw(OSD_STATUS ? joy_raw_payload : 16\'b0),\n'
        f'{indent}// [MiSTer-DB9 END]\n'
        f'{indent}// [MiSTer-DB9-Pro BEGIN] - Saturn key gate\n'
        f'{indent}.saturn_unlocked(saturn_unlocked){comma}\n'
        f'{indent}// [MiSTer-DB9-Pro END]'
    )
    return text[:m.start()] + new_block + text[m.end():], True


# ---- Step 8: replace default USER_PP assign with wrapper-driven ----

def update_user_pp_assign(text: str) -> tuple[str, bool]:
    pat = re.compile(r"assign[ \t]+USER_PP[ \t]*=[ \t]*8'h00;")
    if not pat.search(text):
        return text, False
    return pat.sub('assign USER_PP = USER_PP_DRIVE;', text, count=1), True


# ---- Step 9: SerJoystick-family mid-file USER_OUT mux ----
#
# Genesis / MegaCD / PSX / S32X / SMS / Saturn drive USER_OUT inside an
# always-block (SerJoystick / piano relay). Their `else begin` branch carries
# `USER_OUT <= JOY_FLAG[2] ? {...,JOY_SPLIT,...,JOY_MDSEL} : JOY_FLAG[1] ?
# {...,JOY_CLK,JOY_LOAD} : '1;` — a deep-mid-file JOY_FLAG reference that
# WRAPPER_BLOCK doesn't reach. The new wrapper exposes the same per-mode mux
# output as `USER_OUT_DRIVE`, so the rewrite collapses to one wire.
#
# Two consequences when this pattern is present:
#   1. The SerJoystick `else` branch is rewritten to `USER_OUT <= USER_OUT_DRIVE;`.
#   2. The WRAPPER_BLOCK's `assign USER_OUT = USER_OUT_DRIVE;` would create a
#      multi-driver conflict against the always-block driver, so the orchestrator
#      strips it after the fact.

SERJOY_USER_OUT_RE = re.compile(
    r"^([ \t]*)USER_OUT[ \t]*(?P<op><=|=)[ \t]*JOY_FLAG\[2\][ \t]*\?[ \t]*"
    r"\{[^{}]*JOY_SPLIT[^{}]*JOY_MDSEL[^{}]*\}[ \t]*:[ \t]*"
    r"JOY_FLAG\[1\][ \t]*\?[ \t]*"
    r"\{[^{}]*JOY_CLK[^{}]*JOY_LOAD[^{}]*\}[ \t]*:[ \t]*"
    r"(?:'1|7'b1111111|8'hFF)[ \t]*;[^\n]*\n",
    flags=re.MULTILINE,
)


def rewrite_serjoy_user_out(text: str) -> tuple[str, bool]:
    m = SERJOY_USER_OUT_RE.search(text)
    if not m:
        return text, False
    indent = m.group(1)
    op = m.group('op')  # `<=` (non-blocking) or `=` (blocking) — preserve.
    new_block = (
        f'{indent}// [MiSTer-DB9 BEGIN] - SerJoystick relay falls through to joydb USER_OUT_DRIVE\n'
        f'{indent}USER_OUT {op} USER_OUT_DRIVE;\n'
        f'{indent}// [MiSTer-DB9 END]\n'
    )
    return text[:m.start()] + new_block + text[m.end():], True


def strip_wrapper_user_out_assign(text: str) -> tuple[str, bool]:
    """SerJoystick cores drive USER_OUT from an always-block; the wrapper's
    `assign USER_OUT = USER_OUT_DRIVE;` would multi-drive. Strip it (and its
    surrounding markers) when the always-block driver is present."""
    pat = re.compile(
        r"^[ \t]*assign[ \t]+USER_OUT[ \t]*=[ \t]*USER_OUT_DRIVE;[^\n]*\n",
        flags=re.MULTILINE,
    )
    if not pat.search(text):
        return text, False
    return pat.sub('', text, count=1), True


# ---- Orchestrator ----

def port_core(core_dir: Path) -> list[str]:
    notes: list[str] = []
    sv = find_emu_sv(core_dir)
    if not sv:
        return [f'{core_dir}: no <core>.sv with `module emu` found']

    text, nl = read_text(sv)
    is_wrapper_thin = 'joydb joydb' in text
    has_joy_flag    = 'JOY_FLAG' in text
    has_joydbmix    = 'joydbmix joydbmix' in text

    if not is_wrapper_thin and not has_joy_flag and not has_joydbmix:
        return [f'{sv.name}: no JOY_FLAG, no joydbmix, and no joydb wrapper — not a standard DB9-baseline core; manual port required']

    orig = text

    # Steps 1-3: legacy → wrapper conversion. Skip if already at wrapper-thin form;
    # the idempotent fix-ups below still run to repair half-converted cores
    # (e.g., wrapper-thin but legacy `oUV` CONF_STR).
    if is_wrapper_thin:
        notes.append(f'{sv.name}: already at wrapper-thin form — running idempotent fix-ups only')
    elif has_joydbmix:
        text, ok = replace_joydbmix_block(text)
        if not ok:
            notes.append(f'{sv.name}: joydbmix instance did not match standard pattern — aborting')
            return notes
        notes.append(f'{sv.name}: replaced joydbmix instance with joydb wrapper')
    else:
        text, instance_notes = strip_legacy_instances(text)
        notes.extend(f'{sv.name}: ' + n for n in instance_notes)

        text, ok = strip_joydb_mux(text)
        if ok: notes.append(f'{sv.name}: stripped legacy joydb_1/2 mux')

        text, ok = strip_joydb_mux_gba(text)
        if ok: notes.append(f'{sv.name}: stripped legacy GBA-style 2-bit joydb mux')

        text, ok = replace_joy_flag_block(text)
        if not ok:
            notes.append(f'{sv.name}: JOY_FLAG block did not match standard pattern — aborting')
            return notes
        notes.append(f'{sv.name}: replaced JOY_FLAG block with joydb wrapper instance')

        # Some cores (Atari-system1, IremM92, DonkeyKong3, ...) emit a standalone
        # `assign USER_OUT = JOY_FLAG[2] ? {...} : '1;` after the JOY_FLAG block.
        # The wrapper's `USER_OUT_DRIVE` provides the same mux; strip the legacy.
        text, ok = strip_standalone_user_out(text)
        if ok: notes.append(f'{sv.name}: stripped standalone post-block USER_OUT mux')

    # Idempotent fix-ups: each is a no-op if already in target form, so safe to
    # re-run on any core, including ones whose port_core_full was interrupted
    # half-way or whose hand-edited state needs reconciliation.

    # Strip stale .USER_MODE(USER_MODE) port binding from joydb instance.
    # Older porter versions emitted it; current joydb.sv removed the port.
    new_text, n_um = re.subn(
        r'^[ \t]*\.USER_MODE[ \t]*\([ \t]*USER_MODE[ \t]*\),?[ \t]*\n',
        '', text, flags=re.MULTILINE,
    )
    if n_um:
        text = new_text
        notes.append(f'{sv.name}: stripped {n_um} stale .USER_MODE() binding from joydb instance')

    # 1P-only cores never reference `joydb_2[N]` in the joystick mux; for
    # those, the `UserIO Players` toggle is meaningless and gets dropped.
    # Check `orig` (pre-port) since the live wrapper hookup adds a non-indexed
    # `joydb_2` port binding that we want to ignore.
    is_1p = 'joydb_2[' not in orig

    # GBA-style legacy ref rename — runs after strip_joydb_mux_gba (no-op on
    # cores that didn't match) and before WRAPPER_BLOCK so we don't rewrite
    # the wrapper's own `joydb_1ena` decls.
    text, n_ref = rename_legacy_joydb_refs(text)
    if n_ref:
        notes.append(f'{sv.name}: renamed {n_ref} legacy joydb/joydbena ref(s) to joydb_1/joydb_1ena')

    if is_1p:
        text, ok = fix_joy_2p_for_1p(text)
        if ok:
            notes.append(f"{sv.name}: tied joy_2p to 1'b0 (1P-only core; status[125] may be reused)")

    text, ok = update_conf_str(text, is_1p=is_1p)
    if ok:
        suffix = ' (1P: dropped Players)' if is_1p else ''
        notes.append(f'{sv.name}: updated CONF_STR to Saturn-first O[127:126]{suffix}')

    # Idempotent strip: handles 1P cores already at Saturn form (e.g. FlappyBird
    # ported before this fix) where the Players line was emitted by mistake.
    if is_1p:
        new_text = strip_players_line(text)
        if new_text != text:
            text = new_text
            notes.append(f'{sv.name}: stripped vestigial UserIO Players line (1P-only core)')

    text, ok = widen_status(text)
    if ok: notes.append(f'{sv.name}: widened status to [127:0]')

    text, n = wrap_joystick_mux(text)
    if n: notes.append(f'{sv.name}: wrapped {n} joystick mux line(s) with OSD_STATUS guard')

    text, ok = replace_joy_raw(text)
    if ok: notes.append(f'{sv.name}: replaced joy_raw + added saturn_unlocked binding')

    text, ok = update_user_pp_assign(text)
    if ok: notes.append(f'{sv.name}: replaced default USER_PP with wrapper-driven assign')

    # SerJoystick family (Genesis/MegaCD/PSX/S32X/SMS/Saturn): rewrite the
    # mid-file always-block USER_OUT mux + drop the wrapper's `assign USER_OUT`
    # to avoid a multi-driver conflict.
    text, ok = rewrite_serjoy_user_out(text)
    if ok:
        notes.append(f'{sv.name}: rewrote SerJoystick USER_OUT mux to USER_OUT_DRIVE')
        text, _ = strip_wrapper_user_out_assign(text)
        notes.append(f'{sv.name}: stripped wrapper `assign USER_OUT = USER_OUT_DRIVE;` (always-block drives USER_OUT)')

    if text == orig:
        notes.append(f'{sv.name}: no changes')
    else:
        write_text(sv, text, nl)

    # Sanity checks. WRAPPER_BLOCK now declares a `wire [2:0] JOY_FLAG = ...`
    # legacy alias; strip that one line before the leftover-JOY_FLAG check, so
    # the WARNING fires only for actual residual references (mid-file SNAC
    # branches, MT32 hazard gate, etc.) that the porter could not rewrite.
    text_for_check = re.sub(
        r'^[ \t]*wire[ \t]+\[2:0\][ \t]+JOY_FLAG[ \t]*=[ \t]*\{joy_db9md_en, joy_db15_en, joy_2p\};[^\n]*\n',
        '', text, count=1, flags=re.MULTILINE,
    )
    if 'JOY_FLAG' in text_for_check:
        residual_lines = [(i+1, ln) for i, ln in enumerate(text_for_check.splitlines()) if 'JOY_FLAG' in ln]
        notes.append(f'{sv.name}: WARNING — JOY_FLAG still referenced at {len(residual_lines)} site(s) after port (mid-file fork-specific code; may need hand-port if it touches JOY_SPLIT/JOY_MDSEL/JOY_CLK/JOY_LOAD)')
        for ln, line in residual_lines[:3]:
            notes.append(f'{sv.name}:   line {ln}: {line.strip()[:100]}')
    if 'joydb joydb' not in text:
        notes.append(f'{sv.name}: WARNING — joydb wrapper instance missing after port')

    return notes


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    d = Path(argv[0]).resolve()
    if not d.is_dir():
        print(f'{d}: not a directory', file=sys.stderr)
        return 1
    for note in port_core(d):
        print(f'  {note}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
