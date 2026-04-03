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

# ── Jenkins helpers ──────────────────────────────────────────────────

# Get latest successful Limbo build from Jenkins
# Sets: JAR_NAME, BUILD_NUMBER, DOWNLOAD_URL
get_latest_limbo_build() {
    log "Fetching latest Limbo build from Jenkins..."
    local api_url="https://ci.loohpjames.com/job/Limbo/lastSuccessfulBuild/api/json"
    local json
    json=$(curl -fsSL "$api_url" 2>/dev/null) || { log_err "Failed to fetch Limbo from Jenkins"; return 1; }

    JAR_NAME=$(echo "$json" | grep -o '"fileName":"Limbo[^"]*\.jar"' | head -1 | sed 's/.*"fileName":"\([^"]*\)".*/\1/')
    [ -z "$JAR_NAME" ] && { log_err "No Limbo JAR found in Jenkins response"; return 1; }

    BUILD_NUMBER=$(echo "$json" | grep -o '"number":[0-9]*' | head -1 | sed 's/.*://')
    [ -z "$BUILD_NUMBER" ] && { log_err "No build number found"; return 1; }

    local rel_path
    rel_path=$(echo "$json" | grep -o '"relativePath":"target/Limbo[^"]*"' | head -1 | sed 's/.*"relativePath":"\([^"]*\)".*/\1/')
    [ -z "$rel_path" ] && rel_path="target/${JAR_NAME}"

    DOWNLOAD_URL="https://ci.loohpjames.com/job/Limbo/${BUILD_NUMBER}/artifact/${rel_path}"
    log "Latest Limbo: build #${BUILD_NUMBER}, ${JAR_NAME}"
}

# Find Limbo build for a specific Minecraft version by scanning Jenkins builds
# The JAR filename format is: Limbo-{LimboVer}-{MCVer}.jar
# Sets: JAR_NAME, BUILD_NUMBER, DOWNLOAD_URL
get_limbo_build_for_mc_version() {
    local mc_version="$1"
    log "Searching Jenkins for Limbo build supporting Minecraft ${mc_version}..."

    local json
    json=$(curl -fsSL "https://ci.loohpjames.com/job/Limbo/api/json?depth=1" 2>/dev/null) \
        || { log_err "Failed to fetch Limbo builds list from Jenkins"; return 1; }

    # Extract (fileName, number) pairs from builds JSON
    local pairs
    pairs=$(echo "$json" | tr ',' '\n' | tr '{' '\n' \
        | grep -E '"(number|fileName)"' \
        | grep -E '"number":[0-9]+|"fileName":"Limbo[^"]*\.jar"')

    # Find first JAR matching the MC version suffix
    JAR_NAME=""
    BUILD_NUMBER=""
    local prev_line=""
    while IFS= read -r line; do
        if echo "$line" | grep -q '"fileName"'; then
            prev_line="$line"
        elif echo "$line" | grep -q '"number"'; then
            if echo "$prev_line" | grep -q "\"fileName\":\"Limbo[^\"]*-${mc_version}\\.jar\""; then
                JAR_NAME=$(echo "$prev_line" | sed 's/.*"fileName":"\([^"]*\)".*/\1/')
                BUILD_NUMBER=$(echo "$line" | grep -o '[0-9]*')
                break
            fi
        fi
    done <<< "$pairs"

    if [ -z "$JAR_NAME" ] || [ -z "$BUILD_NUMBER" ]; then
        log_err "No Limbo build found for Minecraft ${mc_version}"
        log_err "Available MC versions from Jenkins:"
        echo "$pairs" | grep '"fileName"' | sed 's/.*-\([0-9][^"]*\)\.jar".*/  \1/' | sort -uV
        return 1
    fi

    DOWNLOAD_URL="https://ci.loohpjames.com/job/Limbo/${BUILD_NUMBER}/artifact/target/${JAR_NAME}"
    log "Found: Limbo build #${BUILD_NUMBER}, ${JAR_NAME} (Minecraft ${mc_version})"
}

# ── Limbo update ─────────────────────────────────────────────────────

maybe_update_limbo() {
    local mc_version="${MINECRAFT_VERSION:-latest}"

    if [ "${mc_version,,}" = "latest" ]; then
        get_latest_limbo_build || exit 1
    else
        get_limbo_build_for_mc_version "$mc_version" || exit 1
    fi

    local build_id="limbo-${BUILD_NUMBER}"

    local cache_file="${CACHE_DIR}/limbo_build"
    if [ -f "$cache_file" ] && [ -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ]; then
        local cached
        cached=$(cat "$cache_file")
        if [ "$cached" = "$build_id" ]; then
            log "Limbo: up to date (build #${BUILD_NUMBER})."
            return 0
        fi
        log "Limbo: updating ${cached} -> ${build_id}"
    else
        log "Limbo: first download (build #${BUILD_NUMBER})"
    fi

    cd "${CONTAINER_DIR}" || exit 1
    [ -f "${SERVER_JARFILE}" ] && cp "${SERVER_JARFILE}" "${SERVER_JARFILE}.bak"

    if curl -fsSL --progress-bar -o "${SERVER_JARFILE}" "${DOWNLOAD_URL}"; then
        echo "$build_id" > "$cache_file"
        rm -f "${SERVER_JARFILE}.bak"
        log "Limbo: downloaded ${SERVER_JARFILE}"
    else
        log_err "Limbo: download failed!"
        [ -f "${SERVER_JARFILE}.bak" ] && mv "${SERVER_JARFILE}.bak" "${SERVER_JARFILE}" && log "Limbo: JAR restored from backup."
        exit 1
    fi
}

# ── ViaLimbo ─────────────────────────────────────────────────────────

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
        # Specific version from Maven repo
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
