# shellcheck shell=bash
# Replay the fork's prior merge commits so rerere learns historical conflict
# resolutions before the upcoming `git merge upstream/...`. Without this,
# every upstream tick that touches a recurring conflict spot would require
# human intervention.
#
# Symlinked into fork_ci_template/.github/rerere_train.sh; setup_cicd.sh's
# `cp -rL` materialises it into each fork. Both sync_release.sh (stable) and
# unstable_release.sh (unstable) can source it via `source "${SCRIPT_DIR}/rerere_train.sh"`.
#
# Expects to be called from the fork checkout root, on the branch we intend
# to merge into.

# Single owner of this fork's rerere/merge policy — called by every script that
# trains rerere or merges upstream (sync_release.sh, unstable_preflight.sh,
# unstable_merge.sh) so the three knobs can't drift apart per script.
configure_rerere() {
    git config --global rerere.enabled true
    # 2-way conflict markers (no base section). rerere keys on the rendered
    # conflict text; a base-bearing style (diff3/zdiff3) bakes the merge-base into
    # the preimage, so a resolution recorded against the unstable branch's
    # merge-base would NOT match the stable merge's different base (master vs
    # unstable reach the upstream release via different ancestry) and rerere would
    # miss. 2-way drops the base → preimage = ours+theirs only → the canary
    # resolution recorded on unstable replays on the stable merge.
    git config --global merge.conflictstyle merge
    # Stage rerere's auto-applied resolutions. Without autoupdate they are written
    # to the working tree but left UNMERGED in the index, so the merge still
    # reports failure and the commit cannot proceed.
    git config --global rerere.autoupdate true
}

train_rerere() {
    local ORIGINAL_BRANCH ORIGINAL_HEAD
    ORIGINAL_BRANCH=$(git symbolic-ref -q HEAD) ||
    ORIGINAL_HEAD=$(git rev-parse --verify HEAD) || {
        echo >&2 "train_rerere: Not on any branch and no commit yet?"
        return 1
    }

    mkdir -p ".git/rr-cache" || true
    git rev-list --parents "HEAD" |
    while read commit parent1 other_parents
    do
        if test -z "${other_parents}"
        then
            continue
        fi
        git checkout -q "${parent1}^0"
        # MUST mirror the live merge's strategy options (every live merge —
        # sync_release.sh, unstable_merge.sh, unstable_preflight.sh — uses
        # -Xignore-all-space). rerere keys on the rendered conflict text, and
        # -Xignore-all-space changes which hunks conflict and how they segment;
        # replaying with a plain merge here produces a DIFFERENT preimage than the
        # live merge, so the recorded resolution never matches and rerere misses
        # (observed fleet-wide on the upstream 2026-06-03 "Update sys." conflict:
        # sys.qip happened to segment identically and replayed, but NES.sv /
        # sys/hps_io.sv reindented by upstream did not). Keep these in lockstep.
        if git merge -Xignore-all-space ${other_parents} >/dev/null 2>&1
        then
            continue
        fi
        if test -s ".git/MERGE_RR"
        then
            git show -s --pretty=format:"Learning from %h %s" "${commit}"
            git rerere
            git checkout -q ${commit} -- .
            git rerere
        fi
        git reset -q --hard
    done

    if test -z "${ORIGINAL_BRANCH}"
    then
        git checkout "${ORIGINAL_HEAD}"
    else
        git checkout "${ORIGINAL_BRANCH#refs/heads/}"
    fi
}
