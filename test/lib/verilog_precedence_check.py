#!/usr/bin/env python3
# Verilog `||` / `&&` operator-precedence defect check.
#
# `else if (MD_ID == 4'hF || 4'hA)` parses as `(MD_ID==4'hF) || (4'hA)`:
# `4'hA` is a bare non-zero constant operand of `||`, so the whole condition
# is unconditionally true and the module's detection arm is dead. This is a
# real, recurring, high-blast-radius bug (Saturn_MiSTer 3a94b0a, SMPC.sv:
# `MD_ID == 4'hF || 4'hA` -> the entire MD_ID classification dead) that no
# delimiter / connectivity check can see, and that FOSS Verilog parsers
# cannot flag without also false-positiving on Quartus-valid idioms
# (coresv_lint.sh's rejected-parser rationale).
#
# INVARIANT (always a defect, never legitimate): a numeric / base literal
# appearing as the WHOLE immediate operand of a logical `||` / `&&`. The
# detector is RHS-form only (literal immediately AFTER the operator) -- the
# LHS-form's sole fleet occurrence (S32X .../CACHE.sv `==? 4'b001? &&`, a
# SystemVerilog wildcard-equality RHS) is a false positive, so it is
# deliberately not implemented. Validated: 0 hits across 1376 real fleet
# .v/.sv; the 3a94b0a pre-fix line matches, the post-fix does not.
#
# ZERO-FP construction:
#   * mandatory length-preserving mask() (// , /* */ , "..." blanked;
#     Verilog `'` is a base literal, NEVER a string -> must not open a span)
#     -- copied from coresv_lint.sh; without it a comment / $display string
#     containing `|| 4` would be a guaranteed FP.
#   * trailing operand-terminator alternation: the literal is flagged only
#     when followed by `) ; , ? :` / `begin` / another `||`/`&&` / EOL. If a
#     tighter operator follows (`&& 4'hF > INT_MASK`) the literal heads a
#     sub-expression -> correct Verilog -> not matched.
#   * value guard: skip when the literal's value is 0 or 1 -- removes the
#     identity / default-operand / loop-guard idioms (`|| 1'b0`, `&& 1`,
#     `for(;j||1;)`) structurally. The 3a94b0a `4'hA` (=10) still flags.
#
# SCOPE: every .v / .sv under the core dir, RECURSIVE (not just the emu-top)
# -- the 3a94b0a defect lives in rtl/Saturn/SMPC.sv, never <core>.sv. Pure
# Python, no parser / iverilog / network. In merge_validate.sh this is a
# regression-DELTA token (it scans upstream-origin RTL too; a pre-existing
# upstream precedence quirk must never wedge the sync -- only a merge that
# NEWLY introduces one trips it).
#
# Usage:  verilog_precedence_check.py <core_dir> [<ignored_core_sv>]
# Exit:   0 = clean / n-a; 1 = FATAL (>=1 bare-literal ||/&& operand,
#         value not in {0,1}); 2 = no .v/.sv at all (callers fail-open).

import os
import re
import sys

# sized (4'hA, 32'd0, 1'b0) | unsized base ('h1F, 'b0) | plain int >=2-or-1
# (leading [1-9] so it cannot start mid-identifier; plain 0 is excluded
# from LIT, plain 1 is value-guarded out below).
_LIT = (r"(?:[0-9][0-9_]*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ?_]+"
        r"|'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ?_]+"
        r"|[1-9][0-9_]*)")
DEFECT_RE = re.compile(
    r"(\|\||&&)\s*(" + _LIT + r")\s*([);,?:]|\bbegin\b|\|\||&&|$)", re.M)


def mask(s):
    """Length-preserving blank of // , /* */ , "..." (coresv_lint.sh's
    mask, verbatim). ONLY double quotes open a string; Verilog `'` is a
    base literal / cast, never a string."""
    out, i, n = [], 0, len(s)
    while i < n:
        t = s[i:i + 2]
        if t == "//":
            j = s.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif t == "/*":
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(" " * (j - i))
            i = j
        elif s[i] == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


_BASE = {"b": 2, "o": 8, "d": 10, "h": 16}


def lit_value(tok):
    """Numeric value of a matched literal, or None if not cleanly decidable
    (x/z/? bits). None is treated as NOT in {0,1} -> still flagged (a bare
    metavalue literal as a ||/&& operand is the same defect)."""
    tok = tok.replace("_", "")
    if "'" in tok:
        digits = tok.split("'", 1)[1]
        if digits[:1] in "sS":
            digits = digits[1:]
        radix = _BASE.get(digits[:1].lower())
        digits = digits[1:]
        if radix is None or not digits:
            return None
        try:
            return int(digits, radix)
        except ValueError:
            return None                  # x / z / ? present
    try:
        return int(tok, 10)
    except ValueError:
        return None


def scan_file(path):
    """Return (line, op, lit, ctx) of the first defect, or None."""
    raw = open(path, "rb").read().decode("latin1")
    m = mask(raw)
    for mm in DEFECT_RE.finditer(m):
        op, lit = mm.group(1), mm.group(2)
        v = lit_value(lit)
        if v in (0, 1):
            continue                     # identity / default / loop-guard
        ln = m.count("\n", 0, mm.start(2)) + 1
        lines = raw.splitlines()
        ctx = lines[ln - 1].strip()[:100] if ln <= len(lines) else ""
        return (ln, op, lit, ctx)
    return None


def main(argv):
    if len(argv) < 2:
        print("usage: verilog_precedence_check.py <core_dir> "
              "[<ignored>]", file=sys.stderr)
        return 2
    core_dir = argv[1].rstrip("/")
    if not os.path.isdir(core_dir):
        print(f"  vprec: FAIL core dir not found: {core_dir}")
        return 2

    files = []
    for root, dirs, fs in os.walk(core_dir):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in sorted(fs):
            if f.endswith((".v", ".sv")):
                files.append(os.path.join(root, f))
    if not files:
        print(f"  vprec: n/a  no .v/.sv under {core_dir}")
        return 0

    for p in sorted(files):
        try:
            hit = scan_file(p)
        except OSError as e:
            print(f"  vprec: FAIL parse error ({e})")
            return 2
        if hit:
            ln, op, lit, ctx = hit
            rel = os.path.relpath(p, core_dir)
            print(f"  vprec: FAIL {rel}:{ln} bare literal `{lit}` is the "
                  f"whole operand of `{op}` (precedence: `==`/`!=` binds "
                  f"tighter than `{op}` -> constant-true arm, the 3a94b0a "
                  f"class)")
            if ctx:
                print(f"    {ln}: {ctx}")
            return 1
    print(f"  vprec: PASS  {len(files)} .v/.sv clean (no bare ||/&& "
          f"literal operand)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
