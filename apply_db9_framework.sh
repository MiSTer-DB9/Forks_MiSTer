#!/usr/bin/env bash

set -euo pipefail

apply_db9_framework() {
    local dir="${1}"

    cp -r fork_ci_template/sys "${dir}/"
    patch -Np1 -d "${dir}/" < fork_ci_template/sys.patch || :

    pushd "${dir}" >/dev/null

    grep -Fwq joydb9md.v sys/sys.qip || echo 'set_global_assignment -name VERILOG_FILE       [file join $::quartus(qip_path) joydb9md.v ]' >> sys/sys.qip
    grep -Fwq joydb15.v  sys/sys.qip || echo 'set_global_assignment -name VERILOG_FILE       [file join $::quartus(qip_path) joydb15.v ]'  >> sys/sys.qip

    git add sys/joydb9md.v sys/joydb15.v sys/sys.qip

    # Remove the old joydb files
    if git rm -f joydb9md.v joydb15.v || git rm -f rtl/joydb9md.v rtl/joydb15.v; then
        sed -i -e '/joydb9md\.v/d' -e '/joydb15\.v/d' files.qip
        sed -i "s/^\(\s*\).joy_raw(OSD_STATUS?\s*(\(\S*\)\[5:0\]|\(\S*\)\[5:0\])\s*:\s*6'b000000\s*),.*/\1.joy_raw(OSD_STATUS? (\2[11:0] | \3[11:0]) : 11'b0),/" *.sv
        git add files.qip
    fi
}


apply_db9_framework "${@}"
