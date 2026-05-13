#!/usr/bin/env bash
# Shared by release.sh and unstable_release.sh.
# `HDL_GLOBS` doubles as the `find`-name filter for `compute_source_hash` and
# as the path-filter argv tail for git-diff-based change detection — adding a
# new file extension only requires editing this list. `<<EXTRA_SOURCE_GLOBS>>`
# is per-section: empty for HDL cores (default), expanded with C/C++/Makefile
# entries for non-HDL forks (Main_MiSTer) via Forks.ini `EXTRA_SOURCE_GLOBS`.

HDL_GLOBS=(
    '*.v' '*.sv' '*.vhd' '*.vhdl'
    '*.qsf' '*.qip' '*.qpf' '*.sdc'
    '*.tcl' '*.mif' '*.hex'
    #<<EXTRA_SOURCE_GLOBS>>
)

# Path-sorted sha256 of every HDL/build-config file in the tree. Skips .git,
# releases/ (stable RBFs), output_files/ (Quartus artifacts), bin/ (Main_MiSTer
# BUILDDIR). Adds, removes, renames, content edits all change the digest.
#
# db9_key_secret.{h,vh} are CI-materialised from MASTER_ROOT_HEX before the
# build runs (materialize_secret.sh). They MUST be excluded from the hash so
# the result is independent of materialise order — the preflight step computes
# the hash before the secret is written; the build step writes the secret and
# then proceeds. Without this filter, the two callers would disagree on the
# digest and the skip path would never fire on Main_MiSTer-style HPS builds.
compute_source_hash() {
    local find_filter=()
    local first=1
    for g in "${HDL_GLOBS[@]}"; do
        if (( first )); then
            find_filter+=(-name "${g}")
            first=0
        else
            find_filter+=(-o -name "${g}")
        fi
    done
    find . \( -path ./.git -o -path ./releases -o -path ./output_files -o -path ./bin \) -prune \
        -o -type f ! -name db9_key_secret.h ! -name db9_key_secret.vh \
           \( "${find_filter[@]}" \) -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum | awk '{print $1}'
}
