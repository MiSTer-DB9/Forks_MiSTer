#!/usr/bin/env bash
#
# Apply the MiSTer-DB9 fork framework to a core repo: ship `sys/joydb*.{v,sv}`
# helpers, land DB9 + Pro additions in `sys/hps_io.sv` / `sys/sys_top.v` /
# `sys/sys.tcl`, and lift `<core>.sv` to the joydb wrapper-thin form.
#
# Two paths handle whatever shape `sys/` is in:
#   * pristine upstream — `sys.patch` applies cleanly.
#   * legacy-patched   — fall back to `upgrade_pro_additive.py`, which adds
#     only the missing Pro extensions on top of the existing DB9 baseline.
#     Avoids resetting `sys/` from upstream — that can pull in newer
#     sys_top.v versions referencing emu-module ports the fork's `<core>.sv`
#     doesn't yet declare (HDMI_BLACKOUT, HDMI_BOB_DEINT, ...).
#
# Idempotent: re-running on an already-Pro fork is a no-op.

set -euo pipefail

apply_db9_framework() {
    local dir="${1}"
    local patch upgrader porter eol_io
    patch=$(realpath fork_ci_template/sys.patch)
    upgrader=$(realpath porting/upgrade_pro_additive.py)
    porter=$(realpath porting/port_core_full.py)
    eol_io=$(realpath porting/_eol_io.py)

    cp -r fork_ci_template/sys "${dir}/"

    # Pre-SV-rename forks ship `sys/hps_io.v` (Verilog), post-rename ones ship
    # `sys/hps_io.sv`. The fork's hps_io additions use SV constructs (the
    # `uio_block.cmd` hierarchical name in the `db9_key_gate` instance),
    # so when only `.v` exists we keep the filename — Critical Rule #1
    # forbids renaming upstream files — and instead flip its sys.qip entry
    # from VERILOG_FILE to SYSTEMVERILOG_FILE further down so Quartus
    # compiles it in SV mode.
    local hps_io hps_io_rel
    if [ -f "${dir}/sys/hps_io.sv" ]; then
        hps_io_rel='sys/hps_io.sv'
    else
        hps_io_rel='sys/hps_io.v'
    fi
    hps_io="${dir}/${hps_io_rel}"

    # Snapshot EOL of the three patch targets so we can restore after
    # `git apply` (which always lands LF lines, mixing them with CRLF
    # targets). The additive-upgrader path preserves EOL internally.
    local nls
    nls=$(python3 "${eol_io}" snapshot \
        "${hps_io}" "${dir}/sys/sys_top.v" "${dir}/sys/sys.tcl")
    read -r nl_hps nl_top nl_tcl <<<"${nls}"

    if grep -q saturn_unlocked "${hps_io}" 2>/dev/null; then
        echo "  ${dir}: already at Pro form — skipping sys.patch"
    elif git -C "${dir}" apply --check --ignore-whitespace < "${patch}" 2>/dev/null; then
        echo "  ${dir}: pristine upstream sys/ — applying sys.patch"
        git -C "${dir}" apply --ignore-whitespace < "${patch}"
        python3 "${eol_io}" apply "${nl_hps}" "${hps_io}"
        python3 "${eol_io}" apply "${nl_top}" "${dir}/sys/sys_top.v"
        python3 "${eol_io}" apply "${nl_tcl}" "${dir}/sys/sys.tcl"
    else
        echo "  ${dir}: legacy-patched sys/ — running additive Pro upgrader"
    fi

    python3 "${upgrader}" "${dir}"
    python3 "${porter}"   "${dir}"

    pushd "${dir}" >/dev/null

    grep -Fwq joydb9md.v       sys/sys.qip || echo 'set_global_assignment -name VERILOG_FILE        [file join $::quartus(qip_path) joydb9md.v ]'       >> sys/sys.qip
    grep -Fwq joydb15.v        sys/sys.qip || echo 'set_global_assignment -name VERILOG_FILE        [file join $::quartus(qip_path) joydb15.v ]'        >> sys/sys.qip
    grep -Fwq joydb9saturn.v   sys/sys.qip || echo 'set_global_assignment -name VERILOG_FILE        [file join $::quartus(qip_path) joydb9saturn.v ]'   >> sys/sys.qip
    grep -Fwq joydb.sv         sys/sys.qip || echo 'set_global_assignment -name SYSTEMVERILOG_FILE  [file join $::quartus(qip_path) joydb.sv ]'         >> sys/sys.qip
    grep -Fwq siphash24.v      sys/sys.qip || echo 'set_global_assignment -name VERILOG_FILE        [file join $::quartus(qip_path) siphash24.v ]'      >> sys/sys.qip
    grep -Fwq db9_key_gate.sv  sys/sys.qip || echo 'set_global_assignment -name SYSTEMVERILOG_FILE  [file join $::quartus(qip_path) db9_key_gate.sv ]'  >> sys/sys.qip

    # On `hps_io.v` cores, flip the sys.qip entry from VERILOG_FILE to
    # SYSTEMVERILOG_FILE so Quartus accepts the SV hierarchical name
    # `uio_block.cmd` that the additive upgrader inserts in the
    # db9_key_gate instantiation. Idempotent: matches only the
    # VERILOG_FILE form.
    if [ -f sys/hps_io.v ]; then
        sed -i -E 's|^(set_global_assignment -name )VERILOG_FILE([[:space:]]+\[file join \$::quartus\(qip_path\) hps_io\.v[[:space:]]*\])|\1SYSTEMVERILOG_FILE\2|' sys/sys.qip

        # Modern upstream sys/hps_io.sv labels the USER_IO command-handling
        # always block `: uio_block` so db9_key_gate can reach `cmd` via
        # `uio_block.cmd`. Legacy hps_io.v shipped before that rename has
        # the same block but anonymous — Quartus errors with `object
        # "uio_block" is not declared`. Inject the label on the unique
        # always block whose first declaration is `reg [15:0] cmd;`.
        if ! grep -q ": uio_block" sys/hps_io.v; then
            perl -i -0pe 's{always\@\(posedge clk_sys\) begin\n\treg \[15:0\] cmd;}{// [MiSTer-DB9-Pro BEGIN] - named so db9_key_gate can reach in via uio_block.cmd\nalways\@(posedge clk_sys) begin : uio_block\n// [MiSTer-DB9-Pro END]\n\treg [15:0] cmd;}' sys/hps_io.v
        fi
    fi

    git add sys/joydb9md.v sys/joydb15.v sys/joydb9saturn.v sys/joydb.sv \
            sys/siphash24.v sys/db9_key_gate.sv sys/db9_key_secret.vh \
            sys/sys.qip "${hps_io_rel}" sys/sys_top.v sys/sys.tcl

    # Stage any top-level <core>.sv the upgrader/porter touched.
    git add -u -- '*.sv'

    # Remove legacy joydb files (older forks kept them at repo root or rtl/).
    # Per-file because forks may have any subset (e.g. joydb9md.v + joydb15.v
    # but no joydb9saturn.v).
    local removed_any=0
    for legacy in joydb9md.v joydb15.v joydb9saturn.v \
                  rtl/joydb9md.v rtl/joydb15.v rtl/joydb9saturn.v; do
        if [ -f "${legacy}" ]; then
            git rm -f "${legacy}"
            removed_any=1
        fi
    done
    if [ "${removed_any}" = "1" ] && [ -f files.qip ]; then
        sed -i -e '/joydb9md\.v/d' -e '/joydb15\.v/d' -e '/joydb9saturn\.v/d' files.qip
        git add files.qip
    fi

    # Remove the legacy `sys/joydbmix.sv` wrapper (superseded by `sys/joydb.sv`)
    # plus its sys.qip registration. Affects ~11 arcade cores.
    if [ -f sys/joydbmix.sv ]; then
        git rm -f sys/joydbmix.sv
        sed -i '/joydbmix\.sv/d' sys/sys.qip
        git add sys/sys.qip
    fi

    popd >/dev/null
}


apply_db9_framework "${@}"
