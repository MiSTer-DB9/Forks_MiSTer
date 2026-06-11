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
    configure_mergiraf
}

# Syntax-aware merge driver (https://mergiraf.org) for HDL sources. Resolves the
# "false conflict" class git's line merge can't: an upstream insertion adjacent
# to a fork rename/marker block, independent decls added to the same region, etc.
# Strictly additive to the rerere policy above:
#   * The driver is fed the three full revisions as files (%O/%A/%B) — it does
#     NOT read git's conflictstyle, so the 2-way `merge` style rerere depends on
#     is untouched. Do NOT switch conflictstyle to diff3 for mergiraf's sake; it
#     would break rerere's cross-branch preimage match (see the conflictstyle
#     comment above).
#   * A file mergiraf fully resolves produces no conflict, so rerere simply has
#     nothing to record for it. A file mergiraf leaves conflicted falls through
#     to rerere exactly as before. train_rerere's replay merges run through the
#     same driver as the live merge, so preimages stay in lockstep.
#   * mergiraf falls back to git's own line merge on parse error / timeout /
#     unsupported extension, so the worst case is identical to not having it.
# .v (Verilog) isn't a registered mergiraf language but is a near-subset of
# SystemVerilog, so it is force-routed through the SV grammar (-L SystemVerilog);
# the parse-error fallback covers the rare .v using an SV-reserved word as an
# identifier. If mergiraf isn't installed this is a silent no-op (current
# behaviour preserved) — the CI workflow installs it before the merge step.
configure_mergiraf() {
    command -v mergiraf >/dev/null 2>&1 || return 0
    git config --global merge.mergiraf.name "mergiraf"
    git config --global merge.mergiraf.driver \
        'mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L'
    git config --global "merge.mergiraf-verilog.name" "mergiraf (Verilog as SystemVerilog)"
    git config --global "merge.mergiraf-verilog.driver" \
        'mergiraf merge --git -L SystemVerilog %O %A %B -s %S -x %X -y %Y -p %P -l %L'
    # Repo-scoped, uncommitted attributes (the fork checkouts are upstream-tracked;
    # a tracked .gitattributes would be a merge-compat surface). git-dir/info/
    # attributes is rebuilt per CI run, like the rr-cache.
    local gitdir attrs
    gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 0
    attrs="${gitdir}/info/attributes"
    mkdir -p "${gitdir}/info" || return 0
    if ! grep -q 'merge=mergiraf' "${attrs}" 2>/dev/null; then
        {
            echo '*.sv  merge=mergiraf'
            echo '*.svh merge=mergiraf'
            echo '*.v   merge=mergiraf-verilog'
        } >> "${attrs}"
    fi
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

# Absolute path to the fork-only helper list, resolved next to THIS script so it
# works both in the umbrella (.github/lib/sys_helpers.list) and in a fork's
# flattened .github/ (cp -rL materialises the symlinked list beside this file).
_sys_helpers_list() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sys_helpers.list"
}

# Post-merge guard against rerere replaying a STALE resolution that reverts fork
# wiring (the 00f49da class: a canary "Update sys." resolution recorded before
# the remap matrix landed replayed pre-feature text and dropped joydb.sv's
# joydb_remap instance + the sys.qip registration). Such a revert is internally
# CONSISTENT at merge time, so merge_validate's regression-delta gate sees no new
# failure and the broken tree gets pushed; the later copy-only sys/ helper sync
# then re-installs a joydb.sv that needs the dropped registration -> Error 12006.
#
# The fork-only sys/ helpers (sys_helpers.list) do NOT exist in MiSTer-devel
# upstream, so a CORRECT upstream merge leaves every one byte-identical to the
# pre-merge fork side. Any diff on them is therefore necessarily a mis-replay ->
# abort the merge before it is pushed. False-positive-free: upstream has no side
# to legitimately change these files.
#
#   assert_fork_helpers_unchanged <ref_before> [<ref_after>]
# One ref  : diff <ref_before> vs the WORKING TREE  (stable: merge is
#            --no-commit, HEAD still the pre-merge tip).
# Two refs : diff <ref_before>..<ref_after>          (unstable: merge already
#            committed, so ref_after=HEAD, ref_before=HEAD^1).
# Returns 0 = all helpers unchanged; 1 (with a stderr report) = a helper changed.
# Missing list (propagation bug) fails OPEN (warn + 0) so guard infra can't wedge
# every sync.
assert_fork_helpers_unchanged() {
    local ref_before="$1" ref_after="${2:-}" list
    list="$(_sys_helpers_list)"
    if [ ! -f "${list}" ]; then
        echo >&2 "assert_fork_helpers_unchanged: helper list ${list} missing — skipping guard (fail-open)"
        return 0
    fi
    local -a helpers specs=()
    mapfile -t helpers < <(grep -vE '^[[:space:]]*(#|$)' "${list}")
    if [ "${#helpers[@]}" -eq 0 ]; then
        # List present but empty (truncated to its comment header, or a bad
        # propagation). With no basenames `specs` is empty and an unrestricted
        # `git diff --name-only <ref>` would list EVERY changed file -> the
        # `-z` test fails -> a guaranteed false abort on every sync. Fail OPEN
        # like the missing-list case so broken guard infra can't wedge the fleet.
        echo >&2 "assert_fork_helpers_unchanged: helper list ${list} has no entries — skipping guard (fail-open)"
        return 0
    fi
    local b
    for b in "${helpers[@]}"; do
        # fnmatch pathspec. `*/<b>` matches the helper at any depth (they always
        # live under */sys/ — setup_cicd.sh only ever copies them into a sys/
        # dir); `*` spans `/`, and the leading `*/` requires a path separator so
        # a `foo<b>` basename can't false-match.
        specs+=("*/${b}")
    done
    local changed
    if [ -n "${ref_after}" ]; then
        changed="$(git diff --name-only "${ref_before}" "${ref_after}" -- "${specs[@]}")"
    else
        changed="$(git diff --name-only "${ref_before}" -- "${specs[@]}")"
    fi
    [ -z "${changed}" ] && return 0
    echo >&2 "assert_fork_helpers_unchanged: upstream merge modified fork-only sys/ helper(s) that do NOT exist upstream — a rerere mis-replay reverted fork wiring:"
    printf >&2 '  %s\n' "${changed}"
    return 1
}
