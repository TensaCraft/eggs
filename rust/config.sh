#!/usr/bin/env bash
# shellcheck shell=bash
#
# User overrides for the Rust Auto Wipe egg.
#
# startup.sh loads config.defaults.sh first and then this file.
# Leave lines commented unless you want to override the managed defaults.
#
# Important:
# - Wipe rules are checked only when the server starts.
# - Times are evaluated in UTC.
# - Create a matching Pterodactyl restart schedule or the wipe will never run.
# - This file is never auto-overwritten by startup.sh.
#
# Quick workflow:
# 1. Open config.defaults.sh to see the current managed defaults.
# 2. Copy only the sections you want to change into this file.
# 3. Uncomment them here and edit the values.
# 4. Restart the server at the scheduled UTC minute.

# Enable scheduled wipes:
# AUTO_WIPE_ENABLED=1

# Disable restart cleanup completely:
# CLEAN_EACH_RESTART=0

# Keep the same seed on every wipe:
# WIPE_RESET_SEED=0

# Use random map selection instead of sequential rotation:
# MAP_ROTATION_MODE="random"

# Example schedules:
# WIPE_CRON_SCHEDULES=(
#   "0 4 * * 4|50|weekly"
# )
#
# First Monday event wipe with higher priority than normal Mondays:
# WIPE_CRON_SCHEDULES=(
#   "0 21 * * 1#1|200|first-monday-event"
#   "0 17 * * 1#2,1#3,1#4,1#5|100|regular-mondays"
# )

# Example mixed map pool:
# WIPE_MAPS=(
#   "Procedural Map|3500|0"
#   "Procedural Map|4000|0"
#   "https://example.com/monthly-event.map|3500|0"
# )

# Example full wipe pattern override.
# Copy the defaults here, then remove entries you want to preserve.
#
# To keep blueprints between wipes, remove the player.blueprints pattern.
# To keep Rust+ pairing, remove the player.tokens pattern.
#
# WIPE_REMOVE_PATTERNS=(
#   "server/${SERVER_IDENTITY:-rust}/*.map"
#   "server/${SERVER_IDENTITY:-rust}/*.sav"
#   "server/${SERVER_IDENTITY:-rust}/*.sav.*"
#   "server/${SERVER_IDENTITY:-rust}/player.deaths*.db*"
#   "server/${SERVER_IDENTITY:-rust}/player.identities*.db*"
#   "server/${SERVER_IDENTITY:-rust}/player.states*.db*"
#   "server/${SERVER_IDENTITY:-rust}/player.blueprints*.db*"
#   "server/${SERVER_IDENTITY:-rust}/player.tokens*.db*"
#   "server/${SERVER_IDENTITY:-rust}/sv.files*"
# )

# Optional plugin-data wipe examples.
# Use these only if you really want plugin JSON data reset too:
# WIPE_REMOVE_PATTERNS+=(
#   "oxide/data/*.json"
#   "carbon/data/*.json"
# )

# Protect specific files or folders from broad wipe patterns:
# WIPE_IGNORE_PATTERNS=(
#   "server/${SERVER_IDENTITY:-rust}/protected-backups/*"
#   "oxide/data/keep-this-plugin.json"
# )

# Restart cleanup override example:
# CLEAN_FILES_ON_RESTART=(
#   "logs/*.old"
#   "logs/*.tmp"
#   "logs/*.log.old"
#   "crash/*.dmp"
#   "RustDedicated_Data/CrashReports/*"
#   "oxide/logs/*"
#   "carbon/logs/*"
# )

# Protect one cleanup target even when the glob matches it:
# CLEAN_IGNORE_PATTERNS=(
#   "logs/keep-this-session.log"
# )

# Example operational note:
# If you configure a wipe for "0 4 * * 4|50|weekly", create a panel restart
# schedule for Thursday 04:00 UTC as well. The wipe is evaluated only during
# startup, not while the server is already running.
