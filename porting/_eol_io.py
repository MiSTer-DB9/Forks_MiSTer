#!/usr/bin/env python3
"""Line-ending-preserving file I/O + batch CRLF/LF snapshot CLI.

Used by `upgrade_pro_additive.py`, `port_core_full.py`, and
`apply_db9_framework.sh`. Centralizes the byte-level read/write helpers
that detect a file's dominant line-ending style and round-trip through
LF-normalized in-memory text.

CLI (used by apply_db9_framework.sh around `git apply`, which always lands
LF lines and would otherwise mix them with CRLF targets):

    _eol_io.py snapshot <file>...           # prints "LF" or "CRLF" per file, space-separated
    _eol_io.py apply LF|CRLF <file>...      # rewrites each <file> with the given EOL
"""
from __future__ import annotations

import sys
from pathlib import Path


def detect_nl(data: bytes) -> str:
    crlf = data.count(b'\r\n')
    lf_only = data.count(b'\n') - crlf
    return 'CRLF' if crlf > lf_only else 'LF'


def read_text(path: Path) -> tuple[str, str]:
    data = path.read_bytes()
    nl = detect_nl(data)
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        text = data.decode('latin-1')
    return text.replace('\r\n', '\n'), nl


def write_text(path: Path, text: str, nl: str) -> None:
    # `nl` comes from `read_text` (or the snapshot CLI) and is the literal
    # 'CRLF' or 'LF' string returned by `detect_nl` — NOT '\r\n'/'\n'.
    if nl == 'CRLF':
        text = text.replace('\n', '\r\n')
    path.write_bytes(text.encode('utf-8'))


def _to(data: bytes, style: str) -> bytes:
    lf = data.replace(b'\r\n', b'\n')
    if style == 'CRLF':
        return lf.replace(b'\n', b'\r\n')
    if style == 'LF':
        return lf
    raise SystemExit(f'unknown style: {style!r}')


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == 'snapshot':
        styles = []
        for arg in argv[1:]:
            p = Path(arg)
            styles.append(detect_nl(p.read_bytes()) if p.exists() else 'LF')
        print(' '.join(styles))
        return 0
    if cmd == 'apply' and len(argv) >= 3:
        style = argv[1]
        for arg in argv[2:]:
            p = Path(arg)
            if p.exists():
                p.write_bytes(_to(p.read_bytes(), style))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
