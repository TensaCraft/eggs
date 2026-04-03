#!/bin/bash
# NanoLimbo Startup Script
# https://github.com/tensacraft/eggs

readonly CONTAINER_DIR="/home/container"
readonly BUILD_CACHE="${CONTAINER_DIR}/.build_cache"
readonly SHA_CACHE="${CONTAINER_DIR}/.startup_sha"
readonly SCRIPT_SUBPATH="limbo/startup.sh"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

is_true() { case "${1,,}" in true|1|yes) return 0 ;; *) return 1 ;; esac }
json_get() {
    local field="$1"
    grep -o "\"${field}\":[ ]*\"[^\"]*\"" | sed 's/.*"'"${field}"'":[ ]*"\([^"]*\)".*/\1/'
}

self_update() {
    local remote_sha
    remote_sha=$(curl -fsSL "https://api.github.com/repos/tensacraft/eggs/contents/${SCRIPT_SUBPATH}" \
        | json_get "sha" 2>/dev/null)
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

# ── Build (NanoLimbo GitHub Releases) ────────────────────────────────

resolve_build() {
    local resp
    resp=$(curl -fsSL "https://api.github.com/repos/Nan1t/NanoLimbo/releases/latest") \
        || { log_err "Failed to fetch NanoLimbo releases"; exit 1; }

    BUILD_NUMBER=$(echo "$resp" | json_get "tag_name")
    BUILD_ID="nanolimbo-${BUILD_NUMBER}"
    DOWNLOAD_URL=$(echo "$resp" | grep -o '"browser_download_url":"[^"]*"' | grep '\.jar' | sed 's/.*"browser_download_url":"\([^"]*\)".*/\1/' | sed 's/\\\//g')
    [ -z "$DOWNLOAD_URL" ] && { log_err "JAR not found in NanoLimbo releases"; exit 1; }
}

# ── Download ──────────────────────────────────────────────────────────

maybe_update() {
    resolve_build

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

# ── ViaLimbo ─────────────────────────────────────────────────────────

readonly PLUGINS_DIR="${CONTAINER_DIR}/plugins"
readonly VIALIMBO_CACHE="${CONTAINER_DIR}/.vialimbo_cache"
readonly VIALIMBO_JAR="${PLUGINS_DIR}/ViaLimbo.jar"

maybe_update_vialimbo() {
    mkdir -p "${PLUGINS_DIR}"

    local resp
    resp=$(curl -fsSL "https://api.github.com/repos/4drian3d/ViaLimbo/releases/latest") \
        || { log "ViaLimbo: GitHub unavailable, skipping."; return 0; }

    local tag; tag=$(echo "$resp" | json_get "tag_name")
    local url; url=$(echo "$resp" | grep -o '"browser_download_url":"[^"]*"' | grep '\.jar' | sed 's/.*"browser_download_url":"\([^"]*\)".*/\1/' | sed 's/\\\//g')
    [ -z "$url" ] && { log "ViaLimbo: JAR not found in releases, skipping."; return 0; }

    local cached; cached=$(cat "${VIALIMBO_CACHE}" 2>/dev/null || echo "")
    if [ "$cached" = "$tag" ] && [ -f "${VIALIMBO_JAR}" ]; then
        log "ViaLimbo: already up to date (${tag})."; return 0
    fi

    log "ViaLimbo: downloading ${tag}..."
    if curl -fsSL --progress-bar -o "${VIALIMBO_JAR}" "${url}"; then
        echo "$tag" > "${VIALIMBO_CACHE}"
        log "ViaLimbo: downloaded."
    else
        log "ViaLimbo: download failed, skipping."
    fi
}

# ── Forwarding secret ────────────────────────────────────────────────

configure_forwarding() {
    [ -z "${VELOCITY_SECRET}" ] && return 0
    local cfg="${CONTAINER_DIR}/server.properties"
    [ ! -f "$cfg" ] && touch "$cfg"
    if grep -q "^forwarding-secrets=" "$cfg"; then
        sed -i "s|^forwarding-secrets=.*|forwarding-secrets=${VELOCITY_SECRET}|" "$cfg"
    else
        echo "forwarding-secrets=${VELOCITY_SECRET}" >> "$cfg"
    fi
    log "Forwarding: secret written to server.properties."
}

# ── Main ─────────────────────────────────────────────────────────────

if is_true "${AUTO_UPDATE}"; then
    log "AUTO_UPDATE: checking NanoLimbo..."
    maybe_update
else
    log "AUTO_UPDATE: disabled."
    [ ! -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ] && { log "JAR not found — downloading..."; maybe_update; }
fi

if is_true "${VIALIMBO_ENABLED}"; then
    maybe_update_vialimbo
fi

configure_forwarding

log "Starting NanoLimbo..."
cd "${CONTAINER_DIR}" || exit 1
exec java "$@" -jar "${SERVER_JARFILE}"
