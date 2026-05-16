#!/usr/bin/env bash
# Compute the deduplicated set of Quartus *Standard* versions actually needed
# across every fork in Forks.ini, so publish_quartus_artifact.yml publishes
# exactly those ghcr tarball artifacts (no hardcoded list — auto-tracks new
# forks / .qsf bumps).
#
# Per fork section:
#   - COMPILATION_INPUT = make            -> not a Quartus core, skip
#   - QUARTUS_NATIVE set and != auto      -> use that explicit pin verbatim
#   - else fetch the core's .qsf LAST_QUARTUS_VERSION from its fork repo via
#     the GitHub API and run it through quartus_map_std() — the SAME mapping
#     detect_quartus_version.sh uses at build time (single source of truth).
#
# stdout : compact JSON array, sorted, e.g. ["17.0std","17.1std","20.1std"]
#          (consumed as a workflow matrix via fromJSON).
# stderr : per-core resolution log + summary.
#
# Lives in Forks_MiSTer/.github (control repo, not propagated to forks). Needs
# `gh` authenticated (GH_TOKEN / GITHUB_TOKEN) for the contents API.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKS_INI="${REPO_ROOT}/Forks.ini"
# Shared mapping (quartus_map_std). Sourced — defines functions only.
# shellcheck source=fork_ci_template/.github/detect_quartus_version.sh
source "${REPO_ROOT}/fork_ci_template/.github/detect_quartus_version.sh"

[[ -f "${FORKS_INI}" ]] || { echo "compute_quartus_versions: ${FORKS_INI} not found" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "compute_quartus_versions: gh CLI required" >&2; exit 1; }

# One awk pass: emit "section<US>compilation_input<US>quartus_native<US>fork_repo<US>main_branch"
# for every fork section (skip the [Forks] meta section). Missing keys → empty.
# Separator is 0x1F (US): a non-whitespace char so empty fields survive `read`
# (a whitespace IFS like TAB collapses empties and shifts columns).
mapfile -t ROWS < <(awk '
    BEGIN { US = sprintf("%c", 31) }
    function flush() {
        if (sec != "" && sec != "Forks")
            print sec US ci US qn US repo US br
        ci=""; qn=""; repo=""; br=""
    }
    /^\[/ { flush(); sec=$0; sub(/^\[/,"",sec); sub(/\].*$/,"",sec); next }
    /^[[:space:]]*COMPILATION_INPUT[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/,""); ci=$0; next }
    /^[[:space:]]*QUARTUS_NATIVE[[:space:]]*=/     { sub(/^[^=]*=[[:space:]]*/,""); qn=$0; next }
    /^[[:space:]]*FORK_REPO[[:space:]]*=/          { sub(/^[^=]*=[[:space:]]*/,""); repo=$0; next }
    /^[[:space:]]*MAIN_BRANCH[[:space:]]*=/        { sub(/^[^=]*=[[:space:]]*/,""); br=$0; next }
    END { flush() }
' "${FORKS_INI}")

declare -A SEEN=()
N_MAKE=0 N_PIN=0 N_QSF=0 N_FAIL=0

for row in "${ROWS[@]}"; do
    IFS=$'\037' read -r SEC CI QN REPO BR <<<"${row}"
    CI="${CI%%[[:space:]]*}"     # first token of COMPILATION_INPUT
    BR="${BR:-master}"

    if [[ "${CI}" == "make" || -z "${CI}" ]]; then
        N_MAKE=$((N_MAKE+1)); continue
    fi

    if [[ -n "${QN}" && "${QN}" != "auto" ]]; then
        echo "  ${SEC}: pin ${QN}" >&2
        SEEN["${QN}"]=1; N_PIN=$((N_PIN+1)); continue
    fi

    # auto: derive the .qsf path from COMPILATION_INPUT, fetch it from the fork.
    case "${CI}" in
        *.qpf) QSF="${CI%.qpf}.qsf" ;;
        *.qsf) QSF="${CI}" ;;
        *)     QSF="${CI}.qsf" ;;
    esac
    # https://github.com/OWNER/REPO(.git) -> OWNER/REPO
    SLUG="${REPO#https://github.com/}"; SLUG="${SLUG%.git}"
    if [[ -z "${SLUG}" || "${SLUG}" == "${REPO}" ]]; then
        echo "  ${SEC}: WARN unparseable FORK_REPO '${REPO}' — skipped" >&2
        N_FAIL=$((N_FAIL+1)); continue
    fi

    if RAW=$(gh api "repos/${SLUG}/contents/${QSF}?ref=${BR}" \
                -H "Accept: application/vnd.github.raw" 2>/dev/null); then
        VER=$(quartus_qsf_version_from_text <<<"${RAW}")
        if [[ -n "${VER}" ]]; then
            STD="$(quartus_map_std "${VER}")"
            echo "  ${SEC}: ${QSF} LAST_QUARTUS_VERSION=${VER} -> ${STD}" >&2
            SEEN["${STD}"]=1; N_QSF=$((N_QSF+1)); continue
        fi
        echo "  ${SEC}: WARN no LAST_QUARTUS_VERSION in ${QSF} — skipped (provision fallback at build)" >&2
    else
        echo "  ${SEC}: WARN could not fetch ${SLUG}:${QSF}@${BR} — skipped (provision fallback at build)" >&2
    fi
    N_FAIL=$((N_FAIL+1))
done

mapfile -t VERSIONS < <(printf '%s\n' "${!SEEN[@]}" | sort)
{
    echo "---"
    echo "compute_quartus_versions: ${#VERSIONS[@]} version(s): ${VERSIONS[*]}"
    echo "  resolved by pin=${N_PIN} qsf=${N_QSF} | skipped make=${N_MAKE} unresolved=${N_FAIL}"
} >&2

# Compact JSON array on stdout.
printf '['
for i in "${!VERSIONS[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '"%s"' "${VERSIONS[$i]}"
done
printf ']\n'
