#!/usr/bin/env bash
# Resolve a quartus-install.py version key for the native Quartus build path
# — the only FPGA build path now. (Sibling detect_quartus_image.sh is
# retained for the Main_MiSTer gcc-arm pipeline.)
#
# Priority (CLI mode):
#   1. $QUARTUS_NATIVE_OVERRIDE — explicit Forks.ini value (e.g. "17.0std").
#      The literal "auto" means "ignore me, parse the qsf instead".
#      (An explicit pin short-circuits before any network — see _main.)
#   2. Parse LAST_QUARTUS_VERSION from <COMPILATION_INPUT>.qsf and map to the
#      closest *std (Standard edition) key — exact major.minor, else highest
#      <= target, else highest available.
#      The fork always builds Standard: it has the timing-driven router/
#      fitter and the org QUARTUS_LICENSE entitles it. Altera's modern line
#      (21.1, 22.1, 23.1, 24.1, 25.1) ships Standard alongside Lite/Pro, so
#      every core resolves to a Standard key at exact version parity (a
#      qsf that records "... Lite Edition" only reflects how the upstream
#      author saved the project — the same-version Standard build produces
#      the identical IP / pll_q netlist; edition differs in fitter/device
#      support, not megafunction output). The rest of the pipeline passes
#      the key through verbatim (provision/quartus-install.py/prebuilt
#      image are version-agnostic).
#
# The candidate key set is NOT hardcoded: it is fetched from the single
# source of truth — `quartus-install.py --list-versions` — via a memoized
# shallow clone of $QUARTUS_INSTALL_REPO (one clone per process; cached for
# the ~160-fork compute loop). Hard-fails loudly if the list can't be
# fetched (the repo is already a hard build dependency; failing fast beats
# silently picking a wrong Quartus). No second list to keep in sync.
#
# Echoes the resolved key on stdout. Exits non-zero on detection failure.
#
# Dual use: this file is both an executable CLI and a sourceable library.
# `source detect_quartus_version.sh` defines quartus_map_std() (the bare
# version-string → key mapping) WITHOUT running the CLI, so
# compute_quartus_versions.sh shares the exact same mapping (single source of
# truth — the matrix builder and the per-core resolver can never diverge).

set -euo pipefail

# quartus-install repo to query for the supported version set. Same default
# as setup_cicd.sh:13; release.yml/unstable_release.yml thread the
# deployment's <<QUARTUS_INSTALL_REPO>> into the Resolve step's env.
QUARTUS_INSTALL_REPO="${QUARTUS_INSTALL_REPO:-https://github.com/drizzt/quartus-install.git}"

# Per-process cache FILE for the version list. A shell var alone is
# insufficient: quartus_map_std is invoked via $(...) (compute_quartus_
# versions.sh, ~160×/run) so an in-memory assignment dies in the command-
# substitution subshell. `$$` is the parent shell PID — stable across those
# subshells (one shared file for the whole compute loop) yet distinct per
# CLI `bash detect_quartus_version.sh` invocation (one clone per build job).
_QUARTUS_KEYS_FILE="${TMPDIR:-/tmp}/.detect_quartus_keys.$$"

# _quartus_load_keys — ensure $_QUARTUS_KEYS_CACHE holds the newline-
# separated `quartus-install.py --list-versions` output. Memoized via the
# in-shell var (fast path) backed by $_QUARTUS_KEYS_FILE (survives the
# $(...) subshells), so the version list is fetched at most once per
# process. Returns non-zero (with a stderr message) on any fetch failure —
# callers propagate it; nothing falls back to a stale embedded list.
_quartus_load_keys() {
    [[ -n "${_QUARTUS_KEYS_CACHE:-}" ]] && return 0
    if [[ -s "${_QUARTUS_KEYS_FILE}" ]]; then
        _QUARTUS_KEYS_CACHE=$(cat "${_QUARTUS_KEYS_FILE}")
        return 0
    fi
    local tmp keys
    tmp=$(mktemp -d) || {
        echo "detect_quartus_version: mktemp failed" >&2; return 1; }
    if ! git clone --depth 1 --quiet "${QUARTUS_INSTALL_REPO}" \
            "${tmp}/qi" 2>/dev/null; then
        rm -rf "${tmp}"
        echo "detect_quartus_version: could not clone ${QUARTUS_INSTALL_REPO}" >&2
        return 1
    fi
    if ! keys=$(python3 "${tmp}/qi/quartus-install.py" \
            --list-versions 2>/dev/null); then
        rm -rf "${tmp}"
        echo "detect_quartus_version: 'quartus-install.py --list-versions' failed (${QUARTUS_INSTALL_REPO})" >&2
        return 1
    fi
    rm -rf "${tmp}"
    if [[ -z "${keys}" ]]; then
        echo "detect_quartus_version: empty version list from ${QUARTUS_INSTALL_REPO}" >&2
        return 1
    fi
    _QUARTUS_KEYS_CACHE="${keys}"
    # Best-effort persist for the $(...) subshell callers; a write failure
    # only costs an extra clone, never correctness.
    printf '%s\n' "${keys}" > "${_QUARTUS_KEYS_FILE}" 2>/dev/null || true
}

# Comparable integer for ordering. Strip non-digits per dot-segment so
# "17.0.2" parses as (17,0,2) and "17.0std" as (17,0,0). Pure bash (no awk
# fork): quartus_map_std calls this O(10) times per version, and
# compute_quartus_versions.sh maps ~160 forks — awk subshells there cost
# thousands of process spawns. `10#` forces base-10 so a stripped "08" etc.
# is not misread as octal.
to_num() {
    local a b c
    IFS=. read -r a b c _ <<<"$1"
    a=${a//[!0-9]/}; b=${b//[!0-9]/}; c=${c//[!0-9]/}
    echo $(( 10#${a:-0} * 1000000 + 10#${b:-0} * 1000 + 10#${c:-0} ))
}

# _quartus_pick_closest <target-num> <key...> — from the candidate keys
# (passed as positional args), echo the best match for the integer
# <target-num> (a to_num value):
#   1. exact major.minor match
#   2. else highest candidate <= target (closest downgrade)
#   3. else (target below all) highest candidate
# Pure: no env, no I/O. Shared by the Standard and Lite mappings so they can
# never diverge.
_quartus_pick_closest() {
    local target="$1"; shift
    local t tt best best_tuple highest highest_tuple

    # 1. Exact major.minor match.
    for t in "$@"; do
        if [[ "$(to_num "${t}")" == "${target}" ]]; then
            echo "${t}"
            return 0
        fi
    done

    # 2. Highest candidate <= target.
    best=""
    best_tuple=""
    for t in "$@"; do
        tt=$(to_num "${t}")
        if [[ "${tt}" -le "${target}" ]]; then
            if [[ -z "${best_tuple}" || "${tt}" -gt "${best_tuple}" ]]; then
                best="${t}"
                best_tuple="${tt}"
            fi
        fi
    done
    if [[ -n "${best}" ]]; then
        echo "${best}"
        return 0
    fi

    # 3. Target lower than all candidates — fall back to highest candidate.
    highest=""
    highest_tuple=""
    for t in "$@"; do
        tt=$(to_num "${t}")
        if [[ -z "${highest_tuple}" || "${tt}" -gt "${highest_tuple}" ]]; then
            highest="${t}"
            highest_tuple="${tt}"
        fi
    done
    echo "${highest}"
}

# quartus_map_std <raw-version> — map a LAST_QUARTUS_VERSION-style string
# ("17.0.2", "17.0std", "25.1std.0 Lite Edition", ...) to the closest *std
# (Standard edition) key from `quartus-install.py --list-versions`. The fork
# always builds Standard (timing-driven fitter; org QUARTUS_LICENSE entitles
# it); Altera ships Standard for the modern 21.1..25.1 line too, so every
# core gets a Standard key at exact version parity. Name kept (`_std`) for
# caller/source compatibility (release.yml, unstable_release.yml,
# compute_quartus_versions.sh). Echoes the resolved key. Not pure: triggers
# the memoized version-list fetch on first call.
quartus_map_std() {
    local VER="$1" VER_MM target t
    local -a pool=()

    # Compare on the (major,minor) prefix only — patch level (e.g. 17.0.2)
    # maps to the same install (17.0std applies its own update_1 internally).
    VER_MM=$(awk -F'.' '{print $1"."$2}' <<<"${VER}")
    target=$(to_num "${VER_MM}")

    _quartus_load_keys || return 1

    while IFS= read -r t; do
        [[ -z "${t}" ]] && continue
        case "${t}" in
            *std) pool+=("${t}") ;;
        esac
    done <<<"${_QUARTUS_KEYS_CACHE}"

    if [[ "${#pool[@]}" -eq 0 ]]; then
        echo "detect_quartus_version: no Standard (*std) key in quartus-install.py version list (target ${VER_MM})" >&2
        return 1
    fi
    _quartus_pick_closest "${target}" "${pool[@]}"
}

# quartus_qsf_version_from_text — read .qsf content on stdin, echo the raw
# LAST_QUARTUS_VERSION value (empty if absent). The single parse, shared by
# the file-path resolver below and compute_quartus_versions.sh (which has the
# .qsf as an API blob, not a path).
quartus_qsf_version_from_text() {
    grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+LAST_QUARTUS_VERSION' \
      | head -1 \
      | sed -E 's/.*LAST_QUARTUS_VERSION[[:space:]]+(.*)/\1/' \
      | tr -d '"' \
      | awk '{print $1}'
}

# quartus_qsf_version <COMPILATION_INPUT|.qsf|.qpf> — extract the raw
# LAST_QUARTUS_VERSION value from the resolved .qsf. Echoes it; exits non-zero
# if the file or the assignment is missing.
quartus_qsf_version() {
    local INPUT="${1:-}" QSF VER
    if [[ -z "${INPUT}" ]]; then
        echo "detect_quartus_version: no input file argument" >&2
        return 1
    fi
    case "${INPUT}" in
        *.qpf) QSF="${INPUT%.qpf}.qsf" ;;
        *.qsf) QSF="${INPUT}" ;;
        *)     QSF="${INPUT}.qsf" ;;
    esac
    if [[ ! -f "${QSF}" ]]; then
        echo "detect_quartus_version: qsf not found: ${QSF}" >&2
        return 1
    fi
    VER=$(quartus_qsf_version_from_text < "${QSF}")
    if [[ -z "${VER}" ]]; then
        echo "detect_quartus_version: no LAST_QUARTUS_VERSION in ${QSF}" >&2
        return 1
    fi
    echo "${VER}"
}

# CLI entry point — preserves the original behaviour for release.yml /
# unstable_release.yml callers (QUARTUS_NATIVE_OVERRIDE env + file arg).
detect_quartus_version_main() {
    if [[ -n "${QUARTUS_NATIVE_OVERRIDE:-}" && "${QUARTUS_NATIVE_OVERRIDE}" != "auto" ]]; then
        echo "${QUARTUS_NATIVE_OVERRIDE}"
        return 0
    fi
    local VER
    VER=$(quartus_qsf_version "${1:-}")
    quartus_map_std "${VER}"
}

# Run the CLI only when executed, not when sourced (:- guards keep this
# safe under the caller's `set -u` when sourced).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    detect_quartus_version_main "$@"
fi
