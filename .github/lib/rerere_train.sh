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
        if git merge ${other_parents} >/dev/null 2>&1
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
