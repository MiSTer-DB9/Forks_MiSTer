# shellcheck shell=bash
# Baseline fetch for the timing/ALM regression gate. Sourced by quartus_build.sh
# (build leg). Downloads the previous good build's <rev>_db9_metrics.json release
# asset so quartus_metrics.py can compare the fresh build against it.
#
# The *store* side needs no helper: build_leg stages dist/<rev>_db9_metrics.json
# and the publishers' `dist/*` glob ships it as a release asset automatically
# (stable: per-immutable-release; unstable: --clobber onto unstable-builds).
#
# Downstream-only (Forks_MiSTer) — no MiSTer-DB9 markers.
#
# Contract: GITHUB_TOKEN + gh + GITHUB_REPOSITORY in env (build leg already has
# them). retry() is optional — used when the caller sourced retry.sh.

# _gh_retry -- <gh args...>  : use retry.sh's retry() if present, else plain gh.
_gh_retry() {
    [[ "${1:-}" == "--" ]] && shift
    if command -v retry >/dev/null 2>&1; then
        retry -- gh "$@"
    else
        gh "$@"
    fi
}

# fetch_prior_metrics <LABEL> <rev> <dest_file>
#   LABEL = STABLE | UNSTABLE
#   Writes the prior metrics JSON to <dest_file> and returns 0 on success.
#   Returns 1 when there is no prior baseline (first build, or asset absent) —
#   the caller then skips the gate and just stores this build's metrics.
fetch_prior_metrics() {
    local label="$1" rev="$2" dest="$3"
    # Honour the documented "return 1 -> skip the gate" contract rather than
    # hard-exiting via ${VAR:?...} (CI always sets it; a local rerun may not).
    local repo="${GITHUB_REPOSITORY:-}"
    if [[ -z "${repo}" ]]; then
        echo "GITHUB_REPOSITORY not set — baseline fetch skipped (gate disabled this run)."
        return 1
    fi
    local asset="${rev}_db9_metrics.json"
    local tag tmpd

    if [[ "${label}" == "STABLE" ]]; then
        # Newest stable/<branch>/ release. Branch = the ref the leg built on
        # (Actions sets GITHUB_REF_NAME to MAIN_BRANCH for the stable workflow).
        local branch="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)}"
        local prefix="stable/${branch}/"
        tag="$(_gh_retry -- release list --repo "${repo}" --limit 100 --exclude-drafts \
                 --json tagName,createdAt \
                 --jq "[.[] | select(.tagName | startswith(\"${prefix}\"))] | sort_by(.createdAt) | reverse | .[0].tagName" \
               2>/dev/null || true)"
        [[ -z "${tag}" || "${tag}" == "null" ]] && return 1
    else
        tag="unstable-builds"
    fi

    tmpd="$(mktemp -d)"
    if _gh_retry -- release download "${tag}" --repo "${repo}" \
            --pattern "${asset}" --dir "${tmpd}" >/dev/null 2>&1 \
        && [[ -f "${tmpd}/${asset}" ]]; then
        mv "${tmpd}/${asset}" "${dest}"
        rm -rf "${tmpd}"
        echo "Baseline metrics for ${rev} fetched from ${tag}."
        return 0
    fi
    rm -rf "${tmpd}"
    echo "No baseline metrics for ${rev} (tag ${tag:-<none>}) — gate skipped, storing this build as baseline."
    return 1
}
