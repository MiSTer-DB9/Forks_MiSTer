#!/usr/bin/env python3
"""Additive upgrader for MiSTer-DB9 forks: lands DB9/Pro work on both pristine
upstream `sys/` and legacy-patched `sys/` (post-USER_MODE-removal).

Called unconditionally by `apply_db9_framework.sh` (the static `sys.patch` it
used to try first was deprecated 2026-05 — context drift on every upstream
sync made it unreliable). All transforms here are regex-anchored on stable
upstream landmarks so they survive whitespace changes / new ports / new
context lines that would break `git apply`.

Approach: leave whatever DB9 baseline already exists in place and **add**
only the missing pieces on top. This avoids resetting `sys/` from upstream
(which can pull in newer sys_top.v versions referencing emu-module ports the
fork's `<core>.sv` doesn't yet declare — HDMI_BLACKOUT, HDMI_BOB_DEINT, ...).

Two shapes are handled by every per-file pass:

  * **Pristine upstream**: file is straight from MiSTer-devel, no DB9 markers,
    no saturn_unlocked, no user_pp, USER_IO is 7 bits wide. Inject the full
    DB9 + Pro v1.5 baseline (the contents of the deprecated `sys.patch`).

  * **Legacy-patched**: file already has DB9 baseline (joy_raw, user_mode or
    user_pp, marker comments). Run the post-USER_MODE migration: add user_pp
    wire if missing, prefix USER_IO drives with `user_pp[N] ?`, strip
    user_mode ternaries / port / wire / .USER_MODE hookup, install / upgrade
    key gate v1.5 in hps_io.sv.

Passes (in order):
  1. `upgrade_hps_io` — saturn_unlocked port, joy_raw port, 'h0f handler,
     db9_key_gate instantiation, v1→v1.5 migration if v1 form is present.
  2. `upgrade_sys_top` — USER_IO[7] port + 8-bit USER_IO drive section,
     SD_SPI_CS port comment-out, deb_osd → user_osd OR-gate, user_pp wire,
     user_out/user_in widening to 8 bits, .USER_OSD/.USER_PP/USER_IO[7]/
     user_in[7] emu hookups, user_mode strip.
  3. `wrap_*_markers` — bracket the inserted/legacy DB9 add-sites with
     `[MiSTer-DB9 BEGIN/END]` and (Pro) markers per Critical Rule #1.
  4. `upgrade_sys_tcl` — `set_location_assignment PIN_AE15 -to USER_IO[7]` +
     comment-out the conflicting SD_SPI_CS line.
  5. `upgrade_core_emu` — `<core>.sv` USER_PP port + default driver, legacy
     USER_MODE strip. (port_core_full.py later swaps the default for
     `USER_PP_DRIVE` if it lifts the core to wrapper-thin form.)

Idempotent: every step is guarded by a presence check on its target signal
or an "is this already wrapped" lookback, so re-running is a no-op.

Usage:
    upgrade_pro_additive.py <core_dir>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _eol_io import read_text, write_text  # noqa: E402


# ---- sys/hps_io.sv: install / upgrade key gate v1.5 ----

# v1 port form (legacy):
#   output reg        saturn_unlocked = 0,
#   (with optional [MiSTer-DB9-Pro BEGIN/END] markers)
V1_PORT_RE = re.compile(
    r'(?:^[ \t]*//[ \t]*\[MiSTer-DB9-Pro BEGIN\][^\n]*\n)?'
    r'^[ \t]*output[ \t]+reg[ \t]+saturn_unlocked[ \t]*=[ \t]*0[ \t]*,[^\n]*\n'
    r'(?:^[ \t]*//[ \t]*\[MiSTer-DB9-Pro END\][^\n]*\n)?',
    flags=re.MULTILINE,
)

# v1 casex branch (legacy): 'hFE: saturn_unlocked <= io_din[0];
V1_CASE_RE = re.compile(
    r'(?:^[ \t]*//[ \t]*\[MiSTer-DB9-Pro BEGIN\][^\n]*\n)?'
    r"^[ \t]*'hFE:[ \t]+saturn_unlocked[ \t]*<=[ \t]*io_din\[0\];[^\n]*\n"
    r'(?:^[ \t]*//[ \t]*\[MiSTer-DB9-Pro END\][^\n]*\n)?',
    flags=re.MULTILINE,
)


def _inject_pristine_hps_io(text: str, notes: list[str], path: Path) -> str:
    """Pristine upstream `hps_io.sv` has neither DB9 baseline nor Pro markers.
    Add the joy_raw input port + the 'h0f case branch that exposes it; the
    `upgrade_hps_io` body that runs after will then add saturn_unlocked +
    db9_key_gate using joy_raw as its anchor.

    Idempotent — early-returns if joy_raw is already declared.
    """
    if re.search(r'^[ \t]*input[ \t]+\[15:0\][ \t]+joy_raw,', text, re.MULTILINE):
        return text  # already injected (legacy or previous run)

    # 1. Insert joy_raw input before the ps2_key port. ps2_key has been a
    # core hps_io output since the module was created and lives outside the
    # analog joystick cluster, so it survives even a wholesale restructuring
    # of the analog ports.
    m = re.search(
        r'^([ \t]*)output[ \t]+reg[ \t]+\[10:0\][ \t]+ps2_key\b[^\n]*\n',
        text, re.MULTILINE,
    )
    if not m:
        notes.append(f'{path}: pristine inject — ps2_key anchor missing, joy_raw skipped')
    else:
        indent = m.group(1)
        insert = (
            f'{indent}// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
            f'{indent}input      [15:0] joy_raw,\n'
            f'{indent}// [MiSTer-DB9 END]\n'
        )
        text = text[:m.start()] + insert + text[m.start():]
        notes.append(f'{path}: pristine inject — added joy_raw input port')

    # 2. Insert 'h0f handler at the head of the casex(cmd) inside uio_block.
    # Anchor on the line `casex(cmd)` followed by the `// buttons and switches`
    # comment that's been stable since 2018.
    m = re.search(
        r'^([ \t]*)casex\(cmd\)\n'
        r'([ \t]*)// buttons and switches\n',
        text, re.MULTILINE,
    )
    if not m:
        notes.append(f'{path}: pristine inject — casex(cmd) anchor missing, \'h0f handler skipped')
    else:
        case_indent = m.group(2)
        insert = (
            f'{case_indent}// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
            f'{case_indent}// Reading user_io raw joy\n'
            f"{case_indent}'h0f: io_dout <= joy_raw;\n"
            f'{case_indent}// [MiSTer-DB9 END]\n'
        )
        text = text[:m.end()] + insert + text[m.end():]
        notes.append(f"{path}: pristine inject — added 'h0f joy_raw casex branch")

    return text


def upgrade_hps_io(path: Path) -> list[str]:
    if not path.exists():
        return [f'{path}: missing']
    text, nl = read_text(path)
    notes: list[str] = []
    orig = text

    # 0. Pristine pre-step: if upstream `sys/hps_io.sv` has no DB9 baseline at
    # all (no joy_raw input declared), inject it now so the legacy-shape passes
    # below have their anchors. No-op on already-patched files.
    text = _inject_pristine_hps_io(text, notes, path)

    # 1a. Strip v1 saturn_unlocked port if present (we'll add v1.5 form below).
    text2, n_v1_port = V1_PORT_RE.subn('', text)
    if n_v1_port:
        text = text2
        notes.append(f'{path}: stripped v1 saturn_unlocked port (will replace with v1.5)')

    # 1b. Strip v1 'hFE casex branch if present.
    text2, n_v1_case = V1_CASE_RE.subn('', text)
    if n_v1_case:
        text = text2
        notes.append(f"{path}: stripped v1 'hFE casex branch (gate observes cmd/byte_cnt directly)")

    # 1c. Add v1.5 saturn_unlocked port if not already present
    # in the v1.5 form (output without reg).
    has_v15_port = bool(re.search(
        r'^[ \t]*output[ \t]+saturn_unlocked\b', text, flags=re.MULTILINE,
    ))
    if not has_v15_port:
        m = re.search(
            r'^([ \t]*)input[ \t]+\[15:0\][ \t]+joy_raw,[^\n]*\n'
            r'(?:[ \t]*//[^\n]*\n)?',
            text,
            flags=re.MULTILINE,
        )
        if not m:
            notes.append(f'{path}: joy_raw input not found — v1.5 ports skipped')
        else:
            indent = m.group(1)
            insert = (
                f'{indent}// [MiSTer-DB9-Pro BEGIN] - key gate v1.5 (per-customer SipHash MAC; UIO_DB9_KEY 0xFE)\n'
                f'{indent}output            saturn_unlocked,\n'
                f'{indent}// [MiSTer-DB9-Pro END]\n'
            )
            text = text[:m.end()] + insert + text[m.end():]
            notes.append(f'{path}: added v1.5 saturn_unlocked port')

    # 1d. Add db9_key_gate instantiation just before the hps_io module's
    # endmodule (the FIRST endmodule in the file).
    if 'db9_key_gate' not in text:
        m = re.search(r'^endmodule\b[^\n]*\n', text, flags=re.MULTILINE)
        if not m:
            notes.append(f'{path}: no endmodule found — db9_key_gate skipped')
        else:
            insert = (
                '\n'
                '// [MiSTer-DB9-Pro BEGIN] - key gate v1.5 (40-byte UIO_DB9_KEY 0xFE bytestream)\n'
                '`include "db9_key_secret.vh"\n'
                '// `cmd` is declared inside the `uio_block` named always block, so reach\n'
                '// into it via SystemVerilog hierarchical name. Bare `cmd` would auto-\n'
                '// elaborate as an undriven 1-bit wire and the whole gate would be DCE\'d.\n'
                'db9_key_gate #(\n'
                '\t.MASTER_ROOT(`MASTER_ROOT)\n'
                ') u_db9_key_gate (\n'
                '\t.clk             (clk_sys),\n'
                '\t.cmd_db9         (uio_block.cmd == 16\'hFE),\n'
                '\t.byte_cnt        (byte_cnt[5:0]),\n'
                '\t.io_din          (io_din),\n'
                '\t.saturn_unlocked (saturn_unlocked)\n'
                ');\n'
                '// [MiSTer-DB9-Pro END]\n'
                '\n'
            )
            text = text[:m.start()] + insert + text[m.start():]
            notes.append(f'{path}: added db9_key_gate v1.5 instantiation')

    if text != orig:
        write_text(path, text, nl)
    return notes


# ---- sys/sys_top.v: add user_pp wire + per-pin prefix + emu hookup ----

USER_IO_RE = re.compile(
    r'^([ \t]*)assign[ \t]+USER_IO\[(\d)\][ \t]*=[ \t]*(.+?);[ \t]*$',
    flags=re.MULTILINE,
)
USER_IN_RE = re.compile(
    r'^([ \t]*)assign[ \t]+user_in\[(\d)\][ \t]*=[ \t]*(.+?);[ \t]*$',
    flags=re.MULTILINE,
)


def _inject_pristine_sys_top(text: str, notes: list[str], path: Path) -> str:
    """Pristine upstream `sys_top.v` has 7-bit USER_IO, no user_pp wire, no
    USER_OSD/USER_PP emu hookup. Inject the always-free DB9 baseline so the
    existing user_pp / user_mode migration steps can run.

    Single gate: the whole pristine inject only runs when `inout [6:0]
    USER_IO` is still present. Once we widen to `[7:0]` (or a legacy fork
    already widened it), every substep is skipped — this prevents partial
    re-injection on cores that landed at an intermediate ad-hoc state.
    """
    if not re.search(r'^[ \t]*inout[ \t]+\[6:0\][ \t]+USER_IO\b', text, re.MULTILINE):
        return text  # not pristine — let the legacy-path passes handle it

    # 1. Module port list — comment-out `output SD_SPI_CS,` (pin AE15 reused
    # for USER_IO[7]) and widen `inout [6:0] USER_IO` to `[7:0]`.
    if re.search(r'^[ \t]*output[ \t]+SD_SPI_CS,', text, re.MULTILINE):
        text = re.sub(
            r'^([ \t]*)output[ \t]+SD_SPI_CS,([^\n]*)\n',
            r'\1// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: SD_SPI_CS disabled, pin used for USER_IO[7]\n'
            r'\1//output        SD_SPI_CS,\2\n'
            r'\1// [MiSTer-DB9 END]\n',
            text, count=1, flags=re.MULTILINE,
        )
        notes.append(f'{path}: pristine inject — SD_SPI_CS port commented out')

    text = re.sub(
        r'^([ \t]*)inout[ \t]+\[6:0\][ \t]+USER_IO([^\n]*)\n',
        r'\1// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
        r'\1inout   [7:0] USER_IO\2\n'
        r'\1// [MiSTer-DB9 END]\n',
        text, count=1, flags=re.MULTILINE,
    )
    notes.append(f'{path}: pristine inject — USER_IO widened to 8 bits')

    # 2. deb_osd OR-gate with user_osd. Anchor on the exact upstream line.
    if 'btn_o | user_osd' not in text:
        m = re.search(
            r'^([ \t]*)deb_osd[ \t]*<=[ \t]*\{deb_osd\[6:0\],[ \t]*btn_o[ \t]*\|[ \t]*~KEY\[0\]\};[^\n]*\n',
            text, re.MULTILINE,
        )
        if m:
            indent = m.group(1)
            text = (
                text[:m.start()]
                + f'{indent}// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
                + f'{indent}deb_osd <= {{deb_osd[6:0], btn_o | user_osd | ~KEY[0]}};\n'
                + f'{indent}// [MiSTer-DB9 END]\n'
                + text[m.end():]
            )
            notes.append(f'{path}: pristine inject — deb_osd OR-gates user_osd')

    # 3. Widen `wire [6:0] user_out, user_in;` to `[7:0]` and add user_pp +
    # user_osd declarations next to it. The existing legacy-path code further
    # down adds the user_pp wire on its own; we do it here too in pristine
    # mode so the wrapper section gets all three lines together.
    if re.search(r'^[ \t]*wire[ \t]+\[6:0\][ \t]+user_out,[ \t]+user_in;', text, re.MULTILINE):
        text = re.sub(
            r'^([ \t]*)wire[ \t]+\[6:0\][ \t]+user_out,[ \t]+user_in;([^\n]*)\n',
            r'\1// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
            r'\1wire  [7:0] user_out, user_in;\2\n'
            r'\1wire  [7:0] user_pp;\n'
            r'\1wire        user_osd;\n'
            r'\1// [MiSTer-DB9 END]\n',
            text, count=1, flags=re.MULTILINE,
        )
        notes.append(f'{path}: pristine inject — user_out/user_in widened, user_pp + user_osd added')

    # 4. Replace pristine USER_IO drive section with the per-pin push-pull
    # form. We anchor on the section header comment + the assign block. The
    # block is a contiguous 14-line region (7 USER_IO + 7 user_in). After
    # injection the legacy-path rewrite_drive() pass downstream is a no-op
    # (every line already prefixed with `user_pp[N] ?`).
    pristine_block_re = re.compile(
        r'^assign[ \t]+USER_IO\[0\][ \t]*=[ \t]*'
        r'[^\n]*!user_out\[0\][^\n]*\n'
        r'(?:assign[ \t]+USER_IO\[[1-6]\][^\n]*\n){6}'
        r'\n'
        r'(?:assign[ \t]+user_in\[[0-6]\][^\n]*\n){7}',
        re.MULTILINE,
    )
    if pristine_block_re.search(text) and 'user_pp[0]' not in text:
        replacement = (
            '// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: USER_IO pin drive (per-pin push-pull via user_pp)\n'
            "assign USER_IO[0] = user_pp[0] ? user_out[0] :                       !user_out[0]  ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[1] = user_pp[1] ? user_out[1] :                       !user_out[1]  ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[2] = user_pp[2] ? user_out[2] : !(SW[1] ? HDMI_I2S   : user_out[2]) ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[3] = user_pp[3] ? user_out[3] :                       !user_out[3]  ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[4] = user_pp[4] ? user_out[4] : !(SW[1] ? HDMI_SCLK  : user_out[4]) ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[5] = user_pp[5] ? user_out[5] : !(SW[1] ? HDMI_LRCLK : user_out[5]) ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[6] = user_pp[6] ? user_out[6] :                       !user_out[6]  ? 1'b0 : 1'bZ;\n"
            "assign USER_IO[7] = user_pp[7] ? user_out[7] :                       !user_out[7]  ? 1'b0 : 1'bZ;\n"
            '\n'
            'assign user_in[0] = USER_IO[0];\n'
            'assign user_in[1] = USER_IO[1];\n'
            'assign user_in[2] = SW[1] | USER_IO[2];\n'
            'assign user_in[3] = USER_IO[3];\n'
            'assign user_in[4] = SW[1] | USER_IO[4];\n'
            'assign user_in[5] = SW[1] | USER_IO[5];\n'
            'assign user_in[6] = USER_IO[6];\n'
            'assign user_in[7] = USER_IO[7];\n'
            '// [MiSTer-DB9 END]\n'
        )
        text = pristine_block_re.sub(replacement, text, count=1)
        notes.append(f'{path}: pristine inject — USER_IO drive section rewritten with user_pp + 8th pin')

    # 5. Insert .USER_OSD / .USER_PP emu hookups right before .USER_OUT.
    # Idempotent: only inserts when .USER_OSD is missing.
    if not re.search(r'\.USER_OSD\(user_osd\)', text):
        m = re.search(
            r'^([ \t]*)\.USER_OUT\(user_out\),[^\n]*\n',
            text, re.MULTILINE,
        )
        if m:
            indent = m.group(1)
            insert = (
                f'{indent}// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
                f'{indent}.USER_OSD(user_osd),\n'
                f'{indent}.USER_PP(user_pp),\n'
                f'{indent}// [MiSTer-DB9 END]\n'
            )
            text = text[:m.start()] + insert + text[m.start():]
            notes.append(f'{path}: pristine inject — .USER_OSD + .USER_PP emu hookups')

    return text


def upgrade_sys_top(path: Path) -> list[str]:
    if not path.exists():
        return [f'{path}: missing']
    text, nl = read_text(path)
    notes: list[str] = []
    orig = text

    # 0. Pristine pre-step. If `sys_top.v` is straight from upstream
    # (no DB9 baseline at all), inject it now so the user_mode → user_pp
    # migration steps below have anchors to work with.
    text = _inject_pristine_sys_top(text, notes, path)

    has_user_pp = 'user_pp' in text
    has_user_mode = 'user_mode' in text

    if not has_user_pp and not has_user_mode:
        notes.append(f'{path}: no user_pp/user_mode references after pristine inject — sys_top untouched')
        if text != orig:
            write_text(path, text, nl)
        return notes

    # 1. Rewrite each USER_IO[N] / user_in[N] line: strip the legacy
    # `user_mode` middle ternary if present; for USER_IO, prefix with
    # `user_pp[N] ? user_out[N] :` if not already prefixed; for user_in, the
    # pristine simple read is always correct (push-pulled pins read back
    # their own driven value — harmless).
    def rewrite_drive(m: re.Match, kind: str) -> str:
        indent, n, expr = m.group(1), m.group(2), m.group(3)
        expr = strip_user_mode_ternary(expr)
        if kind == 'USER_IO' and 'user_pp' not in expr:
            return f'{indent}assign USER_IO[{n}] = user_pp[{n}] ? user_out[{n}] : {expr};'
        return f'{indent}assign {kind}[{n}] = {expr};'

    new_text, n_io = USER_IO_RE.subn(lambda m: rewrite_drive(m, 'USER_IO'), text)
    new_text, n_in = USER_IN_RE.subn(lambda m: rewrite_drive(m, 'user_in'), new_text)
    if n_io == 0 or n_in == 0:
        notes.append(f'{path}: USER_IO/user_in assigns not found ({n_io}/{n_in}) — aborting')
        return notes
    if new_text != text:
        text = new_text
        notes.append(f'{path}: rewrote {n_io} USER_IO + {n_in} user_in lines (user_pp prefix, user_mode strip)')

    # 2. Insert `wire [7:0] user_pp;` declaration after the existing
    # `wire [7:0] user_out, user_in;` line, if missing. Drop legacy
    # `wire [1:0] user_mode;` decl if present.
    if 'wire  [7:0] user_pp' not in text and 'wire [7:0] user_pp' not in text:
        m = re.search(
            r'^([ \t]*)wire[ \t]+\[7:0\][ \t]+user_out,[ \t]+user_in;[^\n]*\n',
            text,
            flags=re.MULTILINE,
        )
        if not m:
            notes.append(f'{path}: user_out/user_in wire decl not found — user_pp wire skipped')
        else:
            indent = m.group(1)
            insert = f'{indent}wire  [7:0] user_pp;\n'
            text = text[:m.end()] + insert + text[m.end():]
            notes.append(f'{path}: added user_pp wire decl')

    # Strip legacy user_mode wire decl (with surrounding marker lines if standalone).
    um_decl_re = re.compile(
        r'^[ \t]*wire[ \t]+\[1:0\][ \t]+user_mode;[^\n]*\n',
        flags=re.MULTILINE,
    )
    new_text, n = um_decl_re.subn('', text)
    if n:
        text = new_text
        notes.append(f'{path}: stripped wire [1:0] user_mode decl')

    # 3. Replace `.USER_MODE(user_mode),` emu hookup with `.USER_PP(user_pp),`.
    # If `.USER_MODE` is absent, insert `.USER_PP` after `.USER_OSD(user_osd),`.
    has_pp_hookup = bool(re.search(r'\.USER_PP\(user_pp\)', text))
    um_hookup_re = re.compile(
        r'^([ \t]*)\.USER_MODE\(user_mode\),[^\n]*\n',
        flags=re.MULTILINE,
    )
    m = um_hookup_re.search(text)
    if m:
        indent = m.group(1)
        if has_pp_hookup:
            replacement = ''  # PP already present; just drop USER_MODE
            notes.append(f'{path}: stripped .USER_MODE hookup (.USER_PP already present)')
        else:
            replacement = f'{indent}.USER_PP(user_pp),\n'
            notes.append(f'{path}: replaced .USER_MODE hookup with .USER_PP')
        text = text[:m.start()] + replacement + text[m.end():]
    elif not has_pp_hookup:
        # Insert .USER_PP after .USER_OSD if both are missing the new hookup.
        m_osd = re.search(
            r'^([ \t]*)\.USER_OSD\(user_osd\),[^\n]*\n',
            text,
            flags=re.MULTILINE,
        )
        if m_osd:
            indent = m_osd.group(1)
            insert = f'{indent}.USER_PP(user_pp),\n'
            text = text[:m_osd.end()] + insert + text[m_osd.end():]
            notes.append(f'{path}: added .USER_PP hookup after .USER_OSD')
        else:
            # Pre-USER_OSD-era sys_top.v (e.g. CosmicAvenger): no .USER_OSD
            # hookup either. Insert both `.USER_OSD(user_osd),` and
            # `.USER_PP(user_pp),` immediately before `.USER_OUT(user_out),`
            # in the emu instance. user_osd / user_pp wires are already
            # declared (or just added) in the file.
            m_out = re.search(
                r'^([ \t]*)\.USER_OUT\(user_out\),[^\n]*\n',
                text,
                flags=re.MULTILINE,
            )
            if m_out:
                indent = m_out.group(1)
                insert = (
                    f'{indent}.USER_OSD(user_osd),\n'
                    f'{indent}.USER_PP(user_pp),\n'
                )
                text = text[:m_out.start()] + insert + text[m_out.start():]
                notes.append(f'{path}: added .USER_OSD + .USER_PP hookups before .USER_OUT')
            else:
                notes.append(f'{path}: neither .USER_MODE/.USER_OSD/.USER_OUT hookup found — .USER_PP skipped')

    if text != orig:
        write_text(path, text, nl)
    return notes


# Strip the legacy `output [1:0] USER_MODE,` port. Marker lines are consumed
# only when BEGIN and END tightly bracket the single line — otherwise we'd
# leave a dangling marker from an unrelated multi-line block.
STRIP_USER_MODE_PORT_RE = re.compile(
    r'(?:^[ \t]*//[ \t]*\[MiSTer-DB9 BEGIN\][^\n]*\n'
    r'[ \t]*output[ \t]+\[1:0\][ \t]+USER_MODE,[^\n]*\n'
    r'[ \t]*//[ \t]*\[MiSTer-DB9 END\][^\n]*\n)'
    r'|'
    r'(?:^[ \t]*output[ \t]+\[1:0\][ \t]+USER_MODE,[^\n]*\n)',
    flags=re.MULTILINE,
)

# Strip `assign USER_MODE = JOY_FLAG[2:1];`. Same marker semantics as the port.
STRIP_USER_MODE_ASSIGN_RE = re.compile(
    r'(?:^[ \t]*//[ \t]*\[MiSTer-DB9 BEGIN\][^\n]*\n'
    r"[ \t]*assign[ \t]+USER_MODE[ \t]*=[ \t]*JOY_FLAG\[2:1\][ \t]*;?[^\n]*\n"
    r'[ \t]*//[ \t]*\[MiSTer-DB9 END\][^\n]*\n)'
    r'|'
    r"(?:^[ \t]*assign[ \t]+USER_MODE[ \t]*=[ \t]*JOY_FLAG\[2:1\][ \t]*;?[^\n]*\n)",
    flags=re.MULTILINE,
)


def strip_user_mode_ternary(expr: str) -> str:
    """Strip the legacy `|user_mode ? X :` or `user_mode[N] ? X :` middle ternary
    from a USER_IO/user_in drive expression. Handles both pristine form
    (clause at start) and the transitional dual-gated form where a `user_pp[N]
    ? user_out[N] :` prefix sits in front of the user_mode clause.

    Caveat: the regex assumes the user_mode "then" branch contains no `:` —
    true for every legacy sys_top.v drive line (the branch is always a bare
    `user_out[N]` or `1'b0`).

    Examples:
        "|user_mode ? user_out[0] : !user_out[0] ? 1'b0 : 1'bZ"
            -> "!user_out[0] ? 1'b0 : 1'bZ"
        "user_pp[1] ? user_out[1] : user_mode[0] ? user_out[1] : !user_out[1] ? 1'b0 : 1'bZ"
            -> "user_pp[1] ? user_out[1] : !user_out[1] ? 1'b0 : 1'bZ"
        "user_mode[0] ? 1'b0 : USER_IO[1]"
            -> "USER_IO[1]"
    """
    pp = re.match(
        r'(\s*user_pp\[\d\]\s*\?\s*(?:user_out|USER_IO)\[\d\]\s*:\s*)(.+)$',
        expr,
        flags=re.DOTALL,
    )
    prefix, rest = (pp.group(1), pp.group(2)) if pp else ('', expr)
    m = re.match(
        r'\s*(?:\|user_mode|user_mode\[\d\])\s*\?\s*[^:]+\s*:\s*(.+)$',
        rest,
        flags=re.DOTALL,
    )
    if m:
        return prefix + m.group(1).strip()
    return expr


def is_already_wrapped(text: str, match_start: int, comment_prefix: str = '//') -> bool:
    """Return True if the line at `match_start` is currently inside an open
    `[MiSTer-DB9 BEGIN/END]` (or Pro) block. We count BEGIN vs END in the
    nearest ~6 preceding lines: an unmatched BEGIN means we're inside a
    block; matched (or no markers) means we're not."""
    head = text[:match_start]
    preceding = head.split('\n')[-7:]
    open_blocks = 0
    for line in preceding:
        if '[MiSTer-DB9' in line and 'BEGIN]' in line:
            open_blocks += 1
        elif '[MiSTer-DB9' in line and 'END]' in line:
            open_blocks -= 1
    return open_blocks > 0


def wrap_block(text: str, line_re: re.Pattern, label: str, comment_prefix: str = '//') -> tuple[str, int]:
    """Find the line(s) matching `line_re` (which must contain a (?P<indent>...)
    group). If the FIRST match is not already wrapped, wrap the whole match
    range with `[MiSTer-DB9 BEGIN] - <label>` / `[MiSTer-DB9 END]` markers.
    Returns (new_text, n_wrapped)."""
    m = line_re.search(text)
    if not m:
        return text, 0
    if is_already_wrapped(text, m.start(), comment_prefix):
        return text, 0
    indent = m.group('indent')
    prefix = f'{indent}{comment_prefix} [MiSTer-DB9 BEGIN] - {label}\n'
    suffix = f'{indent}{comment_prefix} [MiSTer-DB9 END]\n'
    # Ensure match consumes through end-of-line
    end = text.find('\n', m.end() - 1)
    end = end + 1 if end != -1 else len(text)
    return text[:m.start()] + prefix + text[m.start():end] + suffix + text[end:], 1


def wrap_range(text: str, start_re: re.Pattern, end_re: re.Pattern,
               outer_label: str, inner_label: str | None = None) -> tuple[str, int]:
    """Wrap the multi-line block from `start_re` match to `end_re` match
    with `[MiSTer-DB9 BEGIN/END] - outer_label`. If `inner_label` is given,
    nests `[MiSTer-DB9-Pro BEGIN/END] - inner_label` immediately inside —
    used when a block contains both DB9 baseline and Pro extensions inline
    on the same lines (e.g., USER_IO drive with `|user_mode` DB9 ternaries
    AND `user_pp[N] ?` Pro prefix). Skips if already wrapped."""
    m_start = start_re.search(text)
    if not m_start:
        return text, 0
    if is_already_wrapped(text, m_start.start()):
        return text, 0
    m_end = end_re.search(text, m_start.end())
    if not m_end:
        return text, 0
    indent = m_start.group('indent')
    block_end = text.find('\n', m_end.end() - 1)
    block_end = block_end + 1 if block_end != -1 else len(text)

    open_markers = f'{indent}// [MiSTer-DB9 BEGIN] - {outer_label}\n'
    close_markers = f'{indent}// [MiSTer-DB9 END]\n'
    if inner_label:
        open_markers += f'{indent}// [MiSTer-DB9-Pro BEGIN] - {inner_label}\n'
        close_markers = f'{indent}// [MiSTer-DB9-Pro END]\n' + close_markers
    return (text[:m_start.start()] + open_markers
            + text[m_start.start():block_end]
            + close_markers + text[block_end:]), 1


# ---- Marker wrap: hps_io.sv ----

def wrap_hps_io_markers(path: Path) -> list[str]:
    if not path.exists():
        return []
    text, nl = read_text(path)
    notes: list[str] = []
    orig = text

    # joy_raw input port (multiple consecutive Pro/non-Pro additions may live here;
    # only wrap the joy_raw line itself)
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)input[ \t]+\[15:0\][ \t]+joy_raw,[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: joy_raw input',
    )
    if n: notes.append(f'{path}: wrapped joy_raw input port')

    # 'h0f case
    text, n = wrap_block(
        text,
        re.compile(r"^(?P<indent>[ \t]*)'h0f:[ \t]+io_dout[ \t]*<=[ \t]*joy_raw;[^\n]*$", re.MULTILINE),
        'DB9/SNAC8 support: joy_raw command handler',
    )
    if n: notes.append(f"{path}: wrapped 'h0f case")

    if text != orig:
        write_text(path, text, nl)
    return notes


# ---- Marker wrap: sys_top.v ----

def wrap_sys_top_markers(path: Path) -> list[str]:
    if not path.exists():
        return []
    text, nl = read_text(path)
    notes: list[str] = []
    orig = text

    # `inout [7:0] USER_IO` port — fork-only widening from upstream's [6:0]
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)inout[ \t]+\[7:0\][ \t]+USER_IO[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: USER_IO widened to 8 pins',
    )
    if n: notes.append(f'{path}: wrapped USER_IO port')

    # `//output SD_SPI_CS,` (commented-out original — pin reassigned to USER_IO[7])
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)//output[ \t]+SD_SPI_CS,[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: SD_SPI_CS disabled, pin used for USER_IO[7]',
    )
    if n: notes.append(f'{path}: wrapped SD_SPI_CS comment-out')

    # deb_osd line carrying user_osd
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)deb_osd[ \t]*<=[ \t]*\{deb_osd\[6:0\],[ \t]*btn_o[ \t]*\|[ \t]*user_osd[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: deb_osd OR-includes user_osd',
    )
    if n: notes.append(f'{path}: wrapped deb_osd line')

    # `wire [7:0] user_out, user_in;` + the `wire [7:0] user_pp;` decl that
    # upgrade_sys_top inserted right after it. Wrap both lines as a unit so the
    # marker BEGIN/END encloses the user_pp decl too (otherwise it lands
    # OUTSIDE the marker block, which trips the marker audit).
    text, n = wrap_block(
        text,
        re.compile(
            r'^(?P<indent>[ \t]*)wire[ \t]+\[7:0\][ \t]+user_out,[ \t]+user_in;[^\n]*\n'
            r'(?:[ \t]*wire[ \t]+\[7:0\][ \t]+user_pp;[^\n]*)?',
            re.MULTILINE,
        ),
        'DB9/SNAC8 support: user_out/user_in widened to 8 pins + user_pp decl',
    )
    if n: notes.append(f'{path}: wrapped user_out/user_in (+user_pp) wire decls')

    # `.USER_OSD(user_osd),` emu hookup
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)\.USER_OSD\(user_osd\),[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: USER_OSD hookup',
    )
    if n: notes.append(f'{path}: wrapped .USER_OSD hookup')

    # `.USER_PP(user_pp),` emu hookup
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)\.USER_PP\(user_pp\),[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: USER_PP hookup (per-pin push-pull mask)',
    )
    if n: notes.append(f'{path}: wrapped .USER_PP hookup')

    # USER_IO[N] / user_in[N] drive section: 8+8 lines with `user_pp[N] ?`
    # prefix. Single DB9 marker wraps the whole block (post-USER_MODE).
    start_re = re.compile(
        r'^(?P<indent>[ \t]*)assign[ \t]+USER_IO\[0\][ \t]*=', re.MULTILINE,
    )
    end_re = re.compile(
        r'^[ \t]*assign[ \t]+user_in\[7\][ \t]*=[^\n]*$', re.MULTILINE,
    )
    text, n = wrap_range(
        text, start_re, end_re,
        outer_label='DB9/SNAC8 support: USER_IO pin drive (per-pin push-pull via user_pp)',
    )
    if n: notes.append(f'{path}: wrapped USER_IO drive section')

    # Replace the misleading upstream section header. Pristine upstream calls
    # this section "User I/O (USB 3.0 connector)" — accurate for the physical
    # connector form factor, but post-fork the same pins also carry DB9/SNAC8
    # controller protocols, MT32-pi I2C, and HDMI passthrough. Update the
    # comment so a reader doesn't think this is just USB.
    new_header_re = re.compile(
        r'^[ \t]*///+[ \t]*User I/O \(USB 3\.0 connector\)[ \t]*///+[ \t]*$',
        re.MULTILINE,
    )
    if 'User I/O (USB 3.0 connector / DB9' not in text:
        text, n_hdr = new_header_re.subn(
            '////////////////  User I/O (USB 3.0 connector / DB9/SNAC8 controllers / MT32-pi I2C / HDMI I2S audio) /////////////////////////',
            text, count=1,
        )
        if n_hdr: notes.append(f'{path}: updated misleading "USB 3.0 connector" section header')

    if text != orig:
        write_text(path, text, nl)
    return notes


# ---- Marker wrap: sys.tcl ----

def wrap_sys_tcl_markers(path: Path) -> list[str]:
    """Inject the DB9 baseline into pristine `sys/sys.tcl` (PIN_AE15 →
    USER_IO[7], comment-out the conflicting SD_SPI_CS pin assignment) and
    wrap any existing equivalent lines from a legacy patched fork with
    `[MiSTer-DB9 BEGIN/END]` markers if they're not already wrapped.

    Idempotent — pristine inject only runs when the sentinel string
    `USER_IO[7]` is absent.
    """
    if not path.exists():
        return []
    text, nl = read_text(path)
    notes: list[str] = []
    orig = text

    # 1. Pristine inject: add `USER_IO[7]` line above `USER_IO[6]` in the
    # USER PORT block. Idempotent on the sentinel "USER_IO[7]" string.
    if 'USER_IO[7]' not in text:
        m = re.search(
            r'^([ \t]*)set_location_assignment[ \t]+PIN_AF17[ \t]+-to[ \t]+USER_IO\[6\][^\n]*\n',
            text, re.MULTILINE,
        )
        if m:
            indent = m.group(1)
            insert = (
                f'{indent}# [MiSTer-DB9 BEGIN] - DB9/SNAC8 support\n'
                f'{indent}set_location_assignment PIN_AE15 -to USER_IO[7]\n'
                f'{indent}# [MiSTer-DB9 END]\n'
            )
            text = text[:m.start()] + insert + text[m.start():]
            notes.append(f'{path}: pristine inject — added PIN_AE15 -> USER_IO[7]')
        else:
            notes.append(f'{path}: pristine inject — USER_IO[6] anchor missing, USER_IO[7] skipped')

    # 2. Pristine inject: comment-out `set_location_assignment PIN_AE15 -to
    # SD_SPI_CS` (the original pin assignment that conflicts with USER_IO[7]).
    # Idempotent: only runs when the live (uncommented) line is still present.
    live_sd_re = re.compile(
        r'^([ \t]*)set_location_assignment[ \t]+PIN_AE15[ \t]+-to[ \t]+SD_SPI_CS([^\n]*)\n',
        re.MULTILINE,
    )
    m = live_sd_re.search(text)
    if m:
        indent = m.group(1)
        rest = m.group(2)
        replacement = (
            f'{indent}# [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: PIN_AE15 reassigned to USER_IO[7]\n'
            f'{indent}#set_location_assignment PIN_AE15 -to SD_SPI_CS{rest}\n'
            f'{indent}# [MiSTer-DB9 END]\n'
        )
        text = text[:m.start()] + replacement + text[m.end():]
        notes.append(f'{path}: pristine inject — SD_SPI_CS pin assignment commented out')

    # PIN_AE15 -> USER_IO[7] — wrap if a legacy fork has the line bare.
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)set_location_assignment[ \t]+PIN_AE15[ \t]+-to[ \t]+USER_IO\[7\][^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support',
        comment_prefix='#',
    )
    if n: notes.append(f'{path}: wrapped PIN_AE15 -> USER_IO[7]')

    # Commented-out PIN_AE15 -> SD_SPI_CS
    text, n = wrap_block(
        text,
        re.compile(r'^(?P<indent>[ \t]*)#set_location_assignment[ \t]+PIN_AE15[ \t]+-to[ \t]+SD_SPI_CS[^\n]*$', re.MULTILINE),
        'DB9/SNAC8 support: PIN_AE15 reassigned to USER_IO[7]',
        comment_prefix='#',
    )
    if n: notes.append(f'{path}: wrapped commented SD_SPI_CS')

    if text != orig:
        write_text(path, text, nl)
    return notes


# ---- <core>.sv: add USER_PP port + default driver ----

def upgrade_core_emu(core_dir: Path) -> list[str]:
    """Add `output [7:0] USER_PP` port + `assign USER_PP = 8'h00;` default
    driver to every top-level `.sv` that declares `module emu`. Without this
    the patched `sys/sys_top.v` (which now hooks `.USER_PP(user_pp)`) fails
    elaboration on cores not yet processed by `port_batch_*.py` (Gameboy,
    Atari800, console cores, etc.).

    `port_batch_*.py` is responsible for swapping the default `'0` driver
    with the wrapper-based `USER_PP_DRIVE` once a core lands at wrapper-thin
    form. Framework just keeps the build green for non-port_batch cores."""
    notes: list[str] = []
    candidates = []
    for sv in core_dir.glob('*.sv'):
        try:
            t = sv.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        if re.search(r'^\s*module\s+emu\s*[\(#]', t, re.MULTILINE):
            candidates.append(sv)
    if not candidates:
        return [f'{core_dir}: no top-level <core>.sv with `module emu` found']

    for sv in candidates:
        text, nl = read_text(sv)
        orig = text

        # 0. Strip legacy `output [1:0] USER_MODE,` port (with surrounding
        # marker lines IF they tightly bracket the single line) and `assign
        # USER_MODE = JOY_FLAG[2:1];` driver. USER_MODE has been folded into
        # USER_PP. Markers are only consumed when both BEGIN and END are
        # present — otherwise we'd leave a dangling marker from a multi-line
        # block.
        text2, n_um_port = STRIP_USER_MODE_PORT_RE.subn('', text)
        if n_um_port:
            text = text2
            notes.append(f'{sv.name}: stripped USER_MODE port')

        text2, n_um_assign = STRIP_USER_MODE_ASSIGN_RE.subn('', text)
        if n_um_assign:
            text = text2
            notes.append(f'{sv.name}: stripped USER_MODE = JOY_FLAG[2:1] driver')

        if 'USER_PP' in text:
            if text != orig:
                write_text(sv, text, nl)
            notes.append(f'{sv.name}: USER_PP already present — no port insertion')
            continue

        # 1. Insert `output [7:0] USER_PP,` port after USER_OSD (USER_MODE no
        # longer exists). Mirror the existing line's whitespace style.
        m = re.search(
            r'^([ \t]*)output[ \t]+USER_OSD,[^\n]*\n',
            text, re.MULTILINE,
        )
        if not m:
            notes.append(f'{sv.name}: USER_OSD port not found — skipping USER_PP insertion')
            if text != orig:
                write_text(sv, text, nl)
            continue
        indent = m.group(1)
        line = m.group(0)
        kw_gap = '\t' if '\t' in line.split('output', 1)[1][:2] else '  '
        port_insert = (
            f'{indent}// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: per-pin push-pull mask\n'
            f'{indent}output{kw_gap}[7:0] USER_PP,\n'
            f'{indent}// [MiSTer-DB9 END]\n'
        )
        text = text[:m.end()] + port_insert + text[m.end():]

        # 2. Insert default `assign USER_PP = 8'h00;` driver right after the
        # closing `);` of the emu module port list. port_batch_*.py replaces
        # this default with `assign USER_PP = USER_PP_DRIVE;` when a core
        # lands at wrapper-thin form.
        emu_re = re.compile(r'^\s*module\s+emu\b', re.MULTILINE)
        em = emu_re.search(text)
        if em:
            close_re = re.compile(r'^\s*\);\s*$', re.MULTILINE)
            cm = close_re.search(text, em.end())
            if cm:
                insert_pos = cm.end() + 1  # after the `\n` of `);` line
                assign_block = (
                    '\n// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: USER_PP default (port_batch replaces with USER_PP_DRIVE)\n'
                    "assign USER_PP = 8'h00;\n"
                    '// [MiSTer-DB9 END]\n'
                )
                text = text[:insert_pos] + assign_block + text[insert_pos:]
        if text != orig:
            write_text(sv, text, nl)
        notes.append(f'{sv.name}: added USER_PP port + default driver')
    return notes


def resolve_hps_io(sys_dir: Path) -> Path:
    """Pre-SV-rename forks ship `sys/hps_io.v`; post-rename ones ship
    `sys/hps_io.sv`. The upgrader's regex transforms (saturn_unlocked port,
    db9_key_gate instantiation, marker wraps) are extension-agnostic — they
    operate on text. Return whichever exists; prefer .sv when both are
    present (shouldn't happen, but defines a tiebreaker)."""
    sv = sys_dir / 'hps_io.sv'
    v = sys_dir / 'hps_io.v'
    if sv.exists():
        return sv
    return v


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    d = Path(argv[0]).resolve()
    if not d.is_dir():
        print(f'{d}: not a directory', file=sys.stderr)
        return 1
    hps_io = resolve_hps_io(d / 'sys')
    # Pass 1: Pro extensions (saturn_unlocked, user_pp).
    for note in upgrade_hps_io(hps_io):
        print(f'  {note}')
    for note in upgrade_sys_top(d / 'sys' / 'sys_top.v'):
        print(f'  {note}')
    # Pass 2: wrap legacy DB9 additions with [MiSTer-DB9 BEGIN/END] markers.
    for note in wrap_hps_io_markers(hps_io):
        print(f'  {note}')
    for note in wrap_sys_top_markers(d / 'sys' / 'sys_top.v'):
        print(f'  {note}')
    for note in wrap_sys_tcl_markers(d / 'sys' / 'sys.tcl'):
        print(f'  {note}')
    # Pass 3: add USER_PP port + default driver to <core>.sv emu module.
    for note in upgrade_core_emu(d):
        print(f'  {note}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
