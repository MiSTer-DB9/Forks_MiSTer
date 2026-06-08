#!/usr/bin/env bash
# Resolve a fork's blocked STABLE upstream merge on master by adopting the
# CI-green unstable combine, deterministically and drift-guarded.
#
# WHEN TO USE
#   A `sync_release.yml` ("Sync with upstream") run is red because the upstream
#   release commit conflicts in <core>.sv / sys/hps_io.sv / sys/sys.qip etc. and
#   rerere did NOT auto-replay the canary resolution (rerere replay is
#   merge-base-sensitive; the unstable branch already absorbed upstream, so an
#   aligned resolution can't always be regenerated there). The fork's
#   `unstable/<branch>` branch, however, already carries the correct
#   fork-DB9 + upstream combine and built green. This script lifts that combine
#   onto master for the SAME upstream release commit, then dispatches release.yml
#   exactly as sync_release.sh would.
#
# HOW (per core)
#   1. worktree at origin/<MAIN_BRANCH>; merge -Xignore-all-space --no-commit the
#      newest upstream commit that touched releases/ (the release commit, CTM).
#   2. For EVERY path where unstable differs from the release tree, adopt the
#      unstable version -- not only conflicted files. This is the key difference
#      from resolve_update_sys.sh / the conflicted-files-only approach: upstream
#      changes that the fork must counter NON-conflictingly are missed otherwise
#      (e.g. Amstrad: upstream added rtl/joydb.sv colliding with sys/joydb.sv;
#      unstable commented the files.qip registration, but files.qip merged clean
#      so a conflicted-only resolver left the duplicate -> Quartus 10228).
#   3. DRIFT GUARD: if upstream cut commits to a file AFTER the release commit
#      (rev-list CTM..UH), unstable carries forward-drift -> keep the merge/release
#      version (abort if that file is also conflicted). Keeps master release-aligned.
#   4. Gates: check_status_collision.sh + merge_validate.sh, duplicate-joydb guard.
#   5. PUSH=1 -> [skip ci] commit, normal push HEAD:<MAIN_BRANCH>, dispatch
#      release.yml with upstream_release_sha/upstream_head_at_sync provenance.
#
# NOT A SUBSTITUTE for a local Quartus build. A green run here is necessary but
# not sufficient (see WORKFLOW.md Step 6.5). Build-verify cores with structural
# quirks (stale unstable, layout changes, status-bit collisions) before PUSH=1.
#
# Does NOT handle:
#   * stale unstable branch (built before the upstream change) -> adopts pre-change
#     content; resolve such cores by hand (see Arcade-IremM72 in the merge log).
#   * status-bit collisions (upstream took the fork's joy_type bits) -> relocate
#     joy_type/joy_2p + add a RESERVED directive by hand (see C128).
#   * repo restructures (subdir->root) -> full re-port.
#
# USAGE
#   resolve_stable_merge.sh <canonical_clone_dir>          # dry-run: resolve + gate, leaves worktree
#   PUSH=1 resolve_stable_merge.sh <canonical_clone_dir>   # commit + push + dispatch
set -uo pipefail
CLONE="$(cd "${1:?usage: resolve_stable_merge.sh <canonical_clone_dir>}" && pwd)"
REPO="MiSTer-DB9/$(basename "$CLONE")"
WT="/tmp/rsm_$(basename "$CLONE")"; export GIT_MERGE_AUTOEDIT=no
say(){ echo "[$(basename "$CLONE")] $*"; }
cleanup(){ git -C "$CLONE" worktree remove --force "$WT" 2>/dev/null; git -C "$CLONE" worktree prune 2>/dev/null; }

git -C "$CLONE" fetch origin -q 2>/dev/null; git -C "$CLONE" fetch upstream -q 2>/dev/null
MB=$(git -C "$CLONE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null|sed 's#^origin/##'); MB="${MB:-master}"
UB=$(git -C "$CLONE" symbolic-ref --short refs/remotes/upstream/HEAD 2>/dev/null|sed 's#^upstream/##'); UB="${UB:-master}"
UNS="origin/unstable/$MB"
git -C "$CLONE" rev-parse --verify -q "$UNS" >/dev/null || { say "no $UNS — resolve by hand"; exit 1; }
CTM=$(git -C "$CLONE" log -n1 --pretty=%H "upstream/$UB" -- releases/ 2>/dev/null)
UH=$(git -C "$CLONE" rev-parse "upstream/$UB" 2>/dev/null)
[[ -z "$CTM" ]] && { say "no upstream release commit"; exit 2; }
[[ -z "$UH" ]] && { say "could not resolve upstream/$UB HEAD"; exit 2; }   # drift guard depends on UH
git -C "$CLONE" merge-base --is-ancestor "$CTM" "origin/$MB" 2>/dev/null && { say "already in $MB"; exit 2; }

cleanup; rm -rf "$WT"
git -C "$CLONE" worktree add -q --detach "$WT" "origin/$MB" || { say "worktree fail"; exit 1; }
cd "$WT"
# Snapshot the PRE-merge failing checks so merge_validate's `check` later flags
# only NEWLY introduced failures (regression-only). Must run before the merge.
bash .github/merge_validate.sh baseline . >/dev/null 2>&1 || true
git merge -Xignore-all-space --no-commit "$CTM" >/dev/null 2>&1
# A divergent --no-commit merge always leaves MERGE_HEAD (clean or conflicted).
# Its absence means the merge failed (unreachable CTM, untracked-file overwrite)
# or fast-forwarded (no fork divergence) — neither is resolvable here.
git rev-parse -q --verify MERGE_HEAD >/dev/null || { say "ABORT: no merge in progress (merge failed or fast-forwarded)"; cleanup; exit 1; }

mapfile -t DIFFS < <(git diff --name-only "$CTM" "$UNS")
adopted=0; skipped_drift=0; removed=0
for f in "${DIFFS[@]}"; do
    [[ -z "$f" ]] && continue
    # Fail SAFE: a rev-list error counts as drift (keep release version, don't adopt).
    drift=$(git rev-list --count "${CTM}..${UH}" -- "$f" 2>/dev/null) || drift=1
    if [[ "$drift" != "0" ]]; then
        if git ls-files --unmerged -- "$f" | grep -q .; then
            say "  ABORT: $f drifted $drift AND conflicted — resolve by hand"; git merge --abort; cleanup; exit 1
        fi
        skipped_drift=$((skipped_drift+1)); continue
    fi
    if git cat-file -e "$UNS:$f" 2>/dev/null; then
        git checkout "$UNS" -- "$f" && git add "$f" \
            && adopted=$((adopted+1)) \
            || { say "  ABORT: failed to adopt $f from $UNS"; git merge --abort 2>/dev/null; cleanup; exit 1; }
    fi
done
mapfile -t UNMERGED < <(git diff --name-only --diff-filter=U)
for f in "${UNMERGED[@]}"; do
    [[ -z "$f" ]] && continue
    if ! git cat-file -e "$UNS:$f" 2>/dev/null; then
        # Absent from unstable. Only rm if upstream actually DELETED it (absent at
        # the release commit). If it still exists at CTM, this is a stale-unstable
        # gap, not a delete — dropping it would ship a release missing a real file.
        if git cat-file -e "$CTM:$f" 2>/dev/null; then
            say "  ABORT: $f present upstream but absent from $UNS (stale unstable) — resolve by hand"; git merge --abort 2>/dev/null; cleanup; exit 1
        fi
        git rm -q "$f" 2>/dev/null && removed=$((removed+1)) || { say "  ABORT: cannot resolve $f"; git merge --abort 2>/dev/null; cleanup; exit 1; }
    fi
done
say "adopted=$adopted skipped_drift=$skipped_drift removed=$removed"
[[ -n "$(git diff --name-only --diff-filter=U)" ]] && { say "ABORT: unresolved remain: $(git diff --name-only --diff-filter=U|tr '\n' ' ')"; git merge --abort; cleanup; exit 1; }
grep -rIlq -e '^<<<<<<< ' -e '^>>>>>>> ' --include='*.sv' --include='*.v' --include='*.qip' . 2>/dev/null && { say "ABORT: conflict markers left"; git merge --abort; cleanup; exit 1; }
act=$(grep -rh --include='*.qip' --include='*.qsf' -E 'set_global_assignment' . 2>/dev/null | grep -v '^[[:space:]]*#' | grep -ic 'joydb\.sv')
[[ "$act" -gt 1 ]] && { say "ABORT: duplicate joydb.sv registration ($act active)"; git merge --abort 2>/dev/null; cleanup; exit 1; }
bash .github/check_status_collision.sh >/tmp/rsm_col.log 2>&1 || { say "ABORT: status-bit collision (relocate joy_type by hand — see C128)"; cat /tmp/rsm_col.log; cleanup; exit 1; }
# baseline was snapshotted pre-merge (above); this check flags only NEW failures.
bash .github/merge_validate.sh check . >/tmp/rsm_mv.log 2>&1 || { say "ABORT: merge_validate"; tail -4 /tmp/rsm_mv.log; cleanup; exit 1; }
say "GATES OK (worktree: $WT)"
CORES=$(basename "$CLONE"|sed 's/_MiSTer//;s/_MISTer//')
if [[ "${PUSH:-0}" == "1" ]]; then
    git commit -q -m "BOT: Merging upstream, release will publish ${CORES}. [skip ci]" \
        || { say "ABORT: commit failed — not pushing (would push unchanged tip)"; cleanup; exit 1; }
    git push origin "HEAD:$MB" >/tmp/rsm_push.log 2>&1 && say "pushed $MB $(git rev-parse --short HEAD)" || { say "ABORT push"; tail -3 /tmp/rsm_push.log; cleanup; exit 1; }
    gh api -X POST "repos/${REPO}/actions/workflows/release.yml/dispatches" -f ref="$MB" \
        -F "inputs[upstream_release_sha]=$CTM" -F "inputs[upstream_head_at_sync]=$UH" >/dev/null 2>&1 \
        && say "release.yml dispatched" || say "WARN dispatch failed (dispatch by hand)"
    cleanup
else
    say "DRY-RUN ok — worktree left at $WT for local Quartus build"
fi
exit 0
