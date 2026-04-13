#!/usr/bin/env bash
# shellcheck shell=bash
#
# Managed defaults for the Rust Auto Wipe egg.
#
# startup.sh loads this file first, then loads config.sh on top of it.
# This file may be auto-updated from GitHub.
#
# Important:
# - Automated wipe checks run only when the server starts.
# - Schedule expressions are evaluated in UTC.
# - To make automatic wipes actually happen, create a matching Pterodactyl
#   restart schedule for the same UTC minute.
# - If the server is not restarted during the matching minute, no wipe runs.
#
# Examples:
# - Weekly wipe every Thursday at 04:00 UTC
# - First Monday special wipe with higher priority than other Mondays
# - Mixed procedural and custom URL map rotation
# - Cleanup of crash reports and mod logs on every restart
# - Ignore one protected file even when a broad wipe pattern matches it

# 1 = evaluate wipe schedules at startup
# 0 = never trigger automated wipe logic
: "${AUTO_WIPE_ENABLED:=0}"

# 1 = clean disposable files at every startup
# 0 = leave cleanup disabled
: "${CLEAN_EACH_RESTART:=1}"

# 1 = generate a fresh random seed whenever a wipe triggers
# 0 = keep whatever seed is already selected
: "${WIPE_RESET_SEED:=1}"

# sequential = walk through WIPE_MAPS in order
# random     = choose a random WIPE_MAPS entry on each wipe
: "${MAP_ROTATION_MODE:=sequential}"

if ! declare -p WIPE_CRON_SCHEDULES >/dev/null 2>&1 || [[ -z "${WIPE_CRON_SCHEDULES:-}" ]]; then
  unset WIPE_CRON_SCHEDULES 2>/dev/null || true
  WIPE_CRON_SCHEDULES=(
    "0 4 * * 4|50|weekly"
  )
fi
#
# Schedule entry format: "minute hour day month dow|priority|label"
#
# Examples:
# "0 4 * * 4|50|weekly"
#   Every Thursday at 04:00 UTC.
#
# "0 21 * * 1#1|200|first-monday"
#   First Monday of the month at 21:00 UTC with higher priority.
#
# "0 17 * * 1#2,1#3,1#4,1#5|100|other-mondays"
#   Other Mondays at 17:00 UTC.
#
# If multiple rules match the same startup minute, the highest priority wins.

if ! declare -p WIPE_MAPS >/dev/null 2>&1; then
  WIPE_MAPS=(
    "Procedural Map|3500|0"
    "Procedural Map|4000|0"
  )
fi
#
# Map entry format: "first-field|size|seed"
#
# Examples:
# "Procedural Map|3500|0"
#   Standard procedural map. Seed 0 means seed.txt or a generated seed may be used.
#
# "Barren|3000|12345"
#   Fixed seed for repeatable terrain.
#
# "https://example.com/monthly-event.map|3500|0"
#   Custom URL map. When the first field starts with http:// or https://,
#   startup.sh switches to +server.levelurl mode. size and seed stay in the
#   same 3-part format for consistency but are ignored for the actual launch.

if ! declare -p WIPE_REMOVE_PATTERNS >/dev/null 2>&1 || [[ -z "${WIPE_REMOVE_PATTERNS:-}" ]]; then
  unset WIPE_REMOVE_PATTERNS 2>/dev/null || true
  WIPE_REMOVE_PATTERNS=(
    "server/${SERVER_IDENTITY:-rust}/*.map"
    "server/${SERVER_IDENTITY:-rust}/*.sav"
    "server/${SERVER_IDENTITY:-rust}/*.sav.*"
    "server/${SERVER_IDENTITY:-rust}/player.deaths*.db*"
    "server/${SERVER_IDENTITY:-rust}/player.identities*.db*"
    "server/${SERVER_IDENTITY:-rust}/player.states*.db*"
    "server/${SERVER_IDENTITY:-rust}/player.blueprints*.db*"
    "server/${SERVER_IDENTITY:-rust}/player.tokens*.db*"
    "server/${SERVER_IDENTITY:-rust}/sv.files*"
  )
fi
#
# These defaults target world persistence plus player state databases.
# They intentionally do NOT wipe plugin data by default.
#
# Optional plugin-data wipe examples. Keep these commented unless you really
# want plugin JSON data reset on every wipe:
#
# "oxide/data/*.json"
# "carbon/data/*.json"

if ! declare -p WIPE_IGNORE_PATTERNS >/dev/null 2>&1; then
  WIPE_IGNORE_PATTERNS=()
fi
#
# Anything that matches WIPE_IGNORE_PATTERNS is protected even if it also
# matches WIPE_REMOVE_PATTERNS.
#
# Examples:
# "server/${SERVER_IDENTITY:-rust}/protected-backups/*"
# "oxide/data/keep-this-plugin.json"

if ! declare -p CLEAN_FILES_ON_RESTART >/dev/null 2>&1 || [[ -z "${CLEAN_FILES_ON_RESTART:-}" ]]; then
  unset CLEAN_FILES_ON_RESTART 2>/dev/null || true
  CLEAN_FILES_ON_RESTART=(
    "logs/*.old"
    "logs/*.tmp"
    "logs/*.log.old"
    "crash/*.dmp"
    "RustDedicated_Data/CrashReports/*"
    "oxide/logs/*"
    "carbon/logs/*"
  )
fi
#
# Cleanup defaults remove disposable crash and log artifacts only.
# They do not touch plugin configs, data, or server saves.
#
# Examples of paths that are safe to clean:
# - historical rotated logs
# - crash dumps
# - Oxide/uMod logs
# - Carbon logs

if ! declare -p CLEAN_IGNORE_PATTERNS >/dev/null 2>&1; then
  CLEAN_IGNORE_PATTERNS=()
fi
#
# Cleanup ignore examples:
# "logs/keep-this-session.log"
# "carbon/logs/important-audit.log"
