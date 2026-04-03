#!/bin/bash
# LOOHP/Limbo Startup Script
# https://github.com/tensacraft/eggs

readonly CONTAINER_DIR="/home/container"
readonly CACHE_DIR="${CONTAINER_DIR}/.cache"
readonly PLUGINS_DIR="${CONTAINER_DIR}/plugins"
readonly SHA_CACHE="${CACHE_DIR}/startup_sha"
readonly SCRIPT_SUBPATH="limbo/startup.sh"

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

# ── Modrinth API (Limbo) ────────────────────────────────────────────

# Fetch Limbo from Modrinth API
# Sets: DOWNLOAD_URL, BUILD_ID
fetch_limbo() {
    local mc_version="${MINECRAFT_VERSION:-latest}"
    local api_url="https://api.modrinth.com/v2/project/limbo-server/version"

    if [ "${mc_version,,}" != "latest" ]; then
        api_url="${api_url}?game_versions=%5B%22${mc_version}%22%5D"
    fi

    log "Fetching Limbo from Modrinth (MC ${mc_version})..."
    local json
    json=$(curl -fsSL "$api_url" 2>/dev/null) || { log_err "Modrinth API unavailable"; return 1; }

    DOWNLOAD_URL=$(echo "$json" | grep -o '"url":"https://cdn\.modrinth\.com/[^"]*\.jar"' | head -1 \
        | sed 's/.*"url":"\([^"]*\)".*/\1/')
    [ -z "$DOWNLOAD_URL" ] && { log_err "No Limbo JAR found on Modrinth for MC ${mc_version}"; return 1; }

    local version_number
    version_number=$(echo "$json" | grep -o '"version_number":"[^"]*"' | head -1 \
        | sed 's/.*"version_number":"\([^"]*\)".*/\1/')

    local filename
    filename=$(echo "$json" | grep -o '"filename":"Limbo[^"]*\.jar"' | head -1 \
        | sed 's/.*"filename":"\([^"]*\)".*/\1/')

    BUILD_ID="limbo-${version_number:-unknown}"
    log "Limbo: ${version_number} (${filename})"
}

# ── Limbo update ─────────────────────────────────────────────────────

maybe_update_limbo() {
    fetch_limbo || exit 1

    local cache_file="${CACHE_DIR}/limbo_build"
    if [ -f "$cache_file" ] && [ -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ]; then
        local cached
        cached=$(cat "$cache_file")
        if [ "$cached" = "$BUILD_ID" ]; then
            log "Limbo: up to date (${BUILD_ID})."
            return 0
        fi
        log "Limbo: updating ${cached} -> ${BUILD_ID}"
    else
        log "Limbo: first download (${BUILD_ID})"
    fi

    cd "${CONTAINER_DIR}" || exit 1
    [ -f "${SERVER_JARFILE}" ] && cp "${SERVER_JARFILE}" "${SERVER_JARFILE}.bak"

    if curl -fsSL --progress-bar -o "${SERVER_JARFILE}" "${DOWNLOAD_URL}"; then
        echo "$BUILD_ID" > "$cache_file"
        rm -f "${SERVER_JARFILE}.bak"
        log "Limbo: downloaded ${SERVER_JARFILE}"
    else
        log_err "Limbo: download failed!"
        [ -f "${SERVER_JARFILE}.bak" ] && mv "${SERVER_JARFILE}.bak" "${SERVER_JARFILE}" && log "Limbo: JAR restored from backup."
        exit 1
    fi
}

# ── ViaLimbo (Jenkins) ──────────────────────────────────────────────

maybe_update_vialimbo() {
    mkdir -p "${PLUGINS_DIR}"

    local version="${VIALIMBO_VERSION:-latest}"
    local jar_path="${PLUGINS_DIR}/ViaLimbo.jar"

    if [ "${version,,}" = "latest" ]; then
        log "Fetching latest ViaLimbo from Jenkins..."
        local json
        json=$(curl -fsSL "https://ci.loohpjames.com/job/ViaLimbo/lastSuccessfulBuild/api/json" 2>/dev/null) \
            || { log "ViaLimbo: Jenkins unavailable, skipping."; return 0; }

        local jar_name
        jar_name=$(echo "$json" | grep -o '"fileName":"ViaLimbo[^"]*\.jar"' | head -1 | sed 's/.*"fileName":"\([^"]*\)".*/\1/')
        [ -z "$jar_name" ] && { log "ViaLimbo: no JAR found, skipping."; return 0; }

        local build_num
        build_num=$(echo "$json" | grep -o '"number":[0-9]*' | head -1 | sed 's/.*://')

        local rel_path
        rel_path=$(echo "$json" | grep -o '"relativePath":"target/ViaLimbo[^"]*"' | head -1 | sed 's/.*"relativePath":"\([^"]*\)".*/\1/')
        [ -z "$rel_path" ] && rel_path="target/${jar_name}"

        local download_url="https://ci.loohpjames.com/job/ViaLimbo/${build_num}/artifact/${rel_path}"
        local cache_id="vialimbo-${build_num}"

        local cache_file="${CACHE_DIR}/vialimbo_build"
        local cached
        cached=$(cat "$cache_file" 2>/dev/null || echo "")
        if [ "$cached" = "$cache_id" ] && [ -f "$jar_path" ]; then
            log "ViaLimbo: up to date (build #${build_num})."; return 0
        fi

        log "ViaLimbo: downloading build #${build_num}..."
        if curl -fsSL --progress-bar -o "$jar_path" "$download_url"; then
            echo "$cache_id" > "$cache_file"
            log "ViaLimbo: downloaded."
        else
            log "ViaLimbo: download failed, skipping."
        fi
    else
        local download_url="https://repo.loohpjames.com/repository/com/loohp/ViaLimbo/${version}/ViaLimbo-${version}.jar"
        local cache_id="vialimbo-${version}"

        local cache_file="${CACHE_DIR}/vialimbo_build"
        local cached
        cached=$(cat "$cache_file" 2>/dev/null || echo "")
        if [ "$cached" = "$cache_id" ] && [ -f "$jar_path" ]; then
            log "ViaLimbo: up to date (${version})."; return 0
        fi

        log "ViaLimbo: downloading version ${version}..."
        if curl -fsSL --progress-bar -o "$jar_path" "$download_url"; then
            echo "$cache_id" > "$cache_file"
            log "ViaLimbo: downloaded."
        else
            log "ViaLimbo: download failed, skipping."
        fi
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

if is_true "${AUTO_UPDATE}"; then
    log "AUTO_UPDATE: checking Limbo..."
    maybe_update_limbo
else
    log "AUTO_UPDATE: disabled."
    [ ! -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ] && { log "JAR not found, downloading..."; maybe_update_limbo; }
fi

if is_true "${VIALIMBO_ENABLED}"; then
    maybe_update_vialimbo
fi

log "Starting LOOHP/Limbo (Minecraft ${MINECRAFT_VERSION:-latest})..."
cd "${CONTAINER_DIR}" || exit 1
exec java "$@" -jar "${SERVER_JARFILE}" --nogui
