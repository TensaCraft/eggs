# Rust Auto Wipe Egg

This Rust egg is built for Pterodactyl and focuses on safe, predictable wipe automation without forcing users to manage long semicolon-delimited panel strings.

## Config model

The egg now uses two shell config files inside the server directory:

- `config.defaults.sh`
- `config.sh`

`config.defaults.sh` is the managed defaults layer stored in GitHub. `startup.sh` can auto-update it from GitHub.

`config.sh` is the user-owned override layer. It is created on the server from `config.defaults.sh` if missing and is never stored in this repository or overwritten automatically.

Load order:

1. `config.defaults.sh`
2. `config.sh`

This gives you:

- one managed config file in GitHub
- updatable defaults from GitHub
- local overrides that survive updates
- readable arrays and comments instead of long panel text fields

## What still lives in the panel

Short runtime values still make sense in the panel:

- hostname
- description
- URL and header image
- ports
- max players
- save interval
- server identity
- framework
- default `LEVEL`, `WORLD_SIZE`, `WORLD_SEED`, `MAP_URL`
- additional simple startup args

Most wipe and cleanup behavior should now be configured in `config.sh`.

Legacy panel wipe variables are kept only as compatibility fallbacks for older installs.

## Important operational note

Automated wipe logic is evaluated only when `startup.sh` runs, right before the server starts.

That means:

- wipe schedules are checked only on startup
- schedule times are interpreted in UTC
- you must create a matching Pterodactyl restart schedule
- if the server is not restarted in the matching UTC minute, the wipe does not happen

Example:

- If `WIPE_CRON_SCHEDULES` contains `0 4 * * 4|50|weekly`
- then create a Pterodactyl restart schedule for Thursday `04:00 UTC`

## Wipe defaults

The managed defaults wipe the Rust world and player persistence files without wiping plugin data by default.

Default wipe targets:

```text
server/${SERVER_IDENTITY:-rust}/*.map
server/${SERVER_IDENTITY:-rust}/*.sav
server/${SERVER_IDENTITY:-rust}/*.sav.*
server/${SERVER_IDENTITY:-rust}/player.deaths*.db*
server/${SERVER_IDENTITY:-rust}/player.identities*.db*
server/${SERVER_IDENTITY:-rust}/player.states*.db*
server/${SERVER_IDENTITY:-rust}/player.blueprints*.db*
server/${SERVER_IDENTITY:-rust}/player.tokens*.db*
server/${SERVER_IDENTITY:-rust}/sv.files*
```

Why these are included:

- `.map` and `.sav` hold the map and saved world state
- `player.*.db*` covers player persistence and SQLite sidecar files
- `player.tokens` is related to Rust+ pairing data
- `sv.files` stores sign and image data

Plugin data wipe examples are documented in the config files, but they are opt-in:

```text
oxide/data/*.json
carbon/data/*.json
```

## Cleanup defaults

Restart cleanup is designed only for disposable artifacts:

```text
logs/*.old
logs/*.tmp
logs/*.log.old
crash/*.dmp
RustDedicated_Data/CrashReports/*
oxide/logs/*
carbon/logs/*
```

This cleanup intentionally avoids:

- plugin configs
- plugin data
- world files
- player databases

## Map rotation format

`WIPE_MAPS` is a Bash array in `config.sh`.

Each entry uses the same three-part format:

```bash
"first-field|size|seed"
```

Examples:

```bash
WIPE_MAPS=(
  "Procedural Map|3500|0"
  "Barren|3000|12345"
  "https://example.com/monthly-event.map|3500|0"
)
```

Rules:

- if the first field starts with `http://` or `https://`, it becomes `+server.levelurl`
- otherwise the first field is treated as `LEVEL`
- `size` and `seed` stay in the same format for consistency
- for URL maps, `size` and `seed` are ignored during launch

## Ignore lists

Two separate ignore arrays are supported in `config.sh`:

- `WIPE_IGNORE_PATTERNS`
- `CLEAN_IGNORE_PATTERNS`

Use them when a broad remove glob is correct overall, but one specific file or folder must survive.

Examples:

```bash
WIPE_IGNORE_PATTERNS=(
  "server/${SERVER_IDENTITY:-rust}/protected-backups/*"
)

CLEAN_IGNORE_PATTERNS=(
  "logs/keep-this-session.log"
)
```

## GitHub update flow

There are three different moving pieces:

### Egg JSON in the panel

`egg-rust-auto-wipe.json` is what the panel imports through `update_url`.

That controls:

- startup command
- install script
- panel variables

### `startup.sh`

The server downloads `startup.sh` from GitHub during install.

After that, `startup.sh` can self-update from GitHub on future boots.

### Config files

`config.defaults.sh` is the only config file stored in GitHub and may update from GitHub.

`config.sh` is created only on the server if missing by copying `config.defaults.sh`. It is not auto-overwritten and does not need to exist in the repository.

This means new defaults can appear over time without destroying local edits.

## References

- Pterodactyl Rust egg reference: [Rust Staging](https://eggs.pterodactyl.io/egg/games-rust-staging/)
- Rust server file layout: [Facepunch Rust Wiki](https://wiki.facepunch.com/rust/Getting-Started_w-Server)
- Rust wipe basics: [Fragnet Rust wipe guide](https://docs.fragnet.net/games/rust/rust-wipe/)
- Rust+ / blueprint discussions: [uMod forums](https://umod.org/community/rust/35707-no-blueprint-wipe)
