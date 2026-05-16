#!/usr/bin/env bash
# Build the `strategy.matrix` JSON for the per-core build fan-out.
#
#   emit_matrix.sh "<core ...>" "<input ...>" "<output ...>"
#
# The three args are the space-separated lists setup_cicd.sh templates into the
# workflow from a fork group's Forks.ini sections (RELEASE_CORE_NAME /
# COMPILATION_INPUT / COMPILATION_OUTPUT — element-aligned). Echoes a compact
#   {"include":[{"core":..,"input":..,"output":..}, ...]}
# on stdout for `fromJson()` in the build job. Single-core groups yield a
# one-element matrix (identical behaviour to the pre-split single job, one
# extra cheap fan-out hop).
#
# Carries no <<...>> placeholder — it takes its inputs as argv, so setup_cicd.sh
# must NOT sed it (same contract as quartus_build.sh / retry.sh).

set -euo pipefail

read -r -a CORES   <<< "${1:-}"
read -r -a INPUTS  <<< "${2:-}"
read -r -a OUTPUTS <<< "${3:-}"

if (( ${#CORES[@]} != ${#INPUTS[@]} )) || (( ${#CORES[@]} != ${#OUTPUTS[@]} )); then
    echo "emit_matrix: length mismatch (cores=${#CORES[@]} inputs=${#INPUTS[@]} outputs=${#OUTPUTS[@]})" >&2
    exit 1
fi
if (( ${#CORES[@]} == 0 )); then
    echo "emit_matrix: empty core list" >&2
    exit 1
fi

{
    for i in "${!CORES[@]}"; do
        jq -cn --arg c "${CORES[i]}" --arg in "${INPUTS[i]}" --arg o "${OUTPUTS[i]}" \
            '{core:$c, input:$in, output:$o}'
    done
} | jq -cs '{include: .}'
