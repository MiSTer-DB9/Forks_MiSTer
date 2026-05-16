#!/usr/bin/env bash
# Unstable build leg — compile one matrix core from the already-pushed unstable
# merge commit with the per-leg Quartus resolved from THIS core's .qsf, stage
# the RBF for unstable_publish.sh.
#
#   unstable_build.sh <core> <input> <output> <timestamp> <upstream_sha> -- <emails...>
#
# Carries no <<...>> placeholder — argv-driven; setup_cicd.sh must NOT sed it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=quartus_build.sh
source "${SCRIPT_DIR}/quartus_build.sh"

CORE="$1" INPUT="$2" OUTPUT="$3" TIMESTAMP="$4" UPSTREAM_SHA="$5"
shift 5
[[ "${1:-}" == "--" ]] && shift   # remaining args = maintainer emails

build_leg UNSTABLE "unstable_${TIMESTAMP}_${UPSTREAM_SHA:0:7}" "${CORE}" "${INPUT}" "${OUTPUT}" -- "$@"
