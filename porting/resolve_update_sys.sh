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

# Step 2 — auto-resolve sys/sys.qip if it conflicts: take upstream, re-append fork regs.
if echo "${conflicts}" | grep -qx "sys/sys.qip"; then
    git -C "${WT}" checkout --theirs -- sys/sys.qip
    git -C "${WT}" add sys/sys.qip
    echo "  sys/sys.qip: took upstream (emu_ports.vh + audio_out.sv); fork regs re-added by framework"
fi

# Step 3 — re-assert framework (idempotent). Re-appends the 6 joydb/key-gate
# sys.qip lines, the hps_io flip, etc. Stages what it changes.
echo "== apply_db9_framework.sh =="
bash "${APPLY}" "${WT}" 2>&1 | sed 's/^/  /' | tail -8

# Verify all six fork registrations are back in sys.qip (guard against a core
# where the framework didn't re-add one — would be a silent missing-.qip bug).
missing=()
for f in joydb9md.v joydb15.v joydb9saturn.v joydb.sv siphash24.v db9_key_gate.sv; do
    grep -Fwq "${f}" "${WT}/sys/sys.qip" || missing+=("${f}")
done
if (( ${#missing[@]} )); then
    echo "WARN sys.qip missing registrations after framework: ${missing[*]} — inspect before building."
fi

# Step 4 — report remaining conflicts.
remaining=$(git -C "${WT}" diff --name-only --diff-filter=U)
if [[ -z "${remaining}" ]]; then
    echo "RESULT resolved-clean: no conflicts remain. Step-6.5 build, then push origin ${branch}."
    exit 0
fi
core_sv=$(echo "${remaining}" | grep -E '\.sv$' | grep -vE '^sys/' || true)
other=$(echo "${remaining}" | grep -vxF "${core_sv}" || true)
if [[ -n "${other}" ]]; then
    echo "RESULT needs-manual: UNEXPECTED conflicts beyond <core>.sv — review all: ${remaining//$'\n'/ }"
    exit 1
fi
echo "RESULT needs-core-sv-review: only ${core_sv} left."
echo "  -> reject the \`include \"sys/emu_ports.vh\"\`, keep the inline DB9-extended emu port list,"
echo "     and diff sys/emu_ports.vh vs the inline list (grep -E '^(input|output|inout)' both sides)"
echo "     to port every non-DB9 delta inline — esp. HPS_BUS-class width narrowings (Quartus 10978/10714)."
echo "  Then: Step-6.5 quartus compile, then git push origin ${branch} from the worktree."
exit 1
