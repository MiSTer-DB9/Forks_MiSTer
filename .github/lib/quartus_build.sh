# shellcheck shell=bash
# Shared Quartus build core for the stable (release.sh) and unstable
# (unstable_release.sh) channels. fork_ci_template/.github/quartus_build.sh
# symlinks here; setup_cicd.sh propagates the dereferenced file to forks via
# `cp -rL` (same as retry.sh / compute_source_hash.sh / rerere_train.sh).
#
# Sourced, not executed. Single source of truth for the Quartus build so an
# invocation fix (LD_PRELOAD libudev, --mac-address, apt deps, libpng/ncurses
# shims) lands in the stable and unstable channels at once.
#
# Contract — the caller MUST, before invoking build_cores:
#   - have sourced retry.sh (retry() used by the ubuntu:24.04 docker pull)
#   - set the CORE_NAME / COMPILATION_INPUT / COMPILATION_OUTPUT arrays
#     (the setup_cicd.sh placeholder-expanded values stay in the callers; this
#     lib carries no placeholder token so setup_cicd.sh must not sed it)
#   - have run resolve_quartus_env (sets/validates QUARTUS_* + GITHUB_TOKEN)
#   - declare a `UPLOAD_FILES=()` array (build_cores appends to it in place)
#   - have LM_LICENSE_FILE set by materialize_quartus_license.sh (the license
#     is materialized at run time, never persisted into the toolchain tree)
#   - run from the repo checkout root (notify_error.sh is ./.github/...)

# Native Quartus *Standard* build. quartus-toolchain resolves the
# toolchain (GH Actions cache -> private ghcr tarball artifact -> native
# provision) and exports QUARTUS_NATIVE_HOME = /opt/intelFPGA/<ver> on the
# runner. The compile then runs in a stock ubuntu:24.04 container — ONLY so
# `--mac-address` can put the FlexLM node-lock MAC on the container's eth0 —
# with the validated X/glib/font libs apt'd per build.
# QUARTUS_NATIVE_VERSION (resolved std key) and QUARTUS_NATIVE_HOME are both
# required. GITHUB_TOKEN is needed by every gh release call in both callers.

# Timing/ALM regression baseline fetch (fetch_prior_metrics). Same .github dir;
# propagated to forks by the same `cp -rL fork_ci_template/.github` setup_cicd
# uses (the symlink dereferences to a real file in each fork's .github/).
# shellcheck source=timing_baseline.sh
source "$(dirname "${BASH_SOURCE[0]}")/timing_baseline.sh"

resolve_quartus_env() {
    QUARTUS_NATIVE_VERSION="${QUARTUS_NATIVE_VERSION:-}"
    QUARTUS_NATIVE_HOME="${QUARTUS_NATIVE_HOME:-}"
    if [[ -z "${QUARTUS_NATIVE_VERSION}" ]]; then
        echo "::error::QUARTUS_NATIVE_VERSION not set — native Quartus Standard is the only build path"
        exit 1
    fi
    if [[ -z "${QUARTUS_NATIVE_HOME}" ]]; then
        echo "::error::QUARTUS_NATIVE_HOME not set — quartus-toolchain must export it"
        exit 1
    fi
    GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"
}

# gh sanity + upstream case-mismatch shims (Linux-only failures, each gated on
# the specific filename pair so it's a no-op for every other fork). Track via
# https://github.com/MiSTer-devel/<fork>/issues so this list can shrink.
#   - Arcade-TaitoSystemSJ_MiSTer: rtl/index.qip references "Mc68705p3.v" but
#     the file is committed as rtl/mc68705p3.v.
quartus_build_preflight() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "::error::gh CLI missing — cannot publish release"
        exit 1
    fi
    if [[ -f rtl/mc68705p3.v && ! -e rtl/Mc68705p3.v ]]; then
        ln -s mc68705p3.v rtl/Mc68705p3.v
    fi
}

# build_cores <LABEL> <RBF_INFIX> -- <notify-recipient>...
#
#   LABEL      STABLE | UNSTABLE  — notify_error.sh reason word
#   RBF_INFIX  asset-name middle  — stable: <YYYYMMDD>_<sha7>
#                                   unstable: unstable_<YYYYMMDD_HHMM>_<sha7>
#                                   (its last _-token is the sha7 used in the
#                                   notify reason)
#   after --   maintainer emails  — forwarded verbatim to notify_error.sh
#
# Asset name <Core>_<RBF_INFIX>_DB9[.<ext>]: the trailing _DB9 marks every
# fork-built asset for end-user provenance. Main_MiSTer ships bin/MiSTer with
# no extension; ${COMPILATION_OUTPUT##*.} returns the whole path → drop the
# dot suffix so cp lands on the right file.

# notify_error.sh wrapper. Relies on bash dynamic scope to see build_cores'
# LABEL / SHA7 / NOTIFY_ARGS / i locals at call time; notify_error.sh exits 1
# so a failed compile still aborts the run.
_notify_build_fail() {
    ./.github/notify_error.sh "${LABEL} COMPILATION ERROR (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}"
}

# --- Timing/ALM regression gate (dynamic-scope on build_cores' loop locals) ---
# Quartus emits an RBF even when timing FAILS, so a fork-side change can ship a
# timing-regressed (e.g. video-glitched) bitstream — this happened on
# ao486_USERIO2. We compare each build's per-clock worst slack against the last
# good build (regression-relative, because MiSTer cores ship benign negative
# slack) and reseed the fitter to recover a timing regression.

# Cannot recover the regression -> per-channel policy.
#   STABLE  : abort the leg (notify_error.sh exits 1) -> ship no RBF for this core
#   UNSTABLE: ship the best-of-N seed but alert (it's the merge canary)
_db9_timing_fail() {
    if [[ "${LABEL}" == "STABLE" ]]; then
        ./.github/notify_error.sh "STABLE TIMING REGRESSION (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}"
    else
        NOTIFY_LEVEL=warn ./.github/notify_error.sh "UNSTABLE TIMING REGRESSION (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}" || true
    fi
}

# Reseed the fitter up to SEED_MAX times. Ship the first seed that VERIFIABLY
# closes the regression; if none does, keep the least-bad (highest worst-case
# setup slack) build for the UNSTABLE best-of-N fallback. The chosen build is
# promoted into COMPILATION_OUTPUT + METRICS_JSON.
_db9_reseed_loop() {
    [[ "${OUTDIR}" == "." || -z "${OUTDIR}" ]] && { _db9_timing_fail; return; }
    local seed rc cur best_slack recovered=0
    cp "${QSF}" "${QSF}.db9orig"
    cp "${COMPILATION_OUTPUT[i]}" "/tmp/${MKEY}.db9best.rbf"
    cp "${METRICS_JSON}" "/tmp/${MKEY}.db9best.json"
    # `|| best_slack=nan`: bare cmd-sub assignments propagate set -e on failure;
    # tolerate an unreadable metrics file instead of aborting the whole leg.
    best_slack="$(python3 ./.github/quartus_metrics.py worst "${METRICS_JSON}")" || best_slack="nan"
    for (( seed = 2; seed <= 1 + SEED_MAX; seed++ )); do
        echo "Timing regression on ${REV}: retrying fit with SEED ${seed} (attempt $(( seed - 1 ))/${SEED_MAX})..."
        # Reproducible seeds (not $RANDOM). Keep exactly one SEED line: drop any
        # existing assignment from the original qsf, then append ours.
        grep -ivE '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+SEED[[:space:]]' \
            "${QSF}.db9orig" > "${QSF}" || true
        echo "set_global_assignment -name SEED ${seed}" >> "${QSF}"
        rm -rf "${QDIR}/db" "${QDIR}/incremental_db" "${OUTDIR}"
        if ! "${QRT_RUN[@]}" bash -c "${QRT_CMD}"; then
            echo "::warning::SEED ${seed} compile failed for ${REV}; keeping best so far."
            continue
        fi
        [[ -f "${COMPILATION_OUTPUT[i]}" ]] || { echo "::warning::SEED ${seed} produced no RBF for ${REV}."; continue; }
        DB9_SEED="${seed}" python3 ./.github/quartus_metrics.py parse "${OUTDIR}" "${REV}" > "${METRICS_JSON}" || true
        rc=0
        python3 ./.github/quartus_metrics.py compare "${BASE_JSON}" "${METRICS_JSON}" --margin-ns "${TMARGIN}" --risk-floor-ns "${TRISK}" || rc=$?
        cur="$(python3 ./.github/quartus_metrics.py worst "${METRICS_JSON}")" || cur="nan"
        # Only a VERIFIED compare counts as recovery: 0 = clean, 4 = ALM-only
        # (both mean no timing regression on this seed). rc=3 = still regressed;
        # rc=1/2 = compare could not run (crash / usage) → unverified, so do NOT
        # treat it as recovered — keep retrying and ultimately fail closed.
        if (( rc == 0 || rc == 4 )); then
            echo "SEED ${seed} closed the timing regression on ${REV} (worst setup slack ${cur}ns)."
            # Promote the recovering build UNCONDITIONALLY — it is the one we ship.
            # Its worst_setup can be <= an earlier still-regressed seed's (the
            # binding path may be a clock that was never the regression), so a
            # best_slack-gated promote would silently ship the regressed build.
            cp "${COMPILATION_OUTPUT[i]}" "/tmp/${MKEY}.db9best.rbf"
            cp "${METRICS_JSON}" "/tmp/${MKEY}.db9best.json"
            recovered=1
            break
        fi
        # Still regressed: track the least-bad build for the UNSTABLE best-of-N
        # fallback. A numeric slack always beats a no-data ('nan') incumbent.
        if [[ "${cur}" != "nan" ]] \
           && { [[ "${best_slack}" == "nan" ]] || awk "BEGIN{exit !(${cur} > ${best_slack})}" 2>/dev/null; }; then
            best_slack="${cur}"
            cp "${COMPILATION_OUTPUT[i]}" "/tmp/${MKEY}.db9best.rbf"
            cp "${METRICS_JSON}" "/tmp/${MKEY}.db9best.json"
        fi
    done
    mv -f "${QSF}.db9orig" "${QSF}"   # restore (workspace is discarded anyway)
    mkdir -p "${OUTDIR}"              # a failed final seed left OUTDIR rm'd; recreate for the cp
    cp "/tmp/${MKEY}.db9best.rbf" "${COMPILATION_OUTPUT[i]}"
    cp "/tmp/${MKEY}.db9best.json" "${METRICS_JSON}"
    if (( ! recovered )); then
        echo "::warning::No SEED within ${SEED_MAX} attempts closed the timing regression on ${REV} (best worst-setup ${best_slack}ns)."
        _db9_timing_fail
    fi
}

# --- Fitter routing / fit-failure seed retry (dynamic-scope on build_cores) ---
# A HARD fit/route failure produces NO RBF, so the compile aborts at the
# `_notify_build_fail` call BEFORE the timing/ALM gate (_db9_seed_gate) — the
# timing reseed loop above never sees it. Quartus itself says a different fitter
# seed (or Aggressive Routability) may route the design, and in practice a
# routing-congestion failure on one seed routes on another (PSX unstable: the
# DualSDRAM sibling leg routed while the main leg congested out).
#
# POLICY SPLIT — this is NOT the timing reseed:
#   * A real fit/route failure (no RBF) MUST be retried — the alternative is
#     shipping nothing. So this path is DEFAULT-ON, governed by its own knob
#     FIT_RETRY_MAX (default 3); set it to 0 to disable for a core.
#   * A timing regression (RBF exists, just degraded) only REPORTS by default —
#     _db9_seed_gate / _db9_reseed_loop, gated on the separate opt-in
#     SEED_RETRY_MAX (default 0). The two knobs are independent on purpose.
# So when the failed compile's log carries the fit/route signature, retry the
# compile with successive seeds until one yields an RBF. Distinct from
# _db9_reseed_loop, which recovers a TIMING regression on a build that already
# routed; this recovers a build that failed to route AT ALL.

# True iff the captured compile log shows a fitter routing/fit failure (NOT a
# generic Quartus error a reseed can't fix — syntax, missing file, license).
#   11802  = Can't fit design in device
#   170143 = Final fitting attempt was unsuccessful
#   188026 = Fitter failed to route (explicitly suggests changing the seed)
#   16618  = Fitter routing phase terminated due to routing congestion
_db9_fit_signature() {
    grep -qE 'Error \(11802\):|Error \(170143\):|Critical Warning \(188026\):|Warning \(16618\):' "$1"
}

# Reseed-and-recompile until a seed routes. Returns 0 once an RBF appears (the
# qsf is restored, output left in place for the metrics parse), 1 if every seed
# still failed to route. Seeds are reproducible (2..1+FIT_MAX), matching
# _db9_reseed_loop; like it, the winning seed is NOT persisted to the committed
# qsf (the CI workspace is ephemeral — every rebuild re-runs the search).
_db9_fit_retry_loop() {
    [[ "${OUTDIR}" == "." || -z "${OUTDIR}" || ! -f "${QSF}" ]] && {
        echo "::warning::Fit/route failure on ${REV} but reseed unavailable (qsf=${QSF}, outdir=${OUTDIR})."
        return 1
    }
    local seed
    cp "${QSF}" "${QSF}.db9orig"
    for (( seed = 2; seed <= 1 + FIT_MAX; seed++ )); do
        echo "Fit/route failure on ${REV}: retrying with SEED ${seed} (attempt $(( seed - 1 ))/${FIT_MAX})..."
        # Keep exactly one SEED line: drop any from the original qsf, append ours.
        grep -ivE '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+SEED[[:space:]]' \
            "${QSF}.db9orig" > "${QSF}" || true
        echo "set_global_assignment -name SEED ${seed}" >> "${QSF}"
        rm -rf "${QDIR}/db" "${QDIR}/incremental_db" "${OUTDIR}"
        "${QRT_RUN[@]}" bash -c "${QRT_CMD}" || true
        if [[ -f "${COMPILATION_OUTPUT[i]}" ]]; then
            echo "SEED ${seed} routed ${REV} successfully."
            mv -f "${QSF}.db9orig" "${QSF}"
            return 0
        fi
        echo "::warning::SEED ${seed} still failed to route ${REV}."
    done
    mv -f "${QSF}.db9orig" "${QSF}"
    mkdir -p "${OUTDIR}"   # last failed seed rm'd it; recreate so callers don't trip
    return 1
}

# Compare the fresh build against the fetched baseline and dispatch.
#
# Seed search is OPT-IN per core via the SEED_RETRY_MAX repo variable
# (default 0 = OFF). When OFF (the default) the gate is REPORT-ONLY: a worse
# timing or ALM picture is reported to the maintainer over Telegram
# (notify_error.sh, swallowed with `|| true` so its `exit 1` never fails the
# leg) and the fitter is NEVER reseeded. Set vars.SEED_RETRY_MAX to a positive
# N on a specific fork to turn the reseed-and-recover behaviour on for that core.
_db9_seed_gate() {
    local rc=0
    python3 ./.github/quartus_metrics.py compare "${BASE_JSON}" "${METRICS_JSON}" --margin-ns "${TMARGIN}" --risk-floor-ns "${TRISK}" || rc=$?

    # Report-only mode (seed search disabled — the default). Inform, never fail,
    # never reseed.
    if (( SEED_MAX <= 0 )); then
        case "${rc}" in
            3)  NOTIFY_LEVEL=warn ./.github/notify_error.sh "${LABEL} TIMING REGRESSION — report only, build NOT failed, seed search off (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}" || true ;;
            4)  NOTIFY_LEVEL=warn ./.github/notify_error.sh "${LABEL} ALM REGRESSION — report only, build NOT failed, seed search off (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}" || true ;;
            *)  : ;;  # 0 = clean; anything else = couldn't compare, stay silent
        esac
        return 0
    fi

    # Seed search enabled (SEED_MAX > 0): reseed on a timing regression, warn on
    # ALM-only.
    case "${rc}" in
        3)  # timing regression — reseed if we can, else apply policy
            if [[ -f "${QSF}" ]]; then
                _db9_reseed_loop
            else
                echo "::warning::Timing regression on ${REV} but reseed unavailable (qsf=${QSF})."
                _db9_timing_fail
            fi
            ;;
        4)  # ALM-only regression — warn, never retry (reseed won't move synth ALMs)
            NOTIFY_LEVEL=warn ./.github/notify_error.sh "${LABEL} ALM REGRESSION (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}" || true
            ;;
        *)  : ;;  # 0 = clean; anything else = couldn't compare, don't block
    esac
}

build_cores() {
    local LABEL="$1" RBF_INFIX="$2"
    shift 2
    [[ "${1:-}" == "--" ]] && shift
    local NOTIFY_ARGS=("$@")
    local SHA7="${RBF_INFIX##*_}"

    local i FILE_EXT RBF_NAME
    for i in "${!CORE_NAME[@]}"; do
        FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
        if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
            RBF_NAME="${CORE_NAME[i]}_${RBF_INFIX}_DB9"
        else
            RBF_NAME="${CORE_NAME[i]}_${RBF_INFIX}_DB9.${FILE_EXT}"
        fi
        echo
        echo "Building '${RBF_NAME}'..."
        # Run Quartus *Standard* in a container ONLY so `--mac-address` puts
        # the license node-lock MAC on the container's eth0 (FlexLM hostid =
        # its netns primary iface); host NIC untouched so Azure anti-spoof
        # never severs the runner. HOME=/tmp = writable, host-config-free (no
        # stray quartus2.ini). Quartus 17's bundled 2017 libudev.so.1
        # segfaults against glibc 2.39 with no in-container udevd (FlexLM
        # hostid scan), so LD_PRELOAD the modern system libudev (from the
        # per-build apt).
        local LIC_DIR NODELOCK_MAC QRT_CMD APT_STEP=''
        LIC_DIR="$(dirname "${LM_LICENSE_FILE}")"
        # Re-derive the node-lock MAC from the license file itself (the
        # single source of truth — no $GITHUB_ENV/sidecar to leak it in a
        # later step's env: log group). Already ::add-mask::ed by
        # materialize_quartus_license.sh; re-mask defensively. Never echo.
        NODELOCK_MAC="$(grep -ioE 'HOSTID=[0-9A-Fa-f]{12}' "${LM_LICENSE_FILE}" \
            | head -1 | sed 's/.*=//' | tr 'A-Z' 'a-z' \
            | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/')"
        if [[ ! "${NODELOCK_MAC}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            echo "::error::could not derive node-lock MAC from license"; exit 1
        fi
        echo "::add-mask::${NODELOCK_MAC}"

        local QRT_RUN=( docker run --rm
            --mac-address "${NODELOCK_MAC}"
            -v "$(pwd):/project" -w /project
            -v "${LIC_DIR}:${LIC_DIR}:ro"
            -e "LM_LICENSE_FILE=${LM_LICENSE_FILE}"
            -e "ALTERA_LICENSE_FILE=${LM_LICENSE_FILE}"
            -e "HOME=/tmp"
            -e "HOST_UID=$(id -u)"
            -e "HOST_GID=$(id -g)"
            -e "QIN=${COMPILATION_INPUT[i]}" )

        # Provisioned/cached tree on the runner, stock ubuntu:24.04, the
        # validated X/glib/font libs apt'd per build. libstdc++6/zlib1g are in
        # the base; libpng/libncurses shimmed in-tree by
        # --fix-libpng/--fix-libncurses. 'locales' + locale-gen below carry over
        # the en_US.UTF-8 baking from the deleted quartus-native.Dockerfile:
        # qenv.sh itself hard-exports LANG=en_US.UTF-8, so merely *generating*
        # the locale is enough to silence its 'setlocale: LC_CTYPE' warning
        # (cosmetic - RBF is locale-agnostic, compute_source_hash pins LC_ALL=C
        # - but pollutes logs the rerun_transient classifier scans). No explicit
        # export / -e / update-locale: a docker-run non-login 'bash -c' never
        # sources /etc/default/locale (update-locale is a no-op here) and
        # setting LANG/LC_ALL before locale-gen runs makes apt/perl in the
        # install phase emit the very warning we're killing.
        local QRT_PKGS="locales libglib2.0-0t64 libsm6 libice6 libxext6 libxft2 libxrender1 libxtst6 libxi6 libx11-6 libxcb1 libfontconfig1 libfreetype6 libudev1"
        retry -- docker pull ubuntu:24.04
        QRT_RUN+=( -v "${QUARTUS_NATIVE_HOME}:${QUARTUS_NATIVE_HOME}:ro"
                   -e "QRT_PKGS=${QRT_PKGS}"
                   -e "QNH=${QUARTUS_NATIVE_HOME}"
                   ubuntu:24.04 )
        APT_STEP='export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ${QRT_PKGS}
        locale-gen en_US.UTF-8'

        # QNH defaults to QUARTUS_NATIVE_HOME; LD_PRELOAD points at the modern
        # system libudev installed by the per-build apt.
        QRT_CMD="set -e
        ${APT_STEP}
        : \"\${QNH:=\${QUARTUS_NATIVE_HOME}}\"
        export LD_PRELOAD=\"\${LD_PRELOAD:-\$(ls /usr/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libudev.so.1 2>/dev/null | head -1)}\"
        rc=0; \"\${QNH}/quartus/bin/quartus_sh\" --flow compile \"\${QIN}\" || rc=\$?
        # Quartus ran as root in-container; hand the bind-mounted artifacts back
        # to the host runner uid so the host-side gate/reseed (rm, cp of
        # db/incremental_db/output_files) don't die 'Permission denied'.
        chown -R \${HOST_UID}:\${HOST_GID} /project 2>/dev/null || true
        exit \$rc"

        # Derive the build-tree paths up front — BOTH the fit-failure seed retry
        # (at the compile below) and the timing/ALM gate (after) need them.
        # REV   = Quartus revision = RBF / .qsf / report basename.
        # QDIR  = dir the project tree lives in ("." for root cores, e.g.
        #         "quartus" for subdir-qpf cores like Arcade-Cave) — the .qsf and
        #         db/incremental_db sit here, NOT necessarily at the repo root.
        # MKEY  = per-variant asset key. Keep it distinct across sibling variants
        #         that share one revision/output: the three GBA variants all emit
        #         output_files/GBA.rbf but have distinct CORE_NAME, so keying the
        #         <key>_db9_metrics.json baseline on REV would collide on the
        #         shared unstable-builds release. CORE_NAME (= RELEASE_CORE_NAME)
        #         is unique per variant; for normal cores it equals REV.
        local REV QDIR OUTDIR QSF MKEY METRICS_JSON BASE_JSON
        REV="${COMPILATION_OUTPUT[i]##*/}"; REV="${REV%.*}"
        OUTDIR="$(dirname "${COMPILATION_OUTPUT[i]}")"
        QDIR="$(dirname "${OUTDIR}")"
        QSF="${QDIR}/${REV}.qsf"
        MKEY="${CORE_NAME[i]}"
        METRICS_JSON="/tmp/${MKEY}_db9_metrics.json"
        BASE_JSON="/tmp/${MKEY}_db9_baseline.json"
        # Two INDEPENDENT knobs (see _db9_fit_retry_loop's policy note):
        #  SEED_MAX = timing-regression reseed — OPT-IN, default 0 (report-only).
        #  FIT_MAX  = hard fit/route-failure reseed — DEFAULT-ON, default 3 (a
        #             real fit failure ships no RBF, so it MUST be retried; set
        #             FIT_RETRY_MAX=0 to disable for a specific core).
        local SEED_MAX="${SEED_RETRY_MAX:-0}" TMARGIN="${TIMING_MARGIN_NS:-0.5}" TRISK="${TIMING_RISK_FLOOR_NS:-1.0}"
        local FIT_MAX="${FIT_RETRY_MAX:-3}"

        # attempt 0: unmodified qsf — byte-identical to the pre-gate build.
        # Capture the compile output (still streamed live via tee) so a hard
        # fit/route failure — which produces NO RBF and so never reaches the
        # timing gate — can be told apart from other Quartus errors and recovered
        # by a fitter-seed search. PIPESTATUS[0] read before any other command so
        # the tee pipeline's docker rc is intact; set +e/-e brackets the pipe so
        # the caller's `set -e` doesn't abort before we inspect the rc.
        local _cclog _crc=0
        _cclog="$(mktemp)"
        set +e
        "${QRT_RUN[@]}" bash -c "${QRT_CMD}" 2>&1 | tee "${_cclog}"
        _crc="${PIPESTATUS[0]}"
        set -e
        if (( _crc != 0 )); then
            if (( FIT_MAX > 0 )) && _db9_fit_signature "${_cclog}"; then
                echo "::warning::${LABEL} fit/route congestion on ${CORE_NAME[i]} @ ${SHA7} — seed search (FIT_RETRY_MAX=${FIT_MAX})."
                _db9_fit_retry_loop || _notify_build_fail
            else
                _notify_build_fail
            fi
        fi
        rm -f "${_cclog}"

        if [[ ! -f "${COMPILATION_OUTPUT[i]}" ]]; then
            echo "::error::Build succeeded but ${COMPILATION_OUTPUT[i]} missing"
            exit 1
        fi

        # Timing/ALM regression gate + SEED retry. Parse this build's metrics,
        # fetch the last good build's baseline; on a timing regression reseed the
        # fitter (full recompile) to recover. Happy path adds only one gh
        # download + a cheap parse — zero extra compiles unless a regression hits.

        python3 ./.github/quartus_metrics.py parse "${OUTDIR}" "${REV}" > "${METRICS_JSON}" || true

        # ALM-utilization advisory (level, not delta): high utilization marks a
        # core as fitter-seed-sensitive — some seeds ship a glitch, some don't,
        # with no STA signal to tell them apart. Warn so a maintainer pins a
        # runtime-verified SEED. Advisory only — never blocks, reseeds, or emails.
        local UTIL_PCT UTIL_WARN="${ALM_UTIL_WARN_PCT:-80}"
        UTIL_PCT="$(python3 ./.github/quartus_metrics.py util "${METRICS_JSON}" 2>/dev/null)" || UTIL_PCT="nan"
        if [[ "${UTIL_PCT}" != "nan" ]] && awk "BEGIN{exit !(${UTIL_PCT} >= ${UTIL_WARN})}" 2>/dev/null; then
            echo "::warning::${CORE_NAME[i]} ALM utilization ${UTIL_PCT}% >= ${UTIL_WARN}% — fitter-seed-sensitive; pin a runtime-verified SEED in the committed qsf."
        fi

        if fetch_prior_metrics "${LABEL}" "${MKEY}" "${BASE_JSON}"; then
            _db9_seed_gate
        fi

        cp "${COMPILATION_OUTPUT[i]}" "/tmp/${RBF_NAME}"
        # Stage the chosen build's metrics next to the RBF; the publishers'
        # `dist/*` glob ships it as the <core>_db9_metrics.json baseline asset.
        UPLOAD_FILES+=("/tmp/${RBF_NAME}" "${METRICS_JSON}")
    done
}

# build_leg <LABEL> <RBF_INFIX> <core> <input> <output> -- <notify-recipient>...
#
# One matrix leg's full build: set the single-element CORE_NAME/COMPILATION_*
# arrays build_cores consumes, materialise the secret, compile, stage the RBF
# into dist/ for the publish fan-in. Shared by release_build.sh and
# unstable_build.sh — they differ only in LABEL and RBF_INFIX. The locals are
# visible to build_cores via bash dynamic scope.
#
# `git submodule update` is .gitmodules-guarded: an unconditional update on a
# submodule-less tree (most MiSTer cores) is pure overhead and a no-op anyway.
build_leg() {
    local LABEL="$1" RBF_INFIX="$2"
    local CORE_NAME=("$3") COMPILATION_INPUT=("$4") COMPILATION_OUTPUT=("$5")
    shift 5
    [[ "${1:-}" == "--" ]] && shift

    resolve_quartus_env
    if [[ -f .gitmodules ]]; then
        git submodule update --init --recursive
    fi
    ./.github/materialize_secret.sh
    quartus_build_preflight

    local UPLOAD_FILES=()
    build_cores "${LABEL}" "${RBF_INFIX}" -- "$@"

    mkdir -p dist
    cp "${UPLOAD_FILES[@]}" dist/
    echo
    echo "Staged for publish:"
    ls -1 dist/
}
