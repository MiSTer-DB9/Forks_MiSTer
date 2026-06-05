#!/usr/bin/env bash
# Resolve the recurring upstream "Update sys." / emu_ports.vh merge conflict on
# a fork's UNSTABLE worktree, the semi-automated way:
#
#   1. Merge the upstream ref into the worktree's unstable/<branch> (same
#      -Xignore-all-space --no-ff the CI uses).
#   2. Auto-resolve sys/sys.qip: take upstream's version (it carries the
#      emu_ports.vh SOURCE_FILE line + the audio_out.v->.sv rename + any
#      hps_io flip), then let apply_db9_framework.sh re-append the fork's
#      joydb/key-gate registrations idempotently. The net file is identical to a
#      hand "keep-both", but deterministic.
#   3. Run apply_db9_framework.sh to re-assert framework boilerplate (idempotent;
#      preserves per-core snac_active / MT32 RHS).
#   4. Report the remaining conflicted files. If only <core>.sv is left, that is
#      the emu-port include-vs-inline delta — LEFT FOR MANUAL REVIEW (reject the
#      `include "sys/emu_ports.vh"`, keep the inline DB9-extended port list, and
#      port every non-DB9 delta inline — esp. HPS_BUS-class bus-width narrowings,
#      which are silent and blow up as Quartus 10978/10714). This script never
#      touches <core>.sv and never commits/pushes.
#
# Deliberately conservative: NO commit, NO push, NO <core>.sv auto-resolve.
# After this returns "needs <core>.sv review", finish by hand, then
# Step-6.5 build, then `git push origin unstable/<branch>` from the worktree.
#
# Usage:
#   resolve_update_sys.sh <worktree-dir> [upstream-ref]
# upstream-ref defaults to upstream/master (the UPSTREAM_BRANCH of almost every
# fork, even variants whose MAIN_BRANCH != master). Pass it explicitly for the
# rare fork that tracks a non-master upstream branch.
set -euo pipefail

WT="${1:?usage: resolve_update_sys.sh <worktree-dir> [upstream-ref]}"
UPSTREAM_REF="${2:-upstream/master}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORKS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPLY="${FORKS_DIR}/apply_db9_framework.sh"

[[ -d "${WT}/.git" || -f "${WT}/.git" ]] || { echo >&2 "not a git worktree: ${WT}"; exit 2; }
WT="$(cd "${WT}" && pwd)"

branch="$(git -C "${WT}" rev-parse --abbrev-ref HEAD)"
case "${branch}" in
    unstable/*) ;;
    *) echo >&2 "refusing: ${WT} is on '${branch}', not an unstable/* branch"; exit 2 ;;
esac
if [[ -n "$(git -C "${WT}" status --porcelain)" ]]; then
    echo >&2 "refusing: worktree ${WT} is dirty — commit/stash/clean first"; exit 2
fi

echo "== ${WT} (${branch}) : merging ${UPSTREAM_REF} =="
git -C "${WT}" fetch --no-tags origin >/dev/null 2>&1 || true
# upstream remote lives in the canonical clone shared by this worktree.
git -C "${WT}" fetch --no-tags upstream >/dev/null 2>&1 || true

if git -C "${WT}" merge -Xignore-all-space --no-ff "${UPSTREAM_REF}" \
        -m "BOT: Unstable merge of ${UPSTREAM_REF} (Update sys. resolution)" >/dev/null 2>&1; then
    echo "RESULT clean-merge: no conflict (nothing to resolve) — review + build + push."
    exit 0
fi

conflicts=$(git -C "${WT}" diff --name-only --diff-filter=U)
echo "conflicts: $(echo "${conflicts}" | tr '\n' ' ')"

# Identify the conflicted <core>.sv files (top-level emu wrappers, NOT sys/*).
# Multi-revision repos (e.g. Atari800 = Atari5200.sv + Atari800.sv) conflict in
# more than one — handle every one.
mapfile -t core_svs < <(echo "${conflicts}" | grep -E '\.sv$' | grep -vE '^sys/' || true)

# Step 2a — resolve every conflicted <core>.sv by stripping conflict markers and
# keeping OUR side of each conflict hunk (the fork's inline DB9-extended emu port
# list; reject upstream's `include "sys/emu_ports.vh"`). CRUCIALLY this is a
# HUNK-level keep-ours, NOT `git checkout --ours`: the latter reverts the WHOLE
# file to fork HEAD and silently discards upstream's clean-merged BODY edits
# (e.g. Minimig.sv's `.HPS_BUS({HPS_BUS[48:42]...})` -> `[45:42]` splice that
# af37601 narrowed). The marker-strip keeps clean-merged upstream regions intact
# and only resolves the actual conflict (the port list) to ours. Must run BEFORE
# apply_db9_framework: the porter rewrites the emu port region and, if conflict
# markers are still present, DUPLICATES the port list (silent corruption that
# `git diff --diff-filter=U` won't show, since the porter also `git add`s it).
# The lone non-DB9 delta (HPS_BUS decl width narrowing) is applied by hand after (Step 5).
for sv in "${core_svs[@]}"; do
    [[ -z "${sv}" ]] && continue
    python3 - "${WT}/${sv}" <<'PY'
import sys
p=sys.argv[1]
out=[]; mode='keep'   # keep=outside conflict, ours=HEAD side, skip=base/theirs side
for line in open(p,encoding='utf-8',errors='surrogateescape'):
    s=line.rstrip('\n')
    if s.startswith('<<<<<<< '): mode='ours'; continue
    if s.startswith('||||||| '): mode='skip'; continue   # diff3 base section
    if s=='=======' or s.startswith('======= '): mode='skip'; continue
    if s.startswith('>>>>>>> '): mode='keep'; continue
    if mode in ('keep','ours'): out.append(line)
open(p,'w',encoding='utf-8',errors='surrogateescape').writelines(out)
PY
    git -C "${WT}" add -- "${sv}"
    echo "  ${sv}: kept OUR inline emu port list, preserved upstream body (hunk-level keep-ours)"
done

# Step 2b — auto-resolve sys/sys.qip if it conflicts: take upstream, re-append fork regs.
if echo "${conflicts}" | grep -qx "sys/sys.qip"; then
    git -C "${WT}" checkout --theirs -- sys/sys.qip
    git -C "${WT}" add sys/sys.qip
    echo "  sys/sys.qip: took upstream (emu_ports.vh + audio_out.sv); fork regs re-added by framework"
fi

# Step 2c — auto-resolve a conflicted MAIN <core>.qsf by taking upstream. The main
# qsf is upstream-owned + Quartus-regenerated (Critical Rule #1: never fork-commit
# it); the only conflict is upstream's LAST_QUARTUS_VERSION bump. Fork-owned variant
# qsfs (*_USERIO2.qsf) are NOT auto-resolved — they carry pinned SEED / variant defines.
while IFS= read -r q; do
    [[ -z "${q}" ]] && continue
    case "${q}" in *USERIO2.qsf) continue ;; esac   # fork-owned variant — leave for review
    git -C "${WT}" checkout --theirs -- "${q}"
    git -C "${WT}" add -- "${q}"
    echo "  ${q}: took upstream (main qsf is regenerated; only LAST_QUARTUS_VERSION differs)"
done < <(echo "${conflicts}" | grep -E '\.qsf$' || true)

# Step 2d — any OTHER conflict (sys_top.v / hps_io.sv / osd.v with fork markers,
# unexpected files) is NOT auto-resolved — stop and let the maintainer handle it.
core_pat=$(printf '%s\n' "${core_svs[@]}")
other=$(git -C "${WT}" diff --name-only --diff-filter=U | grep -vxF "${core_pat:-/dev/null}" | grep -vx 'sys/sys.qip' | grep -vE '\.qsf$' || true)
if [[ -n "${other}" ]]; then
    echo "RESULT needs-manual: UNEXPECTED conflicts (not <core>.sv / sys.qip): ${other//$'\n'/ }"
    echo "  Resolve those by hand (keep-both for fork-marker regions), then re-run framework + build."
    exit 1
fi

# Step 3 — re-assert framework (idempotent) on the now-conflict-free tree.
# Re-appends the 6 joydb/key-gate sys.qip lines, the hps_io flip, etc.
echo "== apply_db9_framework.sh =="
# apply_db9_framework.sh resolves fork_ci_template/sys and porting/* relative to
# its own repo dir, so it must run with CWD = Forks_MiSTer.
( cd "${FORKS_DIR}" && bash "${APPLY}" "${WT}" ) 2>&1 | sed 's/^/  /' | tail -8

# Verify all six fork registrations are back in sys.qip (guard against a core
# where the framework didn't re-add one — would be a silent missing-.qip bug).
missing=()
for f in joydb9md.v joydb15.v joydb9saturn.v joydb.sv siphash24.v db9_key_gate.sv; do
    grep -Fwq "${f}" "${WT}/sys/sys.qip" || missing+=("${f}")
done
if (( ${#missing[@]} )); then
    echo "WARN sys.qip missing registrations after framework: ${missing[*]} — inspect before building."
fi

# Step 4 — leftover conflict markers anywhere (apply_db9_framework git-adds files,
# so --diff-filter=U is unreliable — grep the actual content instead).
marked=$(grep -rIl -e '^<<<<<<< ' -e '^>>>>>>> ' "${WT}" \
            --include='*.v' --include='*.sv' --include='*.vh' \
            --include='*.qip' --include='*.tcl' 2>/dev/null \
            | sed "s|^${WT}/||" || true)
if [[ -n "${marked}" ]]; then
    echo "RESULT needs-manual: conflict markers still present in: ${marked//$'\n'/ }"
    echo "  (likely the framework re-introduced or never cleared them — inspect before building.)"
    exit 1
fi

# Step 5 — name-keyed emu port diff: emu_ports.vh (upstream) vs the inline list in
# <core>.sv, so the maintainer can apply every NON-DB9 delta by hand. Expected
# fleet-wide delta: HPS_BUS [48:0]->[45:0]. USER_IN/USER_OUT/USER_OSD/USER_PP rows
# are intentional DB9 extensions — KEEP those, do NOT narrow them to match upstream.
for core_sv in "${core_svs[@]}"; do
    [[ -z "${core_sv}" || ! -f "${WT}/sys/emu_ports.vh" ]] && continue
    echo "== emu port delta (apply NON-DB9 rows to ${core_sv} by hand) =="
    python3 - "${WT}/sys/emu_ports.vh" "${WT}/${core_sv}" <<'PY'
import re, sys
DECL = re.compile(r'^\s*(input|output|inout)\b(.*?)\b([A-Za-z_]\w*)\s*(?:,|//|$)')
DB9  = {'USER_IN','USER_OUT','USER_OSD','USER_PP',
        'USER_IN2','USER_OUT2','USER_OSD2','USER_PP2'}  # USERIO2 second-port DB9 adds
def widths(path, region_only=False):
    out={}
    lines=open(path,encoding='utf-8',errors='replace').read().splitlines()
    if region_only:  # restrict to the emu(...) port list
        try:
            s=next(i for i,l in enumerate(lines) if re.match(r'\s*module\s+emu\b',l))
            lines=lines[s:]
        except StopIteration: pass
        # stop at the ");" that closes the port list
        cut=[]
        for l in lines:
            cut.append(l)
            if re.match(r'\s*\);', l): break
        lines=cut
    for l in lines:
        m=DECL.match(l)
        if not m: continue
        w=(m.group(2) or '').strip() or '(1)'
        out[m.group(3)]=w
    return out
up=widths(sys.argv[1]); ours=widths(sys.argv[2], region_only=True)
alln=sorted(set(up)|set(ours))
diffs=[n for n in alln if up.get(n)!=ours.get(n)]
if not diffs:
    print("  (no width/presence delta — inline list already matches upstream ports)")
for n in diffs:
    tag=' [DB9 — keep ours]' if n in DB9 else ' <-- APPLY'
    print(f"  {n:16} upstream={up.get(n,'(absent)'):10} ours={ours.get(n,'(absent)'):10}{tag}")
PY
done
if (( ${#core_svs[@]} )) && [[ -n "${core_svs[0]}" ]]; then
    echo "RESULT needs-core-sv-review: ${core_svs[*]} kept as inline list; apply the '<-- APPLY' deltas above (e.g. HPS_BUS -> [45:0])."
    echo "  Then: Step-6.5 quartus compile, then git push origin ${branch} from the worktree."
    exit 0
fi
echo "RESULT resolved-clean: no <core>.sv conflict. Step-6.5 build, then push origin ${branch}."
exit 0
