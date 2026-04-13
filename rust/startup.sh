#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-tensacraft/eggs}"
SCRIPT_SUBPATH="rust/startup.sh"
CONFIG_DEFAULTS_SUBPATH="rust/config.defaults.sh"

RUNTIME_WIPE_CRON_SCHEDULES=()
RUNTIME_WIPE_MAPS=()
RUNTIME_WIPE_REMOVE_PATTERNS=()
RUNTIME_WIPE_IGNORE_PATTERNS=()
RUNTIME_CLEAN_FILES_ON_RESTART=()
RUNTIME_CLEAN_IGNORE_PATTERNS=()
START_COMMAND=()
START_COMMAND_STRING=""

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

split_by() {
  local input="$1"
  local delimiter="$2"
  local -n out_ref="$3"
  IFS="$delimiter" read -r -a out_ref <<<"$input"
}

var_is_array() {
  local name="$1"
  local declaration
  declaration="$(declare -p "$name" 2>/dev/null || true)"
  [[ "$declaration" == "declare -a"* ]]
}

container_dir() {
  printf '%s' "${CONTAINER_DIR:-/home/container}"
}

cache_dir() {
  printf '%s/.cache' "$(container_dir)"
}

cache_file() {
  local name="$1"
  printf '%s/%s' "$(cache_dir)" "$name"
}

github_raw_url() {
  local subpath="$1"
  printf 'https://raw.githubusercontent.com/%s/main/%s' "$REPO_SLUG" "$subpath"
}

github_contents_url() {
  local subpath="$1"
  printf 'https://api.github.com/repos/%s/contents/%s' "$REPO_SLUG" "$subpath"
}

ensure_cache_dir() {
  mkdir -p "$(cache_dir)"
}

github_file_sha() {
  local subpath="$1"
  curl -fsSL "$(github_contents_url "$subpath")" 2>/dev/null \
    | grep -o '"sha":"[^"]*"' \
    | head -n1 \
    | sed 's/.*"sha":"\([^"]*\)".*/\1/'
}

download_github_file() {
  local subpath="$1"
  local destination="$2"
  curl -fsSL "$(github_raw_url "$subpath")" -o "$destination"
}

maybe_update_managed_file() {
  local subpath="$1"
  local destination="$2"
  local sha_cache_name="$3"
  local destination_mode="${4:-644}"

  ensure_cache_dir

  local remote_sha
  remote_sha="$(github_file_sha "$subpath")"
  if [[ -z "$remote_sha" ]]; then
    log "Managed update skipped for ${subpath}: GitHub unavailable."
    return 1
  fi

  local sha_path
  sha_path="$(cache_file "$sha_cache_name")"

  local current_sha=""
  if [[ -f "$sha_path" ]]; then
    current_sha="$(cat "$sha_path")"
  fi

  if [[ "$current_sha" == "$remote_sha" && -f "$destination" ]]; then
    return 2
  fi

  local temp_path="${destination}.new"
  if ! download_github_file "$subpath" "$temp_path"; then
    rm -f "$temp_path"
    log "Managed update failed for ${subpath}; keeping current file."
    return 1
  fi

  mv "$temp_path" "$destination"
  chmod "$destination_mode" "$destination"
  printf '%s' "$remote_sha" > "$sha_path"
  return 0
}

bootstrap_user_config() {
  local destination
  destination="$(container_dir)/config.sh"
  if [[ -f "$destination" ]]; then
    return
  fi

  local defaults_path
  defaults_path="$(container_dir)/config.defaults.sh"

  if [[ ! -f "$defaults_path" ]]; then
    log "config.sh bootstrap skipped: config.defaults.sh is missing."
    return
  fi

  log "config.sh missing; bootstrapping from local managed defaults."
  if cp "$defaults_path" "$destination"; then
    chmod 644 "$destination"
  else
    rm -f "$destination"
    log "Bootstrap of config.sh failed; continuing without a user config."
  fi
}

self_update_startup() {
  local destination
  destination="$(container_dir)/startup.sh"
  mkdir -p "$(container_dir)"

  if maybe_update_managed_file "$SCRIPT_SUBPATH" "$destination" "startup_sha" 755; then
    log "startup.sh updated from GitHub. Restarting into the new version."
    exec bash "$destination" "$@"
  fi
}

update_managed_defaults() {
  local destination
  destination="$(container_dir)/config.defaults.sh"
  mkdir -p "$(container_dir)"

  if maybe_update_managed_file "$CONFIG_DEFAULTS_SUBPATH" "$destination" "config_defaults_sha" 644; then
    log "config.defaults.sh updated from GitHub."
  fi
}

normalize_list() {
  local out_name="$1"
  shift

  local -n out_ref="$out_name"
  out_ref=()

  local item
  for item in "$@"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    out_ref+=("$item")
  done
}

parse_scalar_list() {
  local input="$1"
  local delimiter="$2"
  local out_name="$3"

  local parts=()
  if [[ -n "$input" ]]; then
    split_by "$input" "$delimiter" parts
  fi
  normalize_list "$out_name" "${parts[@]}"
}

resolve_string_or_array() {
  local out_name="$1"
  local variable_name="$2"
  local delimiter="$3"
  shift 3
  local defaults=("$@")

  local resolved=()
  if var_is_array "$variable_name"; then
    local -n source_ref="$variable_name"
    resolved=("${source_ref[@]}")
  else
    local scalar_value="${!variable_name:-}"
    if [[ -n "$scalar_value" ]]; then
      parse_scalar_list "$scalar_value" "$delimiter" resolved
    else
      resolved=("${defaults[@]}")
    fi
  fi

  normalize_list "$out_name" "${resolved[@]}"
}

default_wipe_patterns() {
  local out_name="$1"
  local identity="${SERVER_IDENTITY:-rust}"
  local defaults=(
    "server/${identity}/*.map"
    "server/${identity}/*.sav"
    "server/${identity}/*.sav.*"
    "server/${identity}/player.deaths*.db*"
    "server/${identity}/player.identities*.db*"
    "server/${identity}/player.states*.db*"
    "server/${identity}/player.blueprints*.db*"
    "server/${identity}/player.tokens*.db*"
    "server/${identity}/sv.files*"
  )
  local -n out_ref="$out_name"
  out_ref=("${defaults[@]}")
}

default_cleanup_patterns() {
  local out_name="$1"
  local defaults=(
    "logs/*.old"
    "logs/*.tmp"
    "logs/*.log.old"
    "crash/*.dmp"
    "RustDedicated_Data/CrashReports/*"
    "oxide/logs/*"
    "carbon/logs/*"
  )
  local -n out_ref="$out_name"
  out_ref=("${defaults[@]}")
}

resolve_runtime_config() {
  resolve_string_or_array RUNTIME_WIPE_CRON_SCHEDULES "WIPE_CRON_SCHEDULES" ';' "0 4 * * 4|50|weekly"
  resolve_string_or_array RUNTIME_WIPE_MAPS "WIPE_MAPS" ';'
  if (( ${#RUNTIME_WIPE_MAPS[@]} == 0 )); then
    if [[ -n "${WIPE_MAP_LIST:-}" ]]; then
      parse_scalar_list "${WIPE_MAP_LIST}" ';' RUNTIME_WIPE_MAPS
    else
      RUNTIME_WIPE_MAPS=("Procedural Map|3500|0" "Procedural Map|4000|0")
    fi
  fi

  if var_is_array "WIPE_REMOVE_PATTERNS"; then
    local -n wipe_remove_ref="WIPE_REMOVE_PATTERNS"
    normalize_list RUNTIME_WIPE_REMOVE_PATTERNS "${wipe_remove_ref[@]}"
  else
    local legacy_wipe_items=()
    if [[ -n "${WIPE_REMOVE_FILES:-}" ]]; then
      local base_items=()
      parse_scalar_list "${WIPE_REMOVE_FILES}" ';' base_items
      legacy_wipe_items+=("${base_items[@]}")
    fi
    if [[ -n "${WIPE_REMOVE_PATTERNS:-}" ]]; then
      local extra_items=()
      parse_scalar_list "${WIPE_REMOVE_PATTERNS}" ';' extra_items
      legacy_wipe_items+=("${extra_items[@]}")
    fi
    if (( ${#legacy_wipe_items[@]} == 0 )); then
      default_wipe_patterns RUNTIME_WIPE_REMOVE_PATTERNS
    else
      normalize_list RUNTIME_WIPE_REMOVE_PATTERNS "${legacy_wipe_items[@]}"
    fi
  fi

  resolve_string_or_array RUNTIME_WIPE_IGNORE_PATTERNS "WIPE_IGNORE_PATTERNS" ';'

  if var_is_array "CLEAN_FILES_ON_RESTART"; then
    local -n cleanup_ref="CLEAN_FILES_ON_RESTART"
    normalize_list RUNTIME_CLEAN_FILES_ON_RESTART "${cleanup_ref[@]}"
  else
    local cleanup_scalar="${CLEAN_FILES_ON_RESTART:-}"
    if [[ -n "$cleanup_scalar" ]]; then
      parse_scalar_list "$cleanup_scalar" ';' RUNTIME_CLEAN_FILES_ON_RESTART
    else
      default_cleanup_patterns RUNTIME_CLEAN_FILES_ON_RESTART
    fi
  fi

  resolve_string_or_array RUNTIME_CLEAN_IGNORE_PATTERNS "CLEAN_IGNORE_PATTERNS" ';'
}

load_layered_config() {
  local defaults_path
  defaults_path="$(container_dir)/config.defaults.sh"
  local user_path
  user_path="$(container_dir)/config.sh"

  if [[ -f "$defaults_path" ]]; then
    # shellcheck disable=SC1090
    source "$defaults_path"
  fi

  if [[ -f "$user_path" ]]; then
    # shellcheck disable=SC1090
    source "$user_path"
  fi

  resolve_runtime_config
}

path_matches_any() {
  local candidate="$1"
  shift || true

  local pattern
  for pattern in "$@"; do
    [[ -n "$pattern" ]] || continue
    if [[ "$candidate" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

expand_patterns_to_matches() {
  local out_name="$1"
  shift

  local -n out_ref="$out_name"
  out_ref=()

  local -A seen=()
  local pattern
  for pattern in "$@"; do
    pattern="$(trim "$pattern")"
    [[ -n "$pattern" ]] || continue

    local match
    while IFS= read -r match; do
      [[ -n "$match" ]] || continue
      if [[ -z "${seen[$match]+x}" ]]; then
        out_ref+=("$match")
        seen[$match]=1
      fi
    done < <(
      shopt -s nullglob globstar
      compgen -G "$pattern" || true
      shopt -u nullglob globstar
    )
  done
}

remove_matching_paths() {
  local label="$1"
  local remove_array_name="$2"
  local ignore_array_name="$3"

  local -n remove_ref="$remove_array_name"
  local -n ignore_ref="$ignore_array_name"

  local matches=()
  expand_patterns_to_matches matches "${remove_ref[@]}"

  local to_remove=()
  local path
  for path in "${matches[@]}"; do
    if path_matches_any "$path" "${ignore_ref[@]}"; then
      log "${label}: keeping protected path '$path'"
      continue
    fi
    to_remove+=("$path")
  done

  if (( ${#to_remove[@]} == 0 )); then
    return
  fi

  log "${label}: removing ${#to_remove[@]} path(s)"
  rm -rf -- "${to_remove[@]}"
}

ensure_seed_file() {
  if [[ -n "${MAP_URL:-}" ]]; then
    return
  fi

  if [[ "${WORLD_SEED:-0}" == "0" ]]; then
    if [[ -f seed.txt ]]; then
      WORLD_SEED="$(cat seed.txt)"
    else
      WORLD_SEED="$((RANDOM<<16 | RANDOM))"
      printf '%s' "$WORLD_SEED" > seed.txt
    fi
  fi
}

apply_cleanup() {
  resolve_runtime_config

  if [[ "${CLEAN_EACH_RESTART:-1}" != "1" ]]; then
    return
  fi

  remove_matching_paths "Restart cleanup" RUNTIME_CLEAN_FILES_ON_RESTART RUNTIME_CLEAN_IGNORE_PATTERNS
}

select_next_map() {
  resolve_runtime_config

  local mode="${MAP_ROTATION_MODE:-sequential}"
  local state_file=".wipe_state"
  local map_count="${#RUNTIME_WIPE_MAPS[@]}"
  (( map_count == 0 )) && return

  local next_index=0
  if [[ "$mode" == "random" ]]; then
    next_index=$((RANDOM % map_count))
  else
    local last_index="-1"
    if [[ -f "$state_file" ]]; then
      last_index="$(grep -E '^LAST_MAP_INDEX=' "$state_file" | tail -n1 | cut -d'=' -f2 || true)"
      [[ "$last_index" =~ ^[0-9]+$ ]] || last_index="-1"
    fi
    next_index=$(( (last_index + 1) % map_count ))
  fi

  local chosen
  chosen="$(trim "${RUNTIME_WIPE_MAPS[$next_index]}")"
  local parts=()
  split_by "$chosen" '|' parts

  local first_field
  first_field="$(trim "${parts[0]:-Procedural Map}")"
  local size
  size="$(trim "${parts[1]:-${WORLD_SIZE:-3500}}")"
  local seed
  seed="$(trim "${parts[2]:-0}")"

  [[ -z "$size" ]] && size="3500"
  [[ -z "$seed" ]] && seed="0"

  if [[ "$first_field" == http://* || "$first_field" == https://* ]]; then
    MAP_URL="$first_field"
    LEVEL=""
    WORLD_SIZE="$size"
    WORLD_SEED="$seed"
    log "Map rotation selected URL map: url='$MAP_URL'"
  else
    MAP_URL=""
    LEVEL="$first_field"
    WORLD_SIZE="$size"
    WORLD_SEED="$seed"
    [[ -z "$LEVEL" ]] && LEVEL="Procedural Map"
    log "Map rotation selected: level='$LEVEL', size='$WORLD_SIZE', seed='$WORLD_SEED'"
  fi

  {
    if [[ -f "$state_file" ]]; then
      grep -vE '^LAST_MAP_INDEX=' "$state_file" || true
    fi
    echo "LAST_MAP_INDEX=$next_index"
  } > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

apply_wipe() {
  resolve_runtime_config

  remove_matching_paths "Wipe cleanup" RUNTIME_WIPE_REMOVE_PATTERNS RUNTIME_WIPE_IGNORE_PATTERNS

  if [[ "${WIPE_RESET_SEED:-1}" == "1" ]]; then
    WORLD_SEED="$((RANDOM<<16 | RANDOM))"
    printf '%s' "$WORLD_SEED" > seed.txt
    log "Generated a new world seed: $WORLD_SEED"
  fi

  select_next_map
}

cron_due() {
  local expr="$1"
  local -a now_parts expr_parts
  now_parts=(
    "$(date -u '+%M')"
    "$(date -u '+%H')"
    "$(date -u '+%d')"
    "$(date -u '+%m')"
    "$(date -u '+%w')"
  )
  split_by "$expr" ' ' expr_parts
  (( ${#expr_parts[@]} == 5 )) || return 1

  num_dow() {
    local token="${1,,}"
    case "$token" in
      sun) echo 0 ;;
      mon) echo 1 ;;
      tue) echo 2 ;;
      wed) echo 3 ;;
      thu) echo 4 ;;
      fri) echo 5 ;;
      sat) echo 6 ;;
      *) echo "$token" ;;
    esac
  }

  nth_dow_match() {
    local now_day="$1"
    local now_dow="$2"
    local token="$3"
    if [[ ! "$token" =~ ^([^#]+)#([1-5])$ ]]; then
      return 1
    fi

    local dow_raw="${BASH_REMATCH[1]}"
    local nth="${BASH_REMATCH[2]}"
    local dow_num
    dow_num="$(num_dow "$dow_raw")"
    [[ "$dow_num" =~ ^[0-9]+$ ]] || return 1
    (( dow_num == 7 )) && dow_num=0

    if (( now_dow != dow_num )); then
      return 1
    fi

    local start=$(( (nth - 1) * 7 + 1 ))
    local end=$(( nth * 7 ))
    (( now_day >= start && now_day <= end ))
  }

  list_match() {
    local value="$1"
    local field="$2"
    local min="$3"
    local max="$4"
    local kind="$5"

    [[ "$field" == "*" ]] && return 0

    local token
    IFS=',' read -r -a tokens <<<"$field"
    for token in "${tokens[@]}"; do
      token="$(trim "$token")"
      [[ -z "$token" ]] && continue

      if [[ "$kind" == "dow" ]]; then
        if nth_dow_match "${now_parts[2]}" "${now_parts[4]}" "$token"; then
          return 0
        fi
      fi

      local step=1
      local base="$token"
      if [[ "$token" == */* ]]; then
        base="${token%/*}"
        step="${token##*/}"
        [[ "$step" =~ ^[0-9]+$ ]] || continue
        (( step > 0 )) || continue
      fi

      if [[ "$base" == "*" ]]; then
        if (( (value - min) % step == 0 )); then
          return 0
        fi
        continue
      fi

      if [[ "$base" =~ ^([^-]+)-([^-]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        [[ "$kind" == "dow" ]] && start="$(num_dow "$start")" && end="$(num_dow "$end")"
        [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || continue
        (( start == 7 )) && start=0
        (( end == 7 )) && end=0
        if (( value >= start && value <= end )); then
          if (( (value - start) % step == 0 )); then
            return 0
          fi
        fi
        continue
      fi

      [[ "$kind" == "dow" ]] && base="$(num_dow "$base")"
      [[ "$base" =~ ^[0-9]+$ ]] || continue
      (( base == 7 )) && base=0
      if (( value == base )); then
        return 0
      fi
    done

    return 1
  }

  list_match "${now_parts[0]}" "${expr_parts[0]}" 0 59 "num" || return 1
  list_match "${now_parts[1]}" "${expr_parts[1]}" 0 23 "num" || return 1
  list_match "${now_parts[2]}" "${expr_parts[2]}" 1 31 "num" || return 1
  list_match "${now_parts[3]}" "${expr_parts[3]}" 1 12 "num" || return 1
  list_match "${now_parts[4]}" "${expr_parts[4]}" 0 7 "dow" || return 1
  return 0
}

run_wipe_scheduler() {
  resolve_runtime_config

  if [[ "${AUTO_WIPE_ENABLED:-0}" != "1" ]]; then
    return
  fi

  local now_minute
  now_minute="$(date -u '+%Y-%m-%dT%H:%M')"
  local state_file=".wipe_state"

  local best_priority=-999999
  local best_label=""
  local matched=0
  local entry
  for entry in "${RUNTIME_WIPE_CRON_SCHEDULES[@]}"; do
    entry="$(trim "$entry")"
    [[ -n "$entry" ]] || continue

    local parts=()
    split_by "$entry" '|' parts
    local expr="$(trim "${parts[0]:-}")"
    local priority="$(trim "${parts[1]:-0}")"
    local label="$(trim "${parts[2]:-schedule}")"

    [[ "$priority" =~ ^-?[0-9]+$ ]] || priority=0
    if cron_due "$expr"; then
      matched=1
      if (( priority > best_priority )); then
        best_priority="$priority"
        best_label="$label"
      fi
    fi
  done

  (( matched == 1 )) || return

  local last_run=""
  if [[ -f "$state_file" ]]; then
    last_run="$(grep -E '^LAST_WIPE_MINUTE=' "$state_file" | tail -n1 | cut -d'=' -f2 || true)"
  fi

  if [[ "$last_run" == "$now_minute" ]]; then
    return
  fi

  log "Wipe schedule triggered: '$best_label' (priority: $best_priority)"
  apply_wipe

  {
    if [[ -f "$state_file" ]]; then
      grep -vE '^LAST_WIPE_MINUTE=' "$state_file" || true
    fi
    echo "LAST_WIPE_MINUTE=$now_minute"
  } > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

build_framework_flag() {
  case "${FRAMEWORK:-vanilla}" in
    carbon)
      printf '%s' "-modded"
      ;;
    oxide)
      printf '%s' "-oxide"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

append_additional_args() {
  local raw_args="${ADDITIONAL_ARGS:-}"
  [[ -n "$raw_args" ]] || return 0

  local parsed_args=()
  read -r -a parsed_args <<<"$raw_args"
  if (( ${#parsed_args[@]} > 0 )); then
    START_COMMAND+=("${parsed_args[@]}")
  fi
}

build_start_command() {
  local framework_flag
  framework_flag="$(build_framework_flag)"

  START_COMMAND=(
    "./RustDedicated"
    "-batchmode"
    "+server.port" "${SERVER_PORT}"
    "+server.queryport" "${QUERY_PORT}"
    "+server.identity" "${SERVER_IDENTITY:-rust}"
    "+rcon.ip" "0.0.0.0"
    "+rcon.port" "${RCON_PORT}"
    "+rcon.web" "true"
    "+server.hostname" "${HOSTNAME}"
    "+server.description" "${DESCRIPTION}"
    "+server.url" "${SERVER_URL:-}"
    "+server.headerimage" "${SERVER_IMG:-}"
    "+server.maxplayers" "${MAX_PLAYERS}"
    "+rcon.password" "${RCON_PASS}"
    "+app.port" "${APP_PORT}"
    "+server.saveinterval" "${SAVEINTERVAL}"
  )

  if [[ -n "${MAP_URL:-}" ]]; then
    START_COMMAND+=("+server.levelurl" "${MAP_URL}")
  else
    START_COMMAND+=(
      "+server.level" "${LEVEL:-Procedural Map}"
      "+server.worldsize" "${WORLD_SIZE:-3500}"
      "+server.seed" "${WORLD_SEED:-0}"
    )
  fi

  if [[ -n "$framework_flag" ]]; then
    START_COMMAND+=("$framework_flag")
  fi

  append_additional_args
  START_COMMAND_STRING="$(printf '%s ' "${START_COMMAND[@]}")"
}

main() {
  mkdir -p "$(container_dir)"
  cd "$(container_dir)" || exit 1

  self_update_startup "$@"
  update_managed_defaults
  bootstrap_user_config
  load_layered_config

  apply_cleanup
  run_wipe_scheduler
  ensure_seed_file
  build_start_command

  log "Starting Rust server"
  exec "${START_COMMAND[@]}"
}

if [[ "${EGG_STARTUP_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
