#!/usr/bin/env python3
"""Apply the non-DB9 deltas between sys/emu_ports.vh and a fork <core>.sv.

The fork keeps an inline `module emu (...)` port list instead of upstream's
`include "sys/emu_ports.vh"`, so every upstream port-list change has to be
carried across by hand. This does the mechanical part:

  * a port upstream declares and the core does not gets inserted at the same
    relative position, plus an `assign <NAME> = 0;` default for outputs;
  * a width that upstream narrowed or widened is rewritten to match.

DB9 ports (USER_IN, USER_OUT, USER_OSD, USER_PP) are fork extensions and are
never touched. Line endings are preserved. Prints every change; makes none
when there is nothing to do.

Usage: sync_emu_ports.py <core.sv> <sys/emu_ports.vh>
"""
import re
import sys

DB9_PORTS = {'USER_IN', 'USER_OUT', 'USER_OSD', 'USER_PP'}
DECL = re.compile(r'^(\s*)(input|output|inout)\b([^;]*?)\b([A-Za-z_]\w*)\s*(,?)\s*(//.*)?$')


def parse(lines):
    """Ordered [(index, indent, dir, mid, name)] for port declarations."""
    out = []
    for i, ln in enumerate(lines):
        m = DECL.match(ln.rstrip('\r\n'))
        if m:
            out.append((i, m.group(1), m.group(2), m.group(3), m.group(4)))
    return out


def emu_body(lines):
    """Line range of the inline `module emu (...)` port list."""
    start = None
    for i, ln in enumerate(lines):
        if start is None and re.match(r'^\s*module\s+emu\b', ln):
            start = i
        elif start is not None and re.match(r'^\s*\);', ln):
            return start, i
    raise SystemExit('could not locate the module emu port list')


def main():
    core_p, ports_p = sys.argv[1], sys.argv[2]
    core = open(core_p, encoding='utf-8', newline='').readlines()
    ports = open(ports_p, encoding='utf-8', newline='').readlines()
    eol = '\r\n' if core and core[0].endswith('\r\n') else '\n'

    lo, hi = emu_body(core)
    up = parse(ports)
    mine = {n: (i, ind, d, mid) for i, ind, d, mid, n in parse(core[lo:hi])}
    mine = {n: (i + lo, ind, d, mid) for n, (i, ind, d, mid) in mine.items()}

    changed = []
    # 1. widths
    for _, _, d, mid, name in up:
        if name in DB9_PORTS or name not in mine:
            continue
        i, ind, myd, mymid = mine[name]
        w_up = re.search(r'\[[^\]]+\]', mid)
        w_me = re.search(r'\[[^\]]+\]', mymid)
        if w_up and w_me and w_up.group(0) != w_me.group(0):
            core[i] = core[i].replace(w_me.group(0), w_up.group(0), 1)
            changed.append(f'{name}: {w_me.group(0)} -> {w_up.group(0)}')

    # 2. missing ports, inserted after the nearest preceding upstream port the
    #    core already declares (keeps upstream's ordering).
    up_names = [n for *_, n in up]
    added = []
    for pos, (_, _, d, mid, name) in enumerate(up):
        if name in DB9_PORTS or name in mine:
            continue
        anchor = None
        for prev in reversed(up_names[:pos]):
            if prev in mine:
                anchor = mine[prev][0]
                break
        if anchor is None:
            changed.append(f'{name}: SKIPPED (no anchor)')
            continue
        indent = mine[up_names[pos - 1]][1] if up_names[pos - 1] in mine else '\t'
        core.insert(anchor + 1, f'{indent}{d}{mid}{name},{eol}')
        # re-index everything after the insertion
        mine = {n: (i + 1 if i > anchor else i, a, b, c)
                for n, (i, a, b, c) in mine.items()}
        mine[name] = (anchor + 1, indent, d, mid)
        added.append((name, d))
        changed.append(f'{name}: added ({d})')

    # 3. defaults for added outputs, next to the sibling that already has one
    for name, d in added:
        if d != 'output':
            continue
        pos = up_names.index(name)
        sib = None
        for prev in reversed(up_names[:pos]):
            for i, ln in enumerate(core):
                if re.match(rf'^\s*assign\s+{re.escape(prev)}\s*=', ln):
                    sib = i
                    break
            if sib is not None:
                break
        if sib is None:
            changed.append(f'{name}: NO DEFAULT ASSIGNED (add by hand)')
            continue
        core.insert(sib + 1, f'assign {name} = 0;{eol}')
        changed.append(f'{name}: assign {name} = 0;')

    if changed:
        open(core_p, 'w', encoding='utf-8', newline='').writelines(core)
    print('\n'.join('  ' + c for c in changed) if changed else '  nothing to apply')


if __name__ == '__main__':
    main()
