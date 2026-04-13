# Rust Auto Wipe Egg

This egg is built for Rust dedicated servers on Pterodactyl and focuses on safe, predictable wipe automation.

## What this egg does

- Installs Rust server files with SteamCMD.
- Runs a startup script that can:
  - clean restart junk files,
  - evaluate wipe schedules,
  - wipe world/player data using file patterns,
  - rotate map settings,
  - launch Rust with vanilla, Oxide, or Carbon flags.

## Wipe model and defaults

The wipe defaults are designed around common Rust server wipe practice:

- World/map files are in `server/<identity>/` and typically use `.map` and `.sav` extensions.
- Player progression/state is stored in `player.*.db` files (identities, states, deaths, blueprints).
- Plugin data may be cleaned for full resets (`oxide/data/*.json`, `carbon/data/*.json`).

Default `WIPE_REMOVE_FILES`:

```text
server/${SERVER_IDENTITY:-rust}/*.map;
server/${SERVER_IDENTITY:-rust}/*.sav;
server/${SERVER_IDENTITY:-rust}/*.sav.*;
server/${SERVER_IDENTITY:-rust}/player.deaths*.db;
server/${SERVER_IDENTITY:-rust}/player.identities*.db;
server/${SERVER_IDENTITY:-rust}/player.states*.db;
server/${SERVER_IDENTITY:-rust}/player.blueprints*.db;
oxide/data/*.json;
carbon/data/*.json
```

Default `CLEAN_FILES_ON_RESTART`:

```text
logs/*.old;logs/*.tmp;crash/*.dmp;RustDedicated_Data/CrashReports/*
```

## Why these defaults

Research and references:

1. Fragnet Rust wipe guide states that wipe data is inside `/server/<identity>`, map wipe is `.map`/`.sav`, and player wipe is `player*.db` files.
   - https://docs.fragnet.net/games/rust/rust-wipe/
2. uMod community confirms blueprint data is inside `player.blueprints.*.db` in the server identity folder and should be handled while server is stopped.
   - https://umod.org/community/rust/35707-no-blueprint-wipe
3. Pterodactyl official Rust egg docs confirm standard Rust startup and identity-based folder usage conventions.
   - https://eggs.pterodactyl.io/egg/games-rust-staging/

## Scheduling format

`WIPE_CRON_SCHEDULES` format:

```text
cron|priority|label;cron|priority|label
```

Supported cron tokens in this egg parser:

- `*`
- comma lists (`1,2,3`)
- ranges (`1-5`)
- steps (`*/15`, `1-31/2`)
- day names (`mon`, `tue`, ...)
- nth weekday in month (`1#1` = first Monday)

Example: Mondays at 17:00, but first Monday at 21:00:

```text
0 21 * * 1#1|200|first-mon-21;0 17 * * 1#2,1#3,1#4,1#5|100|other-mon-17
```

## Important note

Always stop the server before manual wipe operations. Automated wipe from this egg is designed to run at startup before the game process is launched.
