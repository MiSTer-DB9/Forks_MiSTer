#!/usr/bin/env python3
# Forks.ini static linter.
#
# Forks.ini drives every CI/CD path (sync polling, per-fork dispatch,
# distribution). It had ZERO validation; two real outages came from it:
#   * 4d2f0af — 30+ FORK_REPO URLs misspelt the repo casing (`_Mister` /
#     `_MISTer`) so the desynced fork name broke `git clone` silently.
#   * 1b98487 — the *_FORKS lists / section order drifted out of
#     sort_forks_ini.py's canonical order, producing merge conflicts and
#     nondeterministic setup_cicd / sync polling.
#
# All checks here are static, offline (no git ls-remote — deterministic, no
# network in CI sandbox) and verified zero-false-positive against the live
# Forks.ini (160 sections):
#
#   1. No duplicate [section] (configparser raises -> reported cleanly).
#   2. [Forks] exists; every *_FORKS list value is ALREADY whitespace-sorted
#      and the non-Forks section order is ALREADY sorted -> sort_forks_ini.py
#      would be a no-op (the 1b98487 guard; the fork docs "always re-sort").
#   3. Referential integrity: every token in every *_FORKS list resolves to a
#      defined [section].
#   4. Per fork section schema: FORK_REPO present and on the invariant
#      `https://github.com/MiSTer-DB9/<repo>.git` org (all 160 confirmed —
#      a fork ALWAYS lives there, so an org typo is unambiguous); UPSTREAM_REPO
#      and MAIN_BRANCH present.
#   5. The 4d2f0af guard, allowlist-free: basename(FORK_REPO) ==
#      basename(UPSTREAM_REPO). The fork repo mirrors its upstream's exact
#      name/casing; this holds for ALL 160 incl. the 3 divergent-upstream-org
#      sections (Gyruss/PrehistoricIsle/jtcores — different org, SAME
#      basename). A casing typo in either URL desyncs the basenames and trips
#      here with no normalization assumption (some upstream repos really are
#      spelt `_MISTer`/`_Mister` — we must NOT force `MiSTer`).
#   6. Distribution slug-collision, mirroring the Distribution_MiSTer hooks
#      VERBATIM (the only zero-FP construction). `slugify(RELEASE_CORE_NAME)
#      = re.sub(r'[^a-z0-9]', '', rcn.lower())` is the tag id the unstable /
#      stable hooks reserve; two distinct sections hashing to the same slug
#      make the hooks `::error::` + `exit(1)` 10+ min into a distribution
#      build (inject_unstable_tags.py:87 / inject_stable_clean_slugs.py:151).
#      Scoped per channel exactly as the hooks do: among UNSTABLE_FORKS
#      sections (all, no skip); among SYNCING_FORKS sections that do NOT set
#      DISTRIBUTION_FILTERS (Hook-3-owned sections are `continue`d before the
#      stable hook's collision guard, so flagging them would be a FP). A
#      section with no RELEASE_CORE_NAME is skipped (the hooks warn+continue,
#      not error). Live Forks.ini is clean (160 unique) -> pure regression
#      guard catching the collision at lint instead of mid-build.
#
# Usage:  forks_ini_check.py [<path/to/Forks.ini>]   (default ./Forks.ini)
# Exit:   0 = clean, 1 = violation(s), 2 = file/parse error.

import configparser
import os
import re
import sys

ORG_PREFIX = "https://github.com/MiSTer-DB9/"
REQUIRED_KEYS = ("FORK_REPO", "UPSTREAM_REPO", "MAIN_BRANCH")


def _basename(url):
    return os.path.basename(url.rstrip("/")).removesuffix(".git")


def _slugify(rcn):
    # Distribution_MiSTer hooks, verbatim (inject_unstable_tags.py:51 /
    # inject_stable_clean_slugs.py:80).
    return re.sub(r"[^a-z0-9]", "", rcn.lower())


def _slug_collisions(c, list_key, skip_filtered):
    """Mirror one Distribution hook's per-channel slug-collision guard.
    `fork_name` (the *_FORKS token = section name) is the identity, exactly
    like the hooks' `seen_slugs[slug] != fork_name`."""
    errs = []
    if not c.has_option("Forks", list_key):
        return errs
    seen = {}                                  # slug -> section name
    for sec in c.get("Forks", list_key).split():
        if not c.has_section(sec):
            continue                           # ref-integrity (#3) reports it
        rcn = c[sec].get("RELEASE_CORE_NAME", "").strip()
        if not rcn:
            continue                           # hooks warn+continue, not error
        if skip_filtered and c[sec].get("DISTRIBUTION_FILTERS", "").strip():
            continue                           # Hook-3-owned: hook `continue`s
        slug = _slugify(rcn)
        if slug in seen and seen[slug] != sec:
            errs.append(
                f"[Forks] {list_key}: slug collision `{slug}` between "
                f"[{seen[slug]}] and [{sec}] (RELEASE_CORE_NAME `{rcn}`) — "
                f"the Distribution hook would ::error:: + exit 1 mid-build")
        else:
            seen[slug] = sec
    return errs


def check(path):
    errs = []
    if not os.path.isfile(path):
        print(f"forks-ini: FAIL file not found: {path}", file=sys.stderr)
        return 2
    c = configparser.ConfigParser()
    c.optionxform = str
    try:
        c.read(path)
    except configparser.DuplicateSectionError as e:
        print(f"forks-ini: FAIL duplicate section: {e}", file=sys.stderr)
        return 2
    except configparser.Error as e:
        print(f"forks-ini: FAIL parse error: {e}", file=sys.stderr)
        return 2

    if not c.has_section("Forks"):
        print("forks-ini: FAIL no [Forks] section", file=sys.stderr)
        return 1

    secs = [s for s in c.sections() if s != "Forks"]

    # 2. sort idempotence (mirror sort_forks_ini.py exactly)
    for k in c.options("Forks"):
        if not k.endswith("_FORKS"):
            continue
        toks = c.get("Forks", k).split()
        if toks != sorted(toks):
            errs.append(f"[Forks] {k} is not whitespace-sorted "
                        f"(run sort_forks_ini.py)")
    if secs != sorted(secs):
        errs.append("section order is not sorted "
                    "([Forks] + alphabetical; run sort_forks_ini.py)")

    # 3. referential integrity
    defined = set(secs)
    for k in c.options("Forks"):
        if not k.endswith("_FORKS"):
            continue
        for t in c.get("Forks", k).split():
            if t not in defined:
                errs.append(f"[Forks] {k} references undefined section "
                            f"`{t}`")

    # 4 + 5. per-section schema + FORK/UPSTREAM basename parity
    for s in secs:
        for key in REQUIRED_KEYS:
            if not c[s].get(key):
                errs.append(f"[{s}] missing required key {key}")
        fr = c[s].get("FORK_REPO", "")
        ur = c[s].get("UPSTREAM_REPO", "")
        if fr and not fr.startswith(ORG_PREFIX):
            errs.append(f"[{s}] FORK_REPO not on {ORG_PREFIX}* : {fr}")
        if fr and ur and _basename(fr) != _basename(ur):
            errs.append(
                f"[{s}] FORK_REPO/UPSTREAM_REPO basename mismatch "
                f"`{_basename(fr)}` != `{_basename(ur)}` "
                f"(casing/typo desync — the 4d2f0af class)")

    # 6. Distribution slug-collision, per channel, mirroring the hooks.
    errs += _slug_collisions(c, "SYNCING_FORKS", skip_filtered=True)
    errs += _slug_collisions(c, "UNSTABLE_FORKS", skip_filtered=False)

    if errs:
        print(f"forks-ini: FAIL ({len(errs)} issue(s)):")
        for e in errs:
            print(f"  - {e}")
        return 1
    print(f"forks-ini: ok  {len(secs)} sections, lists sorted, "
          f"refs + FORK/UPSTREAM parity + distribution slugs clean")
    return 0


def main(argv):
    path = argv[1] if len(argv) > 1 else "Forks.ini"
    return check(path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
