#!/usr/bin/env bash
# Create / refresh git worktrees for unstable-branch work under the repo root's
# `unstable/` directory, so maintainers can resolve unstable-channel merge
# conflicts without disturbing the canonical clone's master checkout.
#
# Each worktree is a checkout of a canonical clone's `unstable/<MAIN_BRANCH>`
# branch, tracking `origin/unstable/<MAIN_BRANCH>`. It lives in the canonical
# clone's worktree set (its `.git` is a file pointing back at
# `<canonical>/.git/worktrees/<name>`), so it shares the clone's object store
# and remotes (origin + upstream) — no extra full clone.
#
# Naming (single-dash, per the worktree convention in the fork docs):
#   unstable/<Clone>            for the clone's `master` branch (or its sole branch)
#   unstable/<Clone>-<branch>   for each ADDITIONAL branch on a multi-branch clone
# e.g. unstable/GBA_MiSTer, unstable/GBA_MiSTer-GBA2P, unstable/GBA_MiSTer-accuracy,
#      unstable/X68000_MiSTer-USERIO2, unstable/NeoGeo_MiSTer-24MHz_cpu_only.
#
# Idempotent: existing worktrees are reported, not recreated. Skips fork-only
# sections (no UPSTREAM_REPO) and jotego-bundle sections (not built per-fork),
# and any clone whose `origin` has no unstable branch yet (nothing to check out).
#
# Usage:
#   porting/unstable_worktrees.sh                 # all UNSTABLE_FORKS variants
#   porting/unstable_worktrees.sh Gameboy GBA     # only clones matching these names
#   porting/unstable_worktrees.sh --list          # print plan, create nothing
#
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORKS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # Forks_MiSTer
ROOT="$(cd "${FORKS_DIR}/.." && pwd)"         # MiSTer-DB9 (canonical clones live here)
INI="${FORKS_DIR}/Forks.ini"

LIST_ONLY=0
declare -a FILTERS=()
for a in "$@"; do
    case "$a" in
        --list) LIST_ONLY=1 ;;
        *)      FILTERS+=("$a") ;;
    esac
done

mkdir -p "${ROOT}/unstable"

# Emit one TSV row per (clone, main_branch, worktree_dir) for every unstable
# variant, skipping fork-only / jotego sections. The suffix rule is applied here.
mapfile -t ROWS < <(python3 - "$INI" <<'PY'
import configparser, sys, os
from collections import defaultdict
c = configparser.ConfigParser(strict=False); c.read(sys.argv[1])
forks = []
if c.has_section('Forks'):
    for k, v in c.items('Forks'):
        if k.upper() == 'UNSTABLE_FORKS':
            forks = v.split()
byclone = defaultdict(set)
for s in forks:
    if not c.has_section(s):
        continue
    if not c.get(s, 'UPSTREAM_REPO', fallback=''):
        continue  # fork-only core: unstable disabled, no upstream merge
    if c.get(s, 'IS_JOTEGO_BUNDLE', fallback='').strip().lower() == 'true':
        continue  # jt bundle: not built/merged per-fork
    fork_repo = c.get(s, 'FORK_REPO', fallback='')
    clone = os.path.basename(fork_repo.rstrip('/'))
    if clone.endswith('.git'):
        clone = clone[:-4]
    if not clone:
        continue
    byclone[clone].add(c.get(s, 'MAIN_BRANCH', fallback='master'))
for clone, branches in sorted(byclone.items()):
    multi = len(branches) > 1
    for mb in sorted(branches):
        if not multi or mb == 'master':
            dirn = clone
        else:
            dirn = f"{clone}-{mb}"
        print(f"{clone}\t{mb}\t{dirn}")
PY
)

match_filter() {  # $1=clone — true if no filters or clone substring-matches one
    [[ ${#FILTERS[@]} -eq 0 ]] && return 0
    local f
    for f in "${FILTERS[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done
    return 1
}

added=0 existing=0 skipped=0
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r clone mb dirn <<<"${row}"
    match_filter "${clone}" || continue
    canon="${ROOT}/${clone}"
    wt="${ROOT}/unstable/${dirn}"
    ubr="unstable/${mb}"

    if [[ ! -d "${canon}/.git" ]]; then
        echo "SKIP  ${dirn}: canonical clone ${clone} not found at ${canon}"
        skipped=$((skipped+1)); continue
    fi
    if ! git -C "${canon}" ls-remote --exit-code --heads origin "${ubr}" >/dev/null 2>&1; then
        echo "SKIP  ${dirn}: origin has no ${ubr} yet (no unstable build has run)"
        skipped=$((skipped+1)); continue
    fi
    if [[ -e "${wt}/.git" ]]; then
        echo "OK    ${dirn}: present on $(git -C "${wt}" branch --show-current 2>/dev/null || echo '?')"
        existing=$((existing+1)); continue
    fi
    if (( LIST_ONLY )); then
        echo "PLAN  ${dirn}: would add worktree on ${ubr} (clone ${clone})"
        continue
    fi
    git -C "${canon}" fetch --no-tags origin "refs/heads/${ubr}:refs/remotes/origin/${ubr}" >/dev/null 2>&1 || true
    if git -C "${canon}" worktree add -B "${ubr}" "${wt}" "origin/${ubr}" >/dev/null 2>&1; then
        echo "ADD   ${dirn}: ${ubr}"
        added=$((added+1))
    else
        echo "FAIL  ${dirn}: worktree add failed (branch maybe checked out elsewhere)"
        skipped=$((skipped+1))
    fi
done

echo "---"
echo "added=${added} existing=${existing} skipped=${skipped}$([[ ${LIST_ONLY} -eq 1 ]] && echo ' (list-only)')"
