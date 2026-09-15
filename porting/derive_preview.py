#!/usr/bin/env python3
"""Reference model of Main_MiSTer/db9_map.cpp's factory-default derive.

db9_map_factory_default() turns a core's CONF_STR J1 labels (or an arcade MRA's
<buttons names="...">) into the 9-slot DB9 remap table that Main_MiSTer streams
over UIO 0xFD. Every change to that derive shifts the out-of-the-box button
layout of the whole fleet at once, and the only way to see the blast radius is
to run the derive over every core and diff. This is that tool.

  ./derive_preview.py --self-test        # asserts the pinned reference maps
  ./derive_preview.py --core SMS         # one core's map, both rules
  ./derive_preview.py --fleet            # every core whose map the rule changed

"--rule old" is the pre-face-budget derive (gameplay always packed from raw4,
secondary always from raw7), kept so the delta stays inspectable after the C
side has moved on.  Keep this file in step with db9_map.cpp by hand: it is a
model, not a binding, and a silent drift makes the gate worthless.
"""

import argparse
import glob
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

NONE = 15
COMBO_STARTB = 14
BTN_LAST = 12

# db9_map.cpp: phys_db9md / phys_db15 / phys_saturn
PHYS = {
    "DB9MD":  {"a": 4, "b": 5, "c": 6, "x": 7, "y": 8, "z": 9, "start": 10, "mode": 11},
    "DB15":   {"a": 4, "b": 5, "c": 6, "d": 7, "e": 8, "f": 9, "start": 10, "select": 11},
    "SATURN": {"a": 4, "b": 5, "c": 6, "x": 7, "y": 8, "z": 9, "start": 10, "r": 11, "l": 12},
}

def raw_names(devtype):
    return {**{v: k.upper() for k, v in PHYS[devtype].items()},
            COMBO_STARTB: "Start+B", NONE: "-"}


SECONDARY = {
    "pause", "test", "service", "service select", "service mode", "reset",
    "soft reset", "cheat", "advance", "auto up", "high score reset", "slam",
    "next track", "dip", "tilt",
}

GAMEPLAY, NOMAP, SHOULDER, START, COIN, SEL, SECOND, SPILL = range(8)


def clean_label(label):
    """joymapping.cpp db9_clean_label: cut at '|' and '(', then trim."""
    return label.split("|")[0].split("(")[0].strip()


def category(n, rule="new"):
    """db9_map.cpp db9_category(). rule="old" drops the two classifications this
    change added, so a --rule old run reproduces the shipped binary exactly."""
    low = n.lower()
    if low in ("savestate", "save state"):
        return NOMAP
    if low in ("l", "lt", "r", "rt"):
        return SHOULDER
    if (low.startswith("start") and "2" not in n) or low in ("run", "vstart"):
        return START
    if low.startswith("coin") and "2" not in n and not low.endswith("b"):
        return COIN
    if low in ("select", "mode", "game select"):
        return SEL
    if low in SECONDARY:
        return SECOND
    if rule == "new" and low.startswith("arcade "):
        return SECOND
    if "start" in low and "2" in n:
        return SPILL                       # Start 2P: a second-player duplicate
    if rule == "new" and low.startswith("1p") and "start" in low:
        return START                       # "1P Start" -- the ci_starts() test above
                                           # only catches the "Start 1P" word order.
                                           # Anchored on the leading "1P" so a compound
                                           # label ending in "Start1" keeps its face.
    if rule == "new" and low == "p1":
        return START                       # Arcade-BankPanic's 1P start button
    if low.startswith("coin") and ("2" in n or low.endswith("b")):
        return SPILL                       # Coin 2 / Coin B
    return GAMEPLAY


def fire_num(n):
    low = n.lower()
    if not low.startswith("fire") and not low.startswith("button"):
        return 0
    if low == "fire" or "1" in n:
        return 1
    for d in ("2", "3", "4"):
        if d in n:
            return int(d)
    return 0


def classify(n):
    """db9_map.cpp db9_classify() -- only the shoulder arm is consulted here."""
    low, f = n.lower(), fire_num(n)
    if low in ("a", "jump") or f == 1:
        return "A"
    if low == "b" or f == 2:
        return "B"
    if low in ("x", "c") or f == 3:
        return "X"
    if low in ("y", "d") or f == 4:
        return "Y"
    if low in ("r", "rt"):
        return "R"
    if low in ("l", "lt"):
        return "L"
    if low in ("select", "mode", "game select", "start 2p"):
        return "SEL"
    if low in ("start", "run", "pause", "start 1p"):
        return "START"
    return None


def class_raw(devtype, cls, has_r):
    """db9_map.cpp db9_class_raw() -- DB9MD has no shoulders."""
    if devtype == "DB9MD":
        return {"A": 4, "B": 5, "X": 7, "Y": 8, "SEL": 11, "START": 10}.get(cls, NONE)
    if devtype == "DB15":
        return {"A": 4, "B": 5, "X": 6, "Y": 7, "L": 8, "R": 9,
                "SEL": 11, "START": 10}.get(cls, NONE)
    if devtype == "SATURN":
        if cls == "SEL":
            return COMBO_STARTB if has_r else 11
        return {"A": 4, "B": 5, "X": 7, "Y": 8, "L": 12, "R": 11,
                "START": 10}.get(cls, NONE)
    return NONE


def next_free_face(used, first):
    for r in range(first, 10):
        if not used & (1 << r):
            return r
    return -1


def slots(labels):
    """db9_slot_name(): (position, cleaned name) for each non-'-' label in range."""
    out = []
    for pos, raw in enumerate(labels):
        if raw.strip() == "-":
            continue                       # placeholder: holds a position, has no name
        if pos + 4 > BTN_LAST:
            break
        out.append((pos, clean_label(raw)))
    return out


def derive(labels, devtype="DB9MD", rule="new"):
    """db9_map_factory_default(). Returns map[0..12]; None if it would fall back
    to the legacy hardcoded table (no J1, or a J1 with no real button)."""
    real = slots(labels)
    if not real:
        return None

    m = [0, 1, 2, 3] + [NONE] * 9
    exact = PHYS[devtype]
    has_r = any(n.lower() in ("r", "rt") for _, n in real)

    used = 0
    if rule == "new":
        # Face budget: a 2-button pad on DB9MD can never press raw4(A), so retire
        # it up front on a core needing at most two faces. Every pass below already
        # skips claimed bits. See db9_map.cpp for the joydb9md.v rationale.
        face_cnt = sum(1 for _, n in real
                       if 4 <= exact.get(n.lower(), -1) <= 9
                       or (exact.get(n.lower(), -1) < 0 and category(n, rule) == GAMEPLAY))
        if devtype == "DB9MD" and face_cnt <= 2:
            used |= 1 << 4

    for pos, n in real:                                        # Pass 1: exact names
        raw = exact.get(n.lower(), -1)
        if raw < 0 or used & (1 << raw):
            continue
        m[pos + 4] = raw
        used |= 1 << raw

    def each(place):
        for pos, n in real:
            if m[pos + 4] != NONE:
                continue
            place(pos + 4, n, category(n, rule))

    def claim_sel(slot):
        nonlocal used
        if devtype == "SATURN" and has_r:
            m[slot] = COMBO_STARTB
            return
        if not used & (1 << 11):
            m[slot] = 11
            used |= 1 << 11

    def p_start(slot, n, cat):
        nonlocal used
        if cat == START and not used & (1 << 10):
            m[slot] = 10
            used |= 1 << 10

    def p_shoulder(slot, n, cat):
        nonlocal used
        if cat == SHOULDER:
            raw = class_raw(devtype, classify(n), has_r)
            if raw != NONE and not used & (1 << raw):
                m[slot] = raw
                used |= 1 << raw

    def p_gameplay(slot, n, cat):
        nonlocal used
        if cat == GAMEPLAY:
            raw = next_free_face(used, 4)
            if raw >= 0:
                m[slot] = raw
                used |= 1 << raw

    def p_secondary(slot, n, cat):
        nonlocal used
        if cat in (SECOND, SPILL, SEL, COIN):
            if (rule == "new" and devtype == "DB9MD" and cat == SECOND
                    and not used & (1 << 10)):
                m[slot] = 10
                used |= 1 << 10
                return
            raw = next_free_face(used, 7)
            if raw >= 0:
                m[slot] = raw
                used |= 1 << raw

    each(p_start)
    each(lambda s, n, c: claim_sel(s) if c == COIN else None)
    each(lambda s, n, c: claim_sel(s) if c == SEL else None)
    each(p_shoulder)
    each(p_gameplay)
    each(p_secondary)
    return m


def hardcoded_default(devtype):
    """db9_map_hardcoded_default(): the fallback when derive() returns None."""
    m = [0, 1, 2, 3] + [NONE] * 9
    m[4:12] = [4, 5, 6, 7, 8, 9, 11, 10]           # A B C X/D Y/E Z/F Mode/Select Start
    if devtype == "SATURN":
        m[4:12] = [4, 5, 7, 8, 12, 11, NONE, 10]   # A B X Y L R - Start
    return m


def pack36(m):
    """db9_map_stream(): slot s (4..12) at bits [(s-4)*4 +: 4] -- the layout
    joydb_remap.sv's remap_default_* ports take."""
    return sum((m[s] & 0xF) << ((s - 4) * 4) for s in range(4, BTN_LAST + 1))


def show(labels, m, devtype="DB9MD"):
    real = dict(slots(labels))
    names = raw_names(devtype)
    return ", ".join("%s=%s" % (real[p], names.get(m[p + 4], "?"))
                     for p in sorted(real))


# --------------------------------------------------------------------------
# Fleet scan

J1_RE = re.compile(r'"(J1?,[^"]*)"')
MRA_RE = re.compile(r'<buttons[^>]*\bnames\s*=\s*"([^"]*)"', re.I)


def labels_from_j1(text):
    """CONF_STR J1 button labels, or None when the core declares no J1. Shared
    by the fleet scan and by port_core_full.py's per-core factory-default
    derive, so the two cannot drift apart."""
    hit = J1_RE.search(text)
    if not hit:
        return None
    body = hit.group(1).split(",", 1)
    return body[1].rstrip(";").split(",") if len(body) == 2 else None


_CORE_LABELS = None


def core_labels():
    """(source, labels) for every Layer-B core: its J1, plus each in-repo MRA's
    button names (arcade cores derive from ovr_buttons, not from J1). Cached --
    the self-test walks the fleet once per devtype."""
    global _CORE_LABELS
    if _CORE_LABELS is not None:
        return _CORE_LABELS
    out, scanned = [], set()
    for sv in sorted(glob.glob(os.path.join(REPO, "*_MiSTer*", "*.sv"))):
        try:
            text = open(sv, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "joydb_1_mapped[" not in text:
            continue
        core_dir = os.path.dirname(sv)
        core = os.path.basename(core_dir)
        labels = labels_from_j1(text)
        if labels:
            out.append((core, labels))
        if core_dir in scanned:
            continue          # 2nd Layer-B .sv in this dir: its MRAs are listed
        scanned.add(core_dir)
        for mra in sorted(glob.glob(os.path.join(core_dir, "**", "*.mra"),
                                    recursive=True)):
            names = MRA_RE.search(open(mra, encoding="utf-8", errors="replace").read())
            if names:
                out.append(("%s:%s" % (core, os.path.basename(mra)),
                            names.group(1).split(",")))
    _CORE_LABELS = out
    return out


def cmd_fleet(devtype):
    changed = unmapped = total = 0
    for name, labels in core_labels():
        total += 1
        old = derive(labels, devtype, "old")
        new = derive(labels, devtype, "new")
        if old is None or new is None:
            continue
        if any(new[s] == NONE and old[s] != NONE for s in range(4, BTN_LAST + 1)):
            unmapped += 1
            print("LOSS  %-44s %s" % (name, show(labels, new, devtype)))
        if old != new:
            changed += 1
            print("  %-44s\n      old: %s\n      new: %s"
                  % (name, show(labels, old, devtype), show(labels, new, devtype)))
    print("\n%d sources scanned, %d changed, %d lost a mapping" % (total, changed, unmapped))
    return 1 if unmapped else 0


# --------------------------------------------------------------------------
# Self-test: the maps this change is pinned to.

def cmd_self_test():
    def j1(s):
        return s.split(",")

    genesis = j1("A,B,C,Start,Mode,X,Y,Z")
    assert derive(genesis)[4:12] == [4, 5, 6, 10, 11, 7, 8, 9], derive(genesis)
    assert derive(genesis, rule="old") == derive(genesis), "native 6-button pad must not move"

    # SMS: the reported bug. Old fixed perm was Fire1<-B, Fire2<-C, Pause<-Start;
    # "Arcade 3" is a Systeme cabinet button and must not eat a primary face.
    sms = j1("Fire 1,Fire 2,Pause,Coin,Arcade 3,Soft Reset,-,-,SaveState")
    m = derive(sms)
    assert m[4] == 5 and m[5] == 6, "SMS Fire 1/2 must sit on B/C: %s" % show(sms, m)
    assert m[6] == 10, "SMS Pause must sit on Start: %s" % show(sms, m)

    # Cores naming buttons literally A/B are caught by the Pass-1 skip, not the
    # gameplay pass. NES's old fixed perm was A<-C, B<-B.
    nes = j1("A,B,Select,Start")
    m = derive(nes)
    assert m[4] == 6 and m[5] == 5, "NES A/B must sit on C/B: %s" % show(nes, m)
    assert m[6] == 11 and m[7] == 10

    one = j1("Fire,Start 1P,Start 2P,Coin,Pause")
    assert derive(one)[4] == 5, "a 1-button core's Fire must sit on B"

    # A 3-face core keeps A: it is unplayable on a 2-button pad either way.
    three = j1("Fire 1,Fire 2,Fire 3,Start,Coin")
    assert derive(three)[4:7] == [4, 5, 6], derive(three)

    # raw10 is never stolen from a core that declares a Start.
    for name, labels in core_labels():
        m = derive(labels)
        if m is None:
            continue
        for pos, n in slots(labels):
            if category(n) == START and m[pos + 4] != 10 and not any(
                    category(o) == START and m[p + 4] == 10 for p, o in slots(labels)):
                raise AssertionError("%s: Start lost raw10 (%s)" % (name, show(labels, m)))
        # No core may lose a button that the old rule placed.
        old = derive(labels, rule="old")
        for s in range(4, BTN_LAST + 1):
            if m[s] == NONE and old[s] != NONE:
                raise AssertionError("%s: slot %d unmapped by the new rule" % (name, s))

    # The face budget and the meta-Start preference are DB9MD-only (three
    # `devtype == DB9_DEV_DB9MD` guards in the C). The half of that worth asserting
    # is that no other devtype hands raw10 to a non-Start label. DB15/Saturn DO pick
    # up the devtype-independent db9_category fixes -- "1P Start" reaching the Start
    # button on DB15 is the point of one of them -- so this is not byte-identity.
    for devtype in ("DB15", "SATURN"):
        for name, labels in core_labels():
            m = derive(labels, devtype)
            if m is None:
                continue
            for pos, n_ in slots(labels):
                if m[pos + 4] == 10 and category(n_) != START:
                    raise AssertionError("%s: %s gave raw10 to %r" % (name, devtype, n_))

    # pack36 / hardcoded_default mirror db9_map_stream / db9_map_hardcoded_default.
    neo = j1("A,B,C,D,Start,Select,Coin,ABC,A+B,C+D")
    assert pack36(derive(neo, "DB15")) == 0x98FBA7654, hex(pack36(derive(neo, "DB15")))
    assert pack36(derive(neo, "DB9MD")) == 0x98BFA7654, hex(pack36(derive(neo, "DB9MD")))
    assert hardcoded_default("DB15")[4:12] == [4, 5, 6, 7, 8, 9, 11, 10]
    assert hardcoded_default("SATURN")[8:10] == [12, 11]

    print("self-test OK")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--fleet", action="store_true")
    ap.add_argument("--core", help="substring of a core dir / MRA name")
    ap.add_argument("--j1", help="derive a literal comma-separated J1 label list")
    ap.add_argument("--devtype", default="DB9MD", choices=sorted(PHYS))
    ap.add_argument("--rule", default="new", choices=("old", "new"))
    a = ap.parse_args()

    if a.self_test:
        return cmd_self_test()
    if a.fleet:
        return cmd_fleet(a.devtype)
    if a.j1:
        labels = a.j1.split(",")
        print(show(labels, derive(labels, a.devtype, a.rule), a.devtype))
        return 0
    if a.core:
        for name, labels in core_labels():
            if a.core.lower() in name.lower():
                for rule in ("old", "new"):
                    m = derive(labels, a.devtype, rule)
                    print("%-44s %s: %s" % (name, rule, show(labels, m, a.devtype) if m else "(legacy table)"))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
