#!/usr/bin/env bash
# Tiny helpers for GitHub Actions output / env emission. Sourced by both
# preflight_skip.sh (stable) and unstable_preflight.sh / unstable_merge.sh.

emit_out() {
    echo "$1=$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT not set — must run inside GitHub Actions}"
}

emit_skip() {
    emit_out skip "$1"
}

emit_env() {
    echo "$1=$2" >> "${GITHUB_ENV:?GITHUB_ENV not set — must run inside GitHub Actions}"
}
