#!/bin/bash
# MohistMC Youer Startup Script
# https://github.com/tensacraft/eggs

readonly CONTAINER_DIR="/home/container"
readonly CACHE_DIR="${CONTAINER_DIR}/.cache"
readonly SHA_CACHE="${CACHE_DIR}/startup_sha"
readonly SCRIPT_SUBPATH="youer/startup.sh"
readonly API_BASE="https://api.mohistmc.com"
readonly PROJECT_NAME="youer"
readonly DEFAULT_PROJECT_VERSION="1.21.1"
PROJECT_VERSION="${YOUER_VERSION:-${DEFAULT_PROJECT_VERSION}}"

mkdir -p "${CACHE_DIR}"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

is_true() { case "${1,,}" in true|1|yes) return 0 ;; *) return 1 ;; esac; }

self_update() {
    local remote_sha
    remote_sha=$(curl -fsSL "https://api.github.com/repos/tensacraft/eggs/contents/${SCRIPT_SUBPATH}" 2>/dev/null \
        | grep -o '"sha":"[^"]*"' | head -1 | sed 's/.*"sha":"\([^"]*\)".*/\1/')
    [ -z "$remote_sha" ] && { log "Self-update: GitHub unavailable, skipping."; return 0; }

    local current_sha
    current_sha=$(cat "$SHA_CACHE" 2>/dev/null || echo "")
    if [ "$current_sha" = "$remote_sha" ]; then
        log "Self-update: up to date (${remote_sha:0:7})."
        return 0
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

validate_project_version() {
    if [[ ! "$PROJECT_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_err "Invalid YOUER_VERSION: ${PROJECT_VERSION}"
        exit 1
    fi
}

resolve_version() {
    if [ "${PROJECT_VERSION,,}" = "latest" ]; then
        local resp
        resp=$(curl -fsSL "${API_BASE}/project/${PROJECT_NAME}/versions" 2>/dev/null) \
            || { log_err "Failed to fetch Youer versions"; exit 1; }

        PROJECT_VERSION=$(echo "$resp" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
            | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        [ -z "$PROJECT_VERSION" ] && { log_err "No Youer version found"; exit 1; }

        log "Resolved latest Youer version: ${PROJECT_VERSION}"
    fi

    validate_project_version
}

resolve_build() {
    local resp
    resp=$(curl -fsSL "${API_BASE}/project/${PROJECT_NAME}/${PROJECT_VERSION}/builds" 2>/dev/null) \
        || { log_err "Failed to fetch Youer builds for ${PROJECT_VERSION}"; exit 1; }

    BUILD_NUMBER=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | sed 's/.*://')
    [ -z "$BUILD_NUMBER" ] && { log_err "No build number found for Youer ${PROJECT_VERSION}"; exit 1; }

    NEOFORGE_VERSION=$(echo "$resp" | grep -o '"neoforge_version":"[^"]*"' | head -1 \
        | sed 's/.*"neoforge_version":"\([^"]*\)".*/\1/')
    COMMIT_HASH=$(echo "$resp" | grep -o '"hash":"[^"]*"' | head -1 \
        | sed 's/.*"hash":"\([^"]*\)".*/\1/')

    DOWNLOAD_URL="${API_BASE}/project/${PROJECT_NAME}/${PROJECT_VERSION}/builds/${BUILD_NUMBER}/download"
    BUILD_ID="${PROJECT_NAME}-${PROJECT_VERSION}-${BUILD_NUMBER}"

    if [ -n "$NEOFORGE_VERSION" ] && [ -n "$COMMIT_HASH" ]; then
        log "Resolved build: ${BUILD_ID} (NeoForge ${NEOFORGE_VERSION}, commit ${COMMIT_HASH:0:7})"
    elif [ -n "$NEOFORGE_VERSION" ]; then
        log "Resolved build: ${BUILD_ID} (NeoForge ${NEOFORGE_VERSION})"
    else
        log "Resolved build: ${BUILD_ID}"
    fi
}

maybe_update() {
    resolve_build

    local cache_file="${CACHE_DIR}/build_id"
    if [ -f "$cache_file" ] && [ -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ]; then
        local cached
        cached=$(cat "$cache_file")
        if [ "$cached" = "$BUILD_ID" ]; then
            log "Already up to date: ${BUILD_ID}."
            return 0
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

if is_true "${AUTO_UPDATE}"; then
    resolve_version
    log "AUTO_UPDATE: checking Youer ${PROJECT_VERSION}..."
    maybe_update
else
    log "AUTO_UPDATE: disabled."
    [ ! -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ] && { resolve_version; log "JAR not found, downloading Youer ${PROJECT_VERSION}..."; maybe_update; }
fi

log "Starting Youer ${PROJECT_VERSION}..."
cd "${CONTAINER_DIR}" || exit 1
exec java "$@" -jar "${SERVER_JARFILE}" nogui
