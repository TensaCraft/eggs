#!/usr/bin/env bash
set -euo pipefail

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

ensure_seed_file() {
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
  if [[ "${CLEAN_EACH_RESTART:-1}" != "1" ]]; then
    return
  fi

  local files_raw="${CLEAN_FILES_ON_RESTART:-logs/*.old;logs/*.tmp;crash/*.dmp;RustDedicated_Data/CrashReports/*}"
  local files=()
  split_by "$files_raw" ';' files

  for pattern in "${files[@]}"; do
    pattern="$(trim "$pattern")"
    [[ -z "$pattern" ]] && continue
    shopt -s nullglob
    local matches=( $pattern )
    shopt -u nullglob
    if (( ${#matches[@]} > 0 )); then
      log "Restart cleanup: removing '$pattern'"
      rm -rf -- $pattern
    fi
  done
}

select_next_map() {
  local mode="${MAP_ROTATION_MODE:-sequential}"
  local maps_raw="${WIPE_MAP_LIST:-Procedural Map|3500|0}"
  local state_file=".wipe_state"

  local map_defs=()
  split_by "$maps_raw" ';' map_defs
  local map_count="${#map_defs[@]}"
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

  local chosen="$(trim "${map_defs[$next_index]}")"
  local parts=()
  split_by "$chosen" '|' parts

  local level="${parts[0]:-Procedural Map}"
  local size="${parts[1]:-${WORLD_SIZE:-3500}}"
  local seed="${parts[2]:-0}"

  LEVEL="$(trim "$level")"
  WORLD_SIZE="$(trim "$size")"
  WORLD_SEED="$(trim "$seed")"

  [[ -z "$LEVEL" ]] && LEVEL="Procedural Map"
  [[ -z "$WORLD_SIZE" ]] && WORLD_SIZE="3500"
  [[ -z "$WORLD_SEED" ]] && WORLD_SEED="0"

  {
    if [[ -f "$state_file" ]]; then
      grep -vE '^LAST_MAP_INDEX=' "$state_file" || true
    fi
    echo "LAST_MAP_INDEX=$next_index"
  } > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  log "Map rotation selected: level='$LEVEL', size='$WORLD_SIZE', seed='$WORLD_SEED'"
}

apply_wipe() {
  local files_raw="${WIPE_REMOVE_FILES:-server/${SERVER_IDENTITY:-rust}/*.map;server/${SERVER_IDENTITY:-rust}/*.sav;server/${SERVER_IDENTITY:-rust}/*.sav.*;server/${SERVER_IDENTITY:-rust}/player.deaths*.db;server/${SERVER_IDENTITY:-rust}/player.identities*.db;server/${SERVER_IDENTITY:-rust}/player.states*.db;server/${SERVER_IDENTITY:-rust}/player.blueprints*.db;oxide/data/*.json;carbon/data/*.json}"
  local file_patterns="${WIPE_REMOVE_PATTERNS:-}"
  if [[ -n "$file_patterns" ]]; then
    files_raw="${files_raw};${file_patterns}"
  fi
  local files=()
  split_by "$files_raw" ';' files

  for pattern in "${files[@]}"; do
    pattern="$(trim "$pattern")"
    [[ -z "$pattern" ]] && continue
    shopt -s nullglob
    local matches=( $pattern )
    shopt -u nullglob
    if (( ${#matches[@]} > 0 )); then
      log "Wipe cleanup: removing '$pattern'"
      rm -rf -- $pattern
    fi
  done

  local reset_seed="${WIPE_RESET_SEED:-1}"
  if [[ "$reset_seed" == "1" ]]; then
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
  if [[ "${AUTO_WIPE_ENABLED:-0}" != "1" ]]; then
    return
  fi

  local schedules_raw="${WIPE_CRON_SCHEDULES:-0 4 * * 4|50|weekly}"
  local now_minute
  now_minute="$(date -u '+%Y-%m-%dT%H:%M')"
  local state_file=".wipe_state"

  local entries=()
  split_by "$schedules_raw" ';' entries

  local best_priority=-999999
  local best_label=""
  local matched=0

  for entry in "${entries[@]}"; do
    entry="$(trim "$entry")"
    [[ -z "$entry" ]] && continue

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
  } > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
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

main() {
  cd /home/container || exit 1

  apply_cleanup
  run_wipe_scheduler
  ensure_seed_file

  local map_args
  if [[ -n "${MAP_URL:-}" ]]; then
    map_args="+server.levelurl ${MAP_URL}"
  else
    map_args="+server.level \"${LEVEL:-Procedural Map}\" +server.worldsize \"${WORLD_SIZE:-3500}\" +server.seed \"${WORLD_SEED:-0}\""
  fi

  local framework_flag
  framework_flag="$(build_framework_flag)"

  local cmd
  cmd="./RustDedicated -batchmode +server.port ${SERVER_PORT} +server.queryport ${QUERY_PORT} +server.identity \"${SERVER_IDENTITY:-rust}\" +rcon.ip 0.0.0.0 +rcon.port ${RCON_PORT} +rcon.web true +server.hostname \"${HOSTNAME}\" +server.description \"${DESCRIPTION}\" +server.url \"${SERVER_URL}\" +server.headerimage \"${SERVER_IMG}\" +server.maxplayers ${MAX_PLAYERS} +rcon.password \"${RCON_PASS}\" +app.port ${APP_PORT} +server.saveinterval ${SAVEINTERVAL} ${map_args} ${framework_flag} ${ADDITIONAL_ARGS:-}"

  log "Starting Rust server"
  eval "exec ${cmd}"
}

main "$@"
