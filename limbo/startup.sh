#!/bin/bash
# LOOHP/Limbo Startup Script
# https://github.com/tensacraft/eggs

readonly CONTAINER_DIR="/home/container"
readonly BUILD_CACHE="${CONTAINER_DIR}/.build_cache"
readonly PLUGINS_DIR="${CONTAINER_DIR}/plugins"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

is_true() { case "${1,,}" in true|1|yes) return 0 ;; *) return 1 ;; esac }

# ── Version resolution ────────────────────────────────────────────────

get_latest_version() {
    local artifact="$1"
    local metadata_url="https://repo.loohpjames.com/repository/com/loohp/${artifact}/maven-metadata-local.xml"
    local metadata
    metadata=$(curl -fsSL "$metadata_url" 2>/dev/null) || { log_err "Failed to fetch ${artifact} metadata"; return 1; }
    
    local latest
    latest=$(echo "$metadata" | grep -o '<latest>[^<]*' | sed 's/<latest>//' | head -1)
    [ -z "$latest" ] && { log_err "Failed to parse ${artifact} metadata"; return 1; }
    
    echo "$latest"
}

resolve_version() {
    local version="$1"
    if [ "${version,,}" = "latest" ]; then
        echo "$version"
    else
        echo "$version"
    fi
}

get_actual_version() {
    local version="$1"
    if [ "${version,,}" = "latest" ]; then
        echo "$2"
    else
        echo "$1"
    fi
}

# ── Limbo ───────────────────────────────────────────────────────────────

get_limbo_jar_url() {
    local version="$1"
    local artifact="Limbo"
    echo "https://repo.loohpjames.com/repository/com/loohp/${artifact}/${version}/${artifact}-${version}.jar"
}

maybe_update_limbo() {
    local requested_version="${LIMBO_VERSION:-latest}"
    local resolved_version
    resolved_version=$(resolve_version "$requested_version")
    
    local actual_version="$resolved_version"
    if [ "$resolved_version" = "latest" ]; then
        local latest
        latest=$(get_latest_version "Limbo") || exit 1
        actual_version="$latest"
    fi
    
    local build_id="limbo-${actual_version}"
    local jar_url
    jar_url=$(get_limbo_jar_url "$actual_version")
    
    if [ -f "${BUILD_CACHE}" ] && [ -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ]; then
        local cached
        cached=$(cat "${BUILD_CACHE}")
        if [ "${cached}" = "${build_id}" ]; then
            log "Limbo: up to date (${actual_version})."; return 0
        fi
        log "Limbo: updating ${cached} → ${actual_version}"
    else
        log "Limbo: first download (${actual_version})"
    fi
    
    cd "${CONTAINER_DIR}" || exit 1
    [ -f "${SERVER_JARFILE}" ] && cp "${SERVER_JARFILE}" "${SERVER_JARFILE}.bak"
    
    if curl -fsSL --progress-bar -o "${SERVER_JARFILE}" "${jar_url}"; then
        echo "${build_id}" > "${BUILD_CACHE}"
        rm -f "${SERVER_JARFILE}.bak"
        log "Limbo: downloaded ${SERVER_JARFILE}"
    else
        log_err "Limbo: download failed!"
        [ -f "${SERVER_JARFILE}.bak" ] && mv "${SERVER_JARFILE}.bak" "${SERVER_JARFILE}" && log "Limbo: JAR restored from backup."
        exit 1
    fi
}

# ── ViaLimbo ────────────────────────────────────────────────────────────

readonly VIALIMBO_CACHE="${CONTAINER_DIR}/.vialimbo_cache"
readonly VIALIMBO_JAR="${PLUGINS_DIR}/ViaLimbo.jar"

get_vialimbo_jar_url() {
    local version="$1"
    local artifact="ViaLimbo"
    echo "https://repo.loohpjames.com/repository/com/loohp/${artifact}/${version}/${artifact}-${version}.jar"
}

maybe_update_vialimbo() {
    mkdir -p "${PLUGINS_DIR}"
    
    local requested_version="${VIALIMBO_VERSION:-latest}"
    local resolved_version
    resolved_version=$(resolve_version "$requested_version")
    
    local actual_version="$resolved_version"
    if [ "$resolved_version" = "latest" ]; then
        local latest
        latest=$(get_latest_version "ViaLimbo") || { log "ViaLimbo: failed to fetch latest version, skipping."; return 0; }
        actual_version="$latest"
    fi
    
    local jar_url
    jar_url=$(get_vialimbo_jar_url "$actual_version")
    
    local cached
    cached=$(cat "${VIALIMBO_CACHE}" 2>/dev/null || echo "")
    if [ "${cached}" = "${actual_version}" ] && [ -f "${VIALIMBO_JAR}" ]; then
        log "ViaLimbo: up to date (${actual_version})."; return 0
    fi
    
    log "ViaLimbo: downloading ${actual_version}..."
    if curl -fsSL --progress-bar -o "${VIALIMBO_JAR}" "${jar_url}"; then
        echo "${actual_version}" > "${VIALIMBO_CACHE}"
        log "ViaLimbo: downloaded."
    else
        log "ViaLimbo: download failed, skipping."
    fi
}

# ── Server properties ───────────────────────────────────────────────────

download_default_properties() {
    local cfg="${CONTAINER_DIR}/server.properties"
    [ -f "$cfg" ] && return 0
    
    log "Downloading default server.properties..."
    if curl -fsSL -o "$cfg" "https://raw.githubusercontent.com/LOOHP/Limbo/master/src/main/resources/server.properties"; then
        log "server.properties downloaded."
    else
        log_err "Failed to download server.properties, using minimal config."
        cat > "$cfg" << 'EOF'
server-name=A Limbo Server
server-port=25565
server-ip=
max-players=20
motd=Welcome to Limbo!
EOF
    fi
}

configure_forwarding() {
    [ -z "${VELOCITY_SECRET}" ] && return 0
    
    local cfg="${CONTAINER_DIR}/server.properties"
    download_default_properties
    
    if grep -q "^forwarding-secrets=" "$cfg"; then
        sed -i "s|^forwarding-secrets=.*|forwarding-secrets=${VELOCITY_SECRET}|" "$cfg"
    else
        echo "forwarding-secrets=${VELOCITY_SECRET}" >> "$cfg"
    fi
    log "Forwarding: secret written to server.properties."
}

# ── Main ───────────────────────────────────────────────────────────────

download_default_properties

if is_true "${AUTO_UPDATE}"; then
    log "AUTO_UPDATE: checking Limbo..."
    maybe_update_limbo
else
    log "AUTO_UPDATE: disabled."
    [ ! -f "${CONTAINER_DIR}/${SERVER_JARFILE}" ] && { log "JAR not found — downloading..."; maybe_update_limbo; }
fi

if is_true "${VIALIMBO_ENABLED}"; then
    maybe_update_vialimbo
fi

configure_forwarding

log "Starting LOOHP/Limbo ${LIMBO_VERSION}..."
cd "${CONTAINER_DIR}" || exit 1
exec java "$@" -jar "${SERVER_JARFILE}" --nogui
