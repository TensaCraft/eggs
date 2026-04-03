#!/bin/bash
# Velocity Startup Script
# https://github.com/tensacraft/eggs

readonly CONTAINER_DIR="/home/container"
readonly BUILD_CACHE="${CONTAINER_DIR}/.build_cache"
readonly SHA_CACHE="${CONTAINER_DIR}/.startup_sha"
readonly SCRIPT_SUBPATH="velocity/startup.sh"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

is_true() { case "${1,,}" in true|1|yes) return 0 ;; *) return 1 ;; esac }
json_get() { jq -r "$1" 2>/dev/null; }

check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log "jq not found. Attempting to install..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y jq >/dev/null 2>&1 && return 0
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache jq >/dev/null 2>&1 && return 0
        fi
        log_err "jq is required but not available. Please install it manually."
        return 1
    fi
    return 0
}
check_jq || exit 1

# ── Self-update ───────────────────────────────────────────────────────

self_update() {
    local remote_sha
    remote_sha=$(curl -fsSL "https://api.github.com/repos/tensacraft/eggs/contents/${SCRIPT_SUBPATH}" \
        | json_get ".sha" 2>/dev/null)
    [ -z "$remote_sha" ] && { log "Self-update: GitHub unavailable, skipping."; return 0; }

    local current_sha
    current_sha=$(cat "$SHA_CACHE" 2>/dev/null || echo "")
    if [ "$current_sha" = "$remote_sha" ]; then
        log "Self-update: up to date (${remote_sha:0:7})."; return 0
    fi

    log "Self-update: ${current_sha:0:7} → ${remote_sha:0:7}"
    if curl -fsSL "https://raw.githubusercontent.com/tensacraft/eggs/main/${SCRIPT_SUBPATH}" \
            -o "${CONTAINER_DIR}/startup.sh.new"; then
        mv "${CONTAINER_DIR}/startup.sh.new" "${CONTAINER_DIR}/startup.sh"
        chmod +x "${CONTAINER_DIR}/startup.sh"
        echo "$remote_sha" > "$SHA_CACHE"
        log "Self-update: updated. Restarting..."
        exec bash "${CONTAINER_DIR}/startup.sh" "$@"
    else
        log "Self-update: failed, continuing with current version."
    fi
}

self_update "$@"

# ── Version ───────────────────────────────────────────────────────────

resolve_latest_version() {
    curl -fsSL "https://api.papermc.io/v3/projects/velocity" | json_get ".versions[-1]"
}

# ── Build ─────────────────────────────────────────────────────────────

resolve_build() {
    local version="$1"
    local resp
    resp=$(curl -fsSL "https://api.papermc.io/v3/projects/velocity/versions/${version}/builds/latest") \
        || { log_err "Failed to fetch Velocity build for ${version}"; exit 1; }
    BUILD_NUMBER=$(echo "$resp" | json_get ".build")
    local jar; jar=$(echo "$resp" | json_get ".downloads.application.name")
    BUILD_ID="velocity-${version}-${BUILD_NUMBER}"
    DOWNLOAD_URL="https://api.papermc.io/v3/projects/velocity/versions/${version}/builds/${BUILD_NUMBER}/downloads/${jar}"
}

# ── Download ──────────────────────────────────────────────────────────

maybe_update() {
    if [ "${VELOCITY_VERSION,,}" = "latest" ]; then
        VELOCITY_VERSION=$(resolve_latest_version)
        log "Latest Velocity version: ${VELOCITY_VERSION}"
    fi

    resolve_build "${VELOCITY_VERSION}"

    if [ -f "${BUILD_CACHE}" ] && [ -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ]; then
        local cached; cached=$(cat "${BUILD_CACHE}")
        if [ "${cached}" = "${BUILD_ID}" ]; then
            log "Already up to date: ${BUILD_ID}."; return 0
        fi
        log "Updating: ${cached} → ${BUILD_ID}"
    else
        log "First download: ${BUILD_ID}"
    fi

    cd "${CONTAINER_DIR}" || exit 1
    [ -f "${SERVER_JARFILE}" ] && cp "${SERVER_JARFILE}" "${SERVER_JARFILE}.bak"

    if curl -fsSL --progress-bar -o "${SERVER_JARFILE}" "${DOWNLOAD_URL}"; then
        echo "${BUILD_ID}" > "${BUILD_CACHE}"
        rm -f "${SERVER_JARFILE}.bak"
        log "Downloaded: ${SERVER_JARFILE}"
    else
        log_err "Download failed!"
        [ -f "${SERVER_JARFILE}.bak" ] && mv "${SERVER_JARFILE}.bak" "${SERVER_JARFILE}" && log "JAR restored from backup."
        exit 1
    fi
}

# ── Forwarding secret ────────────────────────────────────────────────

configure_forwarding() {
    [ -z "${VELOCITY_SECRET}" ] && return 0
    echo "${VELOCITY_SECRET}" > "${CONTAINER_DIR}/forwarding.secret"
    log "Forwarding: secret written to forwarding.secret."
}

# ── Main ─────────────────────────────────────────────────────────────

if is_true "${AUTO_UPDATE}"; then
    log "AUTO_UPDATE: checking Velocity..."
    maybe_update
else
    log "AUTO_UPDATE: disabled."
    [ ! -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ] && { log "JAR not found — downloading..."; maybe_update; }
fi

configure_forwarding

log "Starting Velocity ${VELOCITY_VERSION}..."
cd "${CONTAINER_DIR}" || exit 1
exec java "$@" -jar "${SERVER_JARFILE}"
