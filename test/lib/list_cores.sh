#!/usr/bin/env bash
# Shared enumerator for cores whose Quartus project lives in a SUBDIR of the
# fork repo instead of at its root (Forks.ini `CORE_DIR`; SYSTEM11_MiSTer/source
# is the first one). Every fleet enumerator globs `*/` or `*/sys/...` from the
# MiSTer-DB9 tree root and so misses these entirely; each appends this list to
# its own rather than widening its glob, which keeps the depth-1 semantics (and
# each script's own skip list) untouched.
#
# Emits repo-relative `<Fork>_MiSTer/<subdir>` paths, one per line, and must be
# called with the tree root as cwd.
#
# Two filters, both needed:
#   * the TOP-level dir must be a git clone. Drops the `unstable/`, `unstable_wt/`,
#     `stable_wt/` and `variant_wt/` worktree parking areas, which hold ~110
#     second-level `sys/joydb.sv` copies that merely duplicate cores the depth-1
#     pass already returns (and a half-resolved worktree there would red-fail the
#     pre-sync gate).
#   * the subdir must hold the Quartus project file. Drops
#     `Forks_MiSTer/fork_ci_template`, which ships the canonical `sys/` helpers
#     but is not a core. Testing for `*.qpf` rather than a `module emu` `.sv` is
#     deliberate: jtframe cores (Arcade-Deco16) keep `emu` in `rtl/emu.sv`.
list_subdir_cores() {
    local d c
    for d in */*/sys; do
        [ -d "$d" ] || continue
        c="${d%/sys}"
        [ -e "${c%%/*}/.git" ] || continue
        compgen -G "${c}/*.qpf" >/dev/null || continue
        echo "$c"
    done
}
