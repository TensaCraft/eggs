#!/bin/bash
# Minecraft Java (Paper/Folia/Purpur) Startup Script
# https://github.com/tensacraft/eggs

readonly CONTAINER_DIR="/home/container"
readonly CACHE_DIR="${CONTAINER_DIR}/.cache"
readonly SHA_CACHE="${CACHE_DIR}/startup_sha"
readonly SCRIPT_SUBPATH="paper/startup.sh"

mkdir -p "${CACHE_DIR}"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

is_true() { case "${1,,}" in true|1|yes) return 0 ;; *) return 1 ;; esac; }

# ── Self-update ──────────────────────────────────────────────────────

self_update() {
    local remote_sha
    remote_sha=$(curl -fsSL "https://api.github.com/repos/tensacraft/eggs/contents/${SCRIPT_SUBPATH}" 2>/dev/null \
        | grep -o '"sha":"[^"]*"' | head -1 | sed 's/.*"sha":"\([^"]*\)".*/\1/')
    [ -z "$remote_sha" ] && { log "Self-update: GitHub unavailable, skipping."; return 0; }

    local current_sha
    current_sha=$(cat "$SHA_CACHE" 2>/dev/null || echo "")
    if [ "$current_sha" = "$remote_sha" ]; then
        log "Self-update: up to date (${remote_sha:0:7})."; return 0
    fi

    log "Self-update: ${current_sha:0:7} -> ${remote_sha:0:7}"
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

# ── Version resolution ───────────────────────────────────────────────

resolve_latest_version() {
    local core="${CORE_TYPE,,}"
    local project="$core"

    case "$core" in
        paper|folia)
            local resp
            resp=$(curl -fsSL "https://fill.papermc.io/v3/projects/${project}" 2>/dev/null) \
                || { log_err "Failed to fetch ${project} versions"; exit 1; }
            # v3 returns versions grouped: {"versions":{"1.21":["1.21.11",...],..}}
            # First item in first array is the latest stable version
            echo "$resp" | grep -o '\["[0-9][^]]*\]' | head -1 | grep -o '"[^"]*"' | head -1 | tr -d '"'
            ;;
        purpur)
            local resp
            resp=$(curl -fsSL "https://api.purpurmc.org/v2/purpur" 2>/dev/null) \
                || { log_err "Failed to fetch Purpur versions"; exit 1; }
            echo "$resp" | grep -o '"versions":\[[^]]*\]' | grep -o '"[^"]*"' | tail -1 | tr -d '"'
            ;;
        *) log_err "Unknown CORE_TYPE: ${CORE_TYPE}"; exit 1 ;;
    esac
}

# ── Build resolution ─────────────────────────────────────────────────

resolve_build() {
    local version="$1"
    local core="${CORE_TYPE,,}"

    case "$core" in
        paper|folia)
            local resp
            resp=$(curl -fsSL "https://fill.papermc.io/v3/projects/${core}/versions/${version}/builds/latest" 2>/dev/null) \
                || { log_err "Failed to fetch build for ${core} ${version}"; exit 1; }

            BUILD_NUMBER=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | sed 's/.*://')
            [ -z "$BUILD_NUMBER" ] && { log_err "No build number found for ${core} ${version}"; exit 1; }

            DOWNLOAD_URL=$(echo "$resp" | grep -o '"url":"https://fill-data[^"]*"' | head -1 | sed 's/.*"url":"\([^"]*\)".*/\1/')
            [ -z "$DOWNLOAD_URL" ] && { log_err "No download URL found for ${core} ${version}"; exit 1; }

            BUILD_ID="${core}-${version}-${BUILD_NUMBER}"
            ;;
        purpur)
            local resp
            resp=$(curl -fsSL "https://api.purpurmc.org/v2/purpur/${version}/latest" 2>/dev/null) \
                || { log_err "Failed to fetch Purpur build for ${version}"; exit 1; }

            BUILD_NUMBER=$(echo "$resp" | grep -o '"build":"[^"]*"' | head -1 | sed 's/.*"build":"\([^"]*\)".*/\1/')
            [ -z "$BUILD_NUMBER" ] && { log_err "No Purpur build number found for ${version}"; exit 1; }

            BUILD_ID="purpur-${version}-${BUILD_NUMBER}"
            DOWNLOAD_URL="https://api.purpurmc.org/v2/purpur/${version}/${BUILD_NUMBER}/download"
            ;;
        *) log_err "Unknown CORE_TYPE: ${CORE_TYPE}"; exit 1 ;;
    esac
}

# ── Download ─────────────────────────────────────────────────────────

maybe_update() {
    if [ "${MINECRAFT_VERSION,,}" = "latest" ]; then
        MINECRAFT_VERSION=$(resolve_latest_version)
        [ -z "$MINECRAFT_VERSION" ] && { log_err "Failed to resolve latest version"; exit 1; }
        log "Latest version: ${MINECRAFT_VERSION}"
    fi

    resolve_build "${MINECRAFT_VERSION}"

    local cache_file="${CACHE_DIR}/build_id"
    if [ -f "$cache_file" ] && [ -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ]; then
        local cached
        cached=$(cat "$cache_file")
        if [ "$cached" = "$BUILD_ID" ]; then
            log "Already up to date: ${BUILD_ID}."; return 0
        fi
        log "Updating: ${cached} -> ${BUILD_ID}"
    else
        log "First download: ${BUILD_ID}"
    fi

    cd "${CONTAINER_DIR}" || exit 1
    [ -f "${SERVER_JARFILE}" ] && cp "${SERVER_JARFILE}" "${SERVER_JARFILE}.bak"

    if curl -fsSL --progress-bar -o "${SERVER_JARFILE}" "${DOWNLOAD_URL}"; then
        echo "${BUILD_ID}" > "$cache_file"
        rm -f "${SERVER_JARFILE}.bak"
        log "Downloaded: ${SERVER_JARFILE}"
    else
        log_err "Download failed!"
        [ -f "${SERVER_JARFILE}.bak" ] && mv "${SERVER_JARFILE}.bak" "${SERVER_JARFILE}" && log "JAR restored from backup."
        exit 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

if is_true "${AUTO_UPDATE}"; then
    log "AUTO_UPDATE: checking (${CORE_TYPE})..."
    maybe_update
else
    log "AUTO_UPDATE: disabled."
    [ ! -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ] && { log "JAR not found, downloading..."; maybe_update; }
fi

log "Starting ${CORE_TYPE} ${MINECRAFT_VERSION}..."
cd "${CONTAINER_DIR}" || exit 1
exec java "$@" -jar "${SERVER_JARFILE}" nogui
