#!/usr/bin/env python3
# Generic emu port-map completeness check.
#
# Enforces the general law the Arcade-Tecmo defect violated (the missing
# .USER_OSD(user_osd) connection in sys/sys_top.v left user_osd undriven and
# Start+C silently dead):
#
#   Every port declared by `module emu (...)` in <core>.sv MUST be connected
#   under SOME branch in its `emu emu (...)` instantiation in sys/sys_top.v,
#   and every connection there MUST correspond to a declared port.
#
# Tokenizing set-equality over the UNION of all `ifdef branches, NOT a
# hardcoded port-name list, so it catches Tecmo's missing .USER_OSD, a
# future missing .USER_PP/.joy_raw, a typo'd or stale connection — with zero
# knowledge of which ports the fork adds. Union (not depth-0) because a port
# legally declared unconditionally may be connected only under
# `ifndef MISTER_DUAL_SDRAM (VGA_DISABLE, SDRAM/SD pins); the real defect is
# a port connected under NO branch at all.
#
# Robust to: comments, packed dims, multi-name port lines, [MiSTer-DB9 ...]
# markers, `ifdef/`ifndef/`else/`endif nesting, the modern upstream
# "Update sys." pattern where the port list lives in an `include
# "sys/emu_ports.vh", and cores that ship more than one `module emu` (the
# build's real top is taken from the core's *.qip / *.qsf file list).
#
# Usage:  emu_portmap_check.py <core_dir>
# Exit:   0 = port sets equal (union over branches); 1 = mismatch (defect);
#         2 = parse/layout error.

import os
import re
import sys


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    # keep `// [MiSTer-DB9 ...]` markers — they delimit the fork-added ports
    text = re.sub(r"//[^\n]*",
                  lambda m: m.group(0) if "[MiSTer-DB9" in m.group(0) else "",
                  text)
    return text


MARK_BEGIN = re.compile(r"\[MiSTer-DB9(?:-Pro)? BEGIN\]")
MARK_END = re.compile(r"\[MiSTer-DB9(?:-Pro)? END\]")


def _sv_files(core_dir):
    return [f for f in sorted(os.listdir(core_dir)) if f.endswith(".sv")]


# Require the port-list "(" or parameter "#" right after `module emu` so
# `module emulator`/commented variants don't match (same anchor the porter
# scripts use).
MODULE_EMU = re.compile(r"^\s*module\s+emu\s*[#(]", re.M)


def _declares_emu(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return MODULE_EMU.search(fh.read()) is not None
    except OSError:
        return False


def find_core_sv(core_dir: str):
    """The top .sv = the file declaring `module emu`. When several .sv do
    (e.g. TI-99 ships ColecoVision.sv + Ti994a.sv), the build's real top is
    the .sv named in a (SYSTEM)VERILOG_FILE assignment in the core's *.qip /
    sys/*.qip / *.qsf — pick that one. Fall back to first match."""
    cands = [f for f in _sv_files(core_dir)
             if _declares_emu(os.path.join(core_dir, f))]
    if not cands:
        return None
    if len(cands) == 1:
        return os.path.join(core_dir, cands[0])

    listfiles = []
    for root, dirs, files in os.walk(core_dir):
        dirs[:] = [d for d in dirs if d != ".git"]   # never descend .git
        for f in files:
            if f.endswith((".qip", ".qsf")):
                listfiles.append(os.path.join(root, f))
    assign_re = re.compile(
        r"(?:SYSTEMVERILOG|VERILOG)_FILE\s+(?:\[[^\]]*\]\s*)?\"?([^\s\"\]]+\.sv)")
    for lf in listfiles:
        try:
            with open(lf, "r", errors="replace") as fh:
                txt = fh.read()
        except OSError:
            continue
        for m in assign_re.finditer(txt):
            base = os.path.basename(m.group(1))
            if base in cands:
                return os.path.join(core_dir, base)
    return os.path.join(core_dir, cands[0])


def expand_includes(region: str, core_dir: str, depth=0) -> str:
    """Splice `include "..." files (one level of recursion). Modern upstream
    moved the emu port list into sys/emu_ports.vh; the header is unparseable
    without it."""
    if depth > 4:
        return region
    out = []
    for ln in region.splitlines():
        m = re.match(r'\s*`include\s+"([^"]+)"', ln)
        if m:
            inc = m.group(1)
            cand = inc if os.path.isabs(inc) else os.path.join(core_dir, inc)
            try:
                with open(cand, "r", errors="replace") as fh:
                    sub = strip_comments(fh.read())
                out.append(expand_includes(sub, core_dir, depth + 1))
                continue
            except OSError:
                pass
        out.append(ln)
    return "\n".join(out)


def slice_paren_list(lines, start_pat):
    """Text between the first '(' after a line matching start_pat and the
    matching `);` line that closes the module/instance port list (MiSTer
    template always closes the port list with a `);` line)."""
    out, started, opened = [], False, False
    for ln in lines:
        if not started:
            if re.search(start_pat, ln):
                started = True
            else:
                continue
        if not opened:
            if "(" in ln:
                opened = True
                out.append(ln[ln.index("(") + 1:])
            continue
        if re.match(r"\s*\)\s*;", ln):
            break
        out.append(ln)
    return "\n".join(out) if (started and opened) else None


# `define/`undef are consumed before this gate in _port_lines, so only the
# conditional directives ever reach it.
PREPROC = re.compile(r"^\s*`(ifdef|ifndef|else|elsif|endif)\b")
IFDEF = re.compile(r"^\s*`(ifdef|ifndef|elsif)\s+([A-Za-z_]\w*)")
ELSE = re.compile(r"^\s*`else\b")
ENDIF = re.compile(r"^\s*`endif\b")
VMACRO = re.compile(r'VERILOG_MACRO\s+"?([A-Za-z_]\w*)')


def core_defines(core_dir: str):
    """Active `define set for the default build = uncommented
    `set_global_assignment -name VERILOG_MACRO "NAME=..."` lines in the
    core's top-level *.qsf. Commented (`#`) lines are inactive; variant
    files (sys/sys_dual_sdram.tcl etc.) are NOT part of the default build.
    `ifdef on these (MISTER_FB, MISTER_DUAL_SDRAM, ...) gates BOTH the emu
    header and the sys_top instance identically, so evaluating them removes
    all preprocessor-dead FB_*/SDRAM2_*/DDRAM_* noise while leaving the
    unconditional DB9 ports (the Tecmo class) fully checked."""
    defs = set()
    try:
        qsfs = [f for f in os.listdir(core_dir) if f.endswith(".qsf")]
    except OSError:
        return defs
    for q in qsfs:
        try:
            for ln in open(os.path.join(core_dir, q), "r", errors="replace"):
                s = ln.strip()
                if s.startswith("#"):
                    continue
                if "VERILOG_MACRO" not in s:
                    continue
                m = VMACRO.search(s)
                if m:
                    defs.add(m.group(1))
        except OSError:
            pass
    return defs
PORTDECL = re.compile(
    r"""^\s*(input|output|inout)\s+
        (?:(?:reg|wire|logic)\s+)?
        (?:signed\s+)?
        (?:\[[^\]]*\]\s*)*
        (.+)$
    """,
    re.X,
)
IDENT = re.compile(r"^([A-Za-z_]\w*)")
CONN = re.compile(r"^\s*\.([A-Za-z_]\w*)\s*\(")


def _port_lines(region: str, defs):
    """Yield (line, in_fork_marker) for every source line reachable under the
    core's actual `define set.

    Two interleaved state machines over the same raw stream:
      * a lightweight preprocessor (`ifdef/`ifndef/`else/`elsif/`endif
        evaluated against `defs`) so the emu header and the sys_top instance
        are compared on the SAME active build — this removes all
        FB_*/SDRAM2_*/DDRAM_*/SECOND_MT32 preprocessor-dead noise;
      * a fork-marker depth tracker ([MiSTer-DB9[-Pro] BEGIN]..[END],
        nesting allowed) so the caller can tell which ports/connections the
        FORK added vs. which are upstream. The Tecmo class is exactly a
        fork-added emu port left unconnected, so scoping the required
        direction to fork-marked ports is the correct generalization (no
        hardcoded port names; upstream ports stay out of scope)."""
    stack = []           # (active_now, taken_any) per open `ifdef
    local = set(defs)
    mark = 0             # fork-marker nesting depth
    for raw in region.splitlines():
        if MARK_BEGIN.search(raw):
            mark += 1
            continue
        if MARK_END.search(raw):
            mark = max(0, mark - 1)
            continue
        m = IFDEF.match(raw)
        if m:
            kind, name = m.group(1), m.group(2)
            parent_live = all(s[0] for s in stack)
            if kind == "elsif":
                if stack:
                    _a, taken = stack[-1]
                    cond = (name in local) and not taken and parent_live
                    stack[-1] = (cond, taken or cond)
                continue
            cond = (name in local) if kind == "ifdef" else (name not in local)
            stack.append((cond and parent_live, cond and parent_live))
            continue
        if ELSE.match(raw):
            if stack:
                _a, taken = stack[-1]
                parent_live = all(s[0] for s in stack[:-1])
                stack[-1] = ((not taken) and parent_live, True)
            continue
        if ENDIF.match(raw):
            if stack:
                stack.pop()
            continue
        if not all(s[0] for s in stack):
            continue
        dm = re.match(r"^\s*`define\s+([A-Za-z_]\w*)", raw)
        if dm:
            local.add(dm.group(1))
            continue
        um = re.match(r"^\s*`undef\s+([A-Za-z_]\w*)", raw)
        if um:
            local.discard(um.group(1))
            continue
        if PREPROC.match(raw):
            continue
        yield raw, (mark > 0)


def declared_ports(core_sv: str, core_dir: str, defs):
    """Return (all_ports, fork_ports). fork_ports = those declared inside
    [MiSTer-DB9*] markers (USER_OSD/USER_PP/joy_raw/...): the porting
    contract requires each of these to be connected in sys_top.v."""
    body = strip_comments(open(core_sv, "r", errors="replace").read())
    region = slice_paren_list(body.splitlines(), r"^\s*module\s+emu\b")
    if region is None:
        return None, None
    region = expand_includes(region, core_dir)
    all_ports, fork_ports = set(), set()
    for raw, in_fork in _port_lines(region, defs):
        m = PORTDECL.match(raw)
        if not m:
            continue
        rest = m.group(2).split(")")[0]
        for tok in rest.split(","):
            tok = tok.strip()
            if not tok:
                continue
            tok = re.sub(r"^\[[^\]]*\]\s*", "", tok.split("=")[0].strip())
            im = IDENT.match(tok)
            if im:
                all_ports.add(im.group(1))
                if in_fork:
                    fork_ports.add(im.group(1))
    return all_ports, fork_ports


def connected_ports(sys_top: str, defs):
    body = strip_comments(open(sys_top, "r", errors="replace").read())
    region = slice_paren_list(body.splitlines(), r"^\s*emu\s+emu\b")
    if region is None:
        return None
    names = set()
    for raw, _in_fork in _port_lines(region, defs):
        m = CONN.match(raw)
        if m:
            names.add(m.group(1))
    return names


def main(argv):
    if len(argv) != 2:
        print("usage: emu_portmap_check.py <core_dir>", file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    core_sv = find_core_sv(core_dir)
    # Machine-readable line so the fleet runner gets the resolved top .sv
    # from this single invocation (no second `--core-sv` process / no
    # duplicate find_core_sv tree walk per core).
    print(f"  portmap-coresv: {os.path.basename(core_sv) if core_sv else ''}")
    if not core_sv:
        print(f"  portmap: FAIL no <core>.sv declaring `module emu` in {core_dir}")
        return 2
    sys_top = os.path.join(core_dir, "sys", "sys_top.v")
    if not os.path.isfile(sys_top):
        print(f"  portmap: FAIL sys/sys_top.v not found in {core_dir}")
        return 2

    defs = core_defines(core_dir)
    all_ports, fork_ports = declared_ports(core_sv, core_dir, defs)
    connected = connected_ports(sys_top, defs)
    if all_ports is None:
        print(f"  portmap: FAIL could not parse `module emu` port list ({core_sv})")
        return 2
    if connected is None:
        print(f"  portmap: FAIL could not parse `emu emu` instantiation ({sys_top})")
        return 2

    cb = os.path.basename(core_sv)
    missing = sorted(fork_ports - connected)   # fork port declared, not wired
    stale = sorted(connected - all_ports)      # wired to a non-existent port

    if not missing and not stale:
        extra = "" if fork_ports else "  (no [MiSTer-DB9] emu ports?)"
        print(f"  portmap: ok   {len(fork_ports)} fork emu port(s) "
              f"connected, {len(connected)} conns valid  [{cb}]{extra}")
        return 0

    if missing:
        print(f"  portmap: FAIL fork-added emu port(s) DECLARED in {cb} "
              "(inside [MiSTer-DB9] markers) but NOT connected in "
              "sys_top.v emu instance (undriven — the Tecmo class):")
        print("           " + ", ".join(missing))
    if stale:
        print("  portmap: FAIL connection(s) in sys_top.v `emu emu` with NO "
              f"matching port on the emu module in {cb} (stale/typo):")
        print("           " + ", ".join(stale))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
