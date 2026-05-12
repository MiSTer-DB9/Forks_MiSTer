#!/usr/bin/env bash
# Shared by release_v2.sh and unstable_release.sh.
# `HDL_GLOBS` doubles as the `find`-name filter for `compute_source_hash` and
# as the path-filter argv tail for git-diff-based change detection — adding a
# new file extension only requires editing this list.

HDL_GLOBS=(
    '*.v' '*.sv' '*.vhd' '*.vhdl'
    '*.qsf' '*.qip' '*.qpf' '*.sdc'
    '*.tcl' '*.mif' '*.hex'
)

# Path-sorted sha256 of every HDL/build-config file in the tree. Skips .git,
# releases/ (stable RBFs), output_files/ (Quartus artifacts). Adds, removes,
# renames, content edits all change the digest.
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
    find . \( -path ./.git -o -path ./releases -o -path ./output_files \) -prune \
        -o -type f \( "${find_filter[@]}" \) -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum | awk '{print $1}'
}
