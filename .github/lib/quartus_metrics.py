#!/usr/bin/env python3
# Parse Quartus fit/sta summary reports and compare a build against a stored
# baseline, so the CI build leg (quartus_build.sh) can detect a timing or ALM
# regression and decide whether to reseed.
#
# Why regression-relative and not absolute: MiSTer cores routinely ship benign
# negative setup slack on internal emulation-clock paths (e.g. AcornAtom carries
# Setup -2.189ns / -1.825ns on its emu PLL and runs fine). An absolute "any
# negative slack -> fail" gate (jtframe style) would fire on almost every core.
# So we compare per-clock worst slack against the last good build and flag only a
# *worsening* beyond a margin, or a domain newly crossing into negative.
#
# Downstream-only (Forks_MiSTer) — no MiSTer-DB9 markers (see markers rule).
# stdlib only; propagated to forks verbatim by setup_cicd.sh (.github copy).
#
# Subcommands:
#   parse  <output_files_dir> <rev>            -> emit metrics JSON to stdout
#   worst  <metrics.json>                      -> print worst setup slack (float)
#   compare <baseline.json> <new.json> [opts]  -> exit 0 ok / 3 timing / 4 alm
#
# compare exit codes: 0 = no regression, 3 = timing regression (reseed),
#                     4 = ALM-only regression (warn, no reseed), 2 = usage error.

import argparse
import json
import os
import re
import sys

# Slack-type stanzas in <rev>.sta.summary we track. Setup is the load-bearing
# one (the ao486 video bug was a setup miss); the rest are compared the same way
# so a new-negative on any of them is still caught.
SLACK_TYPES = ("Setup", "Hold", "Recovery", "Removal", "Minimum Pulse Width")

# "Logic utilization (in ALMs) : 11,922 / 41,910 ( 28 % )"
_ALM_RE = re.compile(r"Logic utilization \(in ALMs\)\s*:\s*([\d,]+)\s*/\s*([\d,]+)")
_REG_RE = re.compile(r"Total registers\s*:\s*([\d,]+)")
_DEV_RE = re.compile(r"^Device\s*:\s*(\S+)", re.M)
_QVER_RE = re.compile(r"Quartus Prime Version\s*:\s*(\S+)")


def _int(s):
    return int(s.replace(",", ""))


def parse_fit(path, m):
    with open(path, encoding="utf-8", errors="replace") as f:
        txt = f.read()
    am = _ALM_RE.search(txt)
    if am:
        m["alms_used"] = _int(am.group(1))
        m["alms_avail"] = _int(am.group(2))
    rm = _REG_RE.search(txt)
    if rm:
        m["registers"] = _int(rm.group(1))
    dm = _DEV_RE.search(txt)
    if dm:
        m["device"] = dm.group(1)
    qm = _QVER_RE.search(txt)
    if qm:
        m["quartus"] = qm.group(1)


def parse_sta(path, m):
    # Stanzas look like:
    #   Type  : Setup 'emu|pll|...divclk'
    #   Slack : -2.189
    #   TNS   : -414.863
    # Keep the worst (min) slack per (type, clock); a domain can appear once but
    # be defensive about duplicates.
    slack = {t: {} for t in SLACK_TYPES}
    cur_type = cur_clock = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("Type"):
                # "Type  : Setup 'clockname'"  /  "Type  : Minimum Pulse Width 'x'"
                body = line.split(":", 1)[1].strip() if ":" in line else ""
                cur_type = cur_clock = None
                q = body.find("'")
                if q == -1:
                    continue
                kind = body[:q].strip()
                clock = body[q + 1 : body.rfind("'")]
                if kind in slack:
                    cur_type, cur_clock = kind, clock
            elif line.startswith("Slack") and cur_type is not None:
                try:
                    val = float(line.split(":", 1)[1].strip())
                except (ValueError, IndexError):
                    continue
                d = slack[cur_type]
                if cur_clock not in d or val < d[cur_clock]:
                    d[cur_clock] = val
    # Drop empty type buckets to keep the JSON compact.
    m["slack"] = {t: v for t, v in slack.items() if v}
    setups = list(m["slack"].get("Setup", {}).values())
    m["worst_setup"] = min(setups) if setups else None


def cmd_parse(args):
    rev = args.rev
    d = args.output_dir
    m = {"rev": rev}
    seed = os.environ.get("DB9_SEED", "")
    m["seed"] = int(seed) if seed.isdigit() else None
    fit = os.path.join(d, rev + ".fit.summary")
    sta = os.path.join(d, rev + ".sta.summary")
    if os.path.isfile(fit):
        parse_fit(fit, m)
    if os.path.isfile(sta):
        parse_sta(sta, m)
    # Derived ALM utilization (level, not delta). High utilization marks a core
    # as fitter-seed-sensitive; the build leg warns on it (advisory only).
    au, aa = m.get("alms_used"), m.get("alms_avail")
    m["alm_util_pct"] = (
        round(au / aa * 100.0, 1)
        if isinstance(au, int) and isinstance(aa, int) and aa
        else None
    )
    # No reports at all (e.g. a non-Quartus leg) -> emit a marker the caller
    # treats as "nothing to gate on".
    m["has_timing"] = "slack" in m and bool(m["slack"])
    json.dump(m, sys.stdout, separators=(",", ":"), sort_keys=True)
    sys.stdout.write("\n")
    return 0


def cmd_worst(args):
    with open(args.metrics, encoding="utf-8") as f:
        m = json.load(f)
    ws = m.get("worst_setup")
    print("nan" if ws is None else repr(ws))
    return 0


def cmd_util(args):
    with open(args.metrics, encoding="utf-8") as f:
        m = json.load(f)
    pct = m.get("alm_util_pct")
    print("nan" if pct is None else repr(pct))
    return 0


def _load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def cmd_compare(args):
    base = _load(args.baseline)
    new = _load(args.new)
    margin = args.margin_ns
    risk_floor = args.risk_floor_ns

    timing_regressions = []
    base_slack = base.get("slack", {})
    new_slack = new.get("slack", {})
    for typ, base_clocks in base_slack.items():
        new_clocks = new_slack.get(typ, {})
        for clock, bval in base_clocks.items():
            if clock not in new_clocks:
                continue  # domain vanished (source reshaped) — can't compare
            nval = new_clocks[clock]
            # Magnitude-aware: only a domain whose NEW slack is near/below its
            # constraint (within risk_floor of zero) matters. Comfortably-positive
            # domains wiggle 1-4ns with the fitter seed and are pure noise — a
            # +327 -> +323ns "regression" is meaningless. Inside the risk zone we
            # still gate *relative* (worsened beyond margin, or newly crossed <0)
            # so benign steady-negative slack (e.g. AcornAtom -2.189ns) doesn't fire.
            at_risk = nval <= risk_floor
            worsened = nval < bval - margin
            new_negative = bval >= 0.0 and nval < 0.0
            if at_risk and (worsened or new_negative):
                timing_regressions.append(
                    (typ, clock, bval, nval, "new-negative" if new_negative else "worse")
                )

    # ALM regression: reseeding will not meaningfully change synthesis-determined
    # ALM count, so this is reported but never triggers a retry.
    alm_regression = None
    bu, nu = base.get("alms_used"), new.get("alms_used")
    if isinstance(bu, int) and isinstance(nu, int):
        alm_margin = max(args.alm_margin_abs, int(bu * args.alm_margin_pct / 100.0))
        if nu > bu + alm_margin:
            alm_regression = (bu, nu, nu - bu, alm_margin)

    if timing_regressions:
        sys.stderr.write(
            "TIMING REGRESSION vs baseline (margin %.3fns, risk-floor %.3fns):\n"
            % (margin, risk_floor)
        )
        for typ, clock, bval, nval, why in sorted(timing_regressions, key=lambda r: r[3] - r[2]):
            sys.stderr.write(
                "  [%s] %s: %.3f -> %.3f (delta %+.3fns, %s)\n"
                % (typ, clock, bval, nval, nval - bval, why)
            )
        if alm_regression:
            bu, nu, d, _ = alm_regression
            sys.stderr.write("  ALMs also grew: %d -> %d (+%d)\n" % (bu, nu, d))
        return 3

    if alm_regression:
        bu, nu, d, am = alm_regression
        sys.stderr.write(
            "ALM REGRESSION (warn-only): %d -> %d (+%d, margin %d)\n" % (bu, nu, d, am)
        )
        return 4

    sys.stderr.write("No timing/ALM regression vs baseline.\n")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("parse", help="parse output_files into metrics JSON")
    p.add_argument("output_dir")
    p.add_argument("rev")
    p.set_defaults(func=cmd_parse)

    p = sub.add_parser("worst", help="print worst setup slack from a metrics JSON")
    p.add_argument("metrics")
    p.set_defaults(func=cmd_worst)

    p = sub.add_parser("util", help="print ALM utilization percent from a metrics JSON")
    p.add_argument("metrics")
    p.set_defaults(func=cmd_util)

    p = sub.add_parser("compare", help="compare new metrics against a baseline")
    p.add_argument("baseline")
    p.add_argument("new")
    p.add_argument("--margin-ns", type=float, default=0.5)
    p.add_argument(
        "--risk-floor-ns", type=float, default=1.0,
        help="only flag a domain whose NEW slack is <= this (ns); comfortably-"
             "positive domains are ignored as fitter seed-noise",
    )
    p.add_argument("--alm-margin-pct", type=float, default=1.0)
    p.add_argument("--alm-margin-abs", type=int, default=16)
    p.set_defaults(func=cmd_compare)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
