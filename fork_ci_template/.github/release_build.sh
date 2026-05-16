#!/usr/bin/env bash
# Stable build leg — compile one matrix core with the per-leg Quartus the
# workflow resolved from THIS core's .qsf, stage the RBF for release_publish.sh.
#
#   release_build.sh <core> <input> <output> <date_stamp> <build_sha> -- <emails...>
#
# The workflow already checked the tree out at <build_sha> (HEAD pinned in
# preflight so parallel legs never drift); it's forwarded only for the asset
# infix. Carries no <<...>> placeholder — argv-driven; setup_cicd.sh must NOT
# sed it (same contract as quartus_build.sh / retry.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=quartus_build.sh
source "${SCRIPT_DIR}/quartus_build.sh"

CORE="$1" INPUT="$2" OUTPUT="$3" DATE_STAMP="$4" BUILD_SHA="$5"
shift 5
[[ "${1:-}" == "--" ]] && shift   # remaining args = maintainer emails

build_leg STABLE "${DATE_STAMP}_${BUILD_SHA:0:7}" "${CORE}" "${INPUT}" "${OUTPUT}" -- "$@"
