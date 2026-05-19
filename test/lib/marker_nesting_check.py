#!/usr/bin/env python3
# Fork-marker nesting / balance validator.
#
# step6.sh #4 only COUNTS [MiSTer-DB9 BEGIN/END] / [MiSTer-DB9-Pro BEGIN/END]
# per <core>.sv (equal-count = pass). A count is blind to mis-nesting: a
# `[MiSTer-DB9-Pro END]` that closes a `[MiSTer-DB9 BEGIN]` (or vice-versa),
# or an interleave that closes the outer family before the inner one, leaves
# both counts balanced yet violates the marker rules ("close inner before outer")
# and mis-classifies a gate-state region for the retag audit / the CI merge.
# A porter-regex bug or an upstream merge introduces exactly this; it was
# only ever caught by eyeball (SNES_MiSTer dc15e64 "remove orphan
# [MiSTer-DB9 END]" -- a 13/14 imbalance that shipped undetected).
#
# MECHANISM: a stack-based two-bracket-type balance over the marker tokens
# (same shape as coresv_lint.sh's delimiter balance, applied to markers).
# BEGIN pushes its family (DB9 | Pro); END must pop a same-family top.
# FATAL on: an END with an empty stack (orphan), an END whose family differs
# from the innermost open BEGIN (mis-nest / wrong-family close), or an open
# BEGIN still on the stack at EOF (severed block). Markers are disjoint by
# construction (`-Pro` has a hyphen where the plain form has a space), so the
# single regex cannot ambiguously match -- ZERO false positive by
# construction (a mis-nest cannot occur in a correctly-marked file).
#
# Each marker-bearing upstream-merged file is validated INDEPENDENTLY: a
# BEGIN in <core>.sv can never be closed from sys/sys_top.v, so the stacks
# do not share. Scope = the resolved top <core>.sv (find_core_sv, same as
# snac_active_check.py) plus sys/sys_top.v when present (both are
# upstream-merged and marker-bearing -> the merge-clobber risk surface).
#
# Usage:  marker_nesting_check.py <core_dir> [<core_sv_basename>]
# Exit:   0 = balanced / n-a (no markers = pristine upstream core);
#         1 = FATAL (orphan / mis-nest / unclosed);
#         2 = no <core>.sv resolvable (callers fail-open on 2).

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from emu_portmap_check import find_core_sv  # noqa: E402

# Disjoint by lexical construction: `[MiSTer-DB9 ` (space) vs
# `[MiSTer-DB9-Pro ` (hyphen). One regex, two capture groups.
MARK_RE = re.compile(r"\[MiSTer-DB9(-Pro)? (BEGIN|END)\]")


def scan(path):
    """Return (issue, marker_count) for one file. issue=None if balanced."""
    src = open(path, "rb").read().decode("latin1")
    stack = []                       # (family, line)
    n = 0
    for m in MARK_RE.finditer(src):
        n += 1
        fam = "Pro" if m.group(1) else "DB9"
        act = m.group(2)
        ln = src.count("\n", 0, m.start()) + 1
        if act == "BEGIN":
            stack.append((fam, ln))
            continue
        # END
        if not stack:
            return (f"line {ln}: orphan [MiSTer-DB9"
                    f"{'-Pro' if fam == 'Pro' else ''} END] "
                    f"(no open BEGIN -- the SNES dc15e64 class)"), n
        ofam, oln = stack[-1]
        if ofam != fam:
            return (f"line {ln}: [MiSTer-DB9"
                    f"{'-Pro' if fam == 'Pro' else ''} END] closes a "
                    f"[MiSTer-DB9{'-Pro' if ofam == 'Pro' else ''} BEGIN] "
                    f"opened at line {oln} (wrong-family / outer-closed-"
                    f"before-inner -- the marker rules 'close inner before "
                    f"outer')"), n
        stack.pop()
    if stack:
        ofam, oln = stack[-1]
        return (f"line {oln}: [MiSTer-DB9"
                f"{'-Pro' if ofam == 'Pro' else ''} BEGIN] is never closed "
                f"(severed block)"), n
    return None, n


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: marker_nesting_check.py <core_dir> "
              "[<core_sv_basename>]", file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if len(argv) == 3 and argv[2] and \
       os.path.isfile(os.path.join(core_dir, argv[2])):
        core_sv = os.path.join(core_dir, argv[2])
    else:
        core_sv = find_core_sv(core_dir)
    cb = os.path.basename(core_sv) if core_sv else ""
    print(f"  marker-coresv: {cb}")
    if not core_sv:
        print(f"  marker-nest: FAIL no <core>.sv declaring `module emu` "
              f"in {core_dir}")
        return 2

    targets = [core_sv]
    st = os.path.join(core_dir, "sys", "sys_top.v")
    if os.path.isfile(st):
        targets.append(st)

    total = 0
    for t in targets:
        try:
            issue, n = scan(t)
        except OSError as e:
            print(f"  marker-nest: FAIL parse error ({e})")
            return 2
        total += n
        if issue:
            rel = os.path.relpath(t, core_dir)
            print(f"  marker-nest: FAIL ({rel}) -- {issue}")
            return 1
    if total == 0:
        print(f"  marker-nest: n/a  no fork markers (pristine upstream) "
              f"[{cb}]")
        return 0
    print(f"  marker-nest: PASS  {total} markers balanced + nested "
          f"[{cb}{', sys_top.v' if len(targets) > 1 else ''}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
