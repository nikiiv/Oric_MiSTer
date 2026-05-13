---
name: mister-remote
description: Drive a MiSTer FPGA over its mrext Remote HTTP API (default mister.local:8182). Use when the user asks to launch a core/game on the MiSTer, send keystrokes, take or download a screenshot, send the MiSTer reset key, reboot the MiSTer, browse files on the device, search the games index, manage wallpapers, control the music player, run scripts, or read/write MiSTer.ini settings. Wraps the wizzomafizzo/mrext remote API.
---

# mister-remote

Wrapper around the [wizzomafizzo/mrext](https://github.com/wizzomafizzo/mrext) Remote HTTP API. The MiSTer must be running the Remote service (default port `8182`). All operations go through one helper script.

## When to use

Trigger phrases:

- "launch the Oric core / launch system X on the mister"
- "launch this game / load this disk on the mister"
- "press menu / osd / arrow / reset on the mister"
- "send these keystrokes to the mister"
- "take a screenshot from the mister" / "download the latest screenshot"
- "reset the (mister) core" / "send reset"
- "reboot the mister"
- "list / browse cores in /media/fat/..."
- "search the mister games index for X"
- "what's the active mister wallpaper?" / "set wallpaper Y"
- "play / stop / next mister music"
- "list / run mister scripts"
- "read / edit MiSTer.ini" / "switch active INI"
- "list peer mister devices"

Do **not** use for source-level actions (compile, deploy `.rbf`) — those go through `tools/oric-build`.

## Default config

- Host: `mister.local` (override with `--host` or env `MISTER_HOST`)
- Port: `8182` (override with `--port` or env `MISTER_PORT`)
- Timeout: 5 s (helper auto-extends for `reboot` and `settings-remote-restart`)

## Helper script

```
python3 .claude/skills/mister-remote/scripts/mister-remote.py <subcommand> [args]
```

JSON-returning commands print pretty JSON on stdout. Errors go to stderr with a non-zero exit code. Destructive commands require `--yes`.

### System info

| Subcommand | Endpoint | Notes |
|---|---|---|
| `sysinfo` | `GET /sysinfo` | hostname, ips, dns, version, disks |
| `generate-mac` | `GET /settings/system/generate-mac` | proposes a fresh MAC address |

### Games

| Subcommand | Endpoint | Notes |
|---|---|---|
| `playing` | `GET /games/playing` | currently running core/game |
| `games-search <query> [--system <id>]` | `POST /games/search` | full-text search the indexed corpus |
| `games-search-systems` | `GET /games/search/systems` | systems with an indexed corpus |
| `games-index` | `POST /games/index` | rebuild the search index (async) |

### Systems / launching

| Subcommand | Endpoint | Notes |
|---|---|---|
| `systems` | `GET /systems` | id / category / name (tab-separated) |
| `launch-system <id>` | `POST /systems/{id}` | boot a core by system id |
| `launch <path>` | `POST /launch` | generic launcher: `.rbf`, `.mra`, `.mgl`, game files |
| `launch-game <path>` | `POST /games/launch` | launch a game by absolute path |
| `launch-menu` | `POST /launch/menu` | exit running core, soft reset to MiSTer menu |
| `launch-new <gamePath> <folder> <name>` | `POST /launch/new` | create a new launcher file pointing at `gamePath` |
| `launch-encoded <data>` | `GET /l/{data}` | launch from a base64-url-encoded payload (QR / NFC) |

### File browser (Menu)

| Subcommand | Endpoint | Notes |
|---|---|---|
| `menu-view <path>` | `POST /menu/view` | list a directory; response items have `path`/`name`/`type`/`extension` |
| `menu-create <type> <folder> <name>` | `POST /menu/files/create` | create a file / folder |
| `menu-rename <fromPath> <toPath>` | `POST /menu/files/rename` | rename / move on the device |
| `menu-delete <path> --yes` | `POST /menu/files/delete` | delete a file (requires `--yes`) |

### Controls (keystrokes)

| Subcommand | Endpoint | Notes |
|---|---|---|
| `key <name>` | `POST /controls/keyboard/{name}` | one named keystroke (validated client-side) |
| `key-raw <code>` | `POST /controls/keyboard-raw/{code}` | raw uinput key code |
| `keys <n1> <n2> ...` | (loop over `key`) | sequence of named keys with `--delay` between |
| `reset-core` | `POST /controls/keyboard/reset` | send MiSTer's reset key (alias for `key reset`); this is not a guaranteed cold core restart |

### Screenshots

| Subcommand | Endpoint | Notes |
|---|---|---|
| `screenshot` | `POST /screenshots` | fire-and-forget capture (returns empty stub) |
| `screenshot-list` | `GET /screenshots` | list all stored screenshots |
| `screenshot-get <core> <filename> [--out PATH]` | `GET /screenshots/{core}/{filename}` | download one PNG |
| `screenshot-delete <core> <filename> --yes` | `DELETE /screenshots/{core}/{filename}` | delete one (requires `--yes`) |
| `screenshot-capture-and-download [--out PATH]` | capture + poll + download | recommended path; see workflow below |

### Wallpapers

| Subcommand | Endpoint | Notes |
|---|---|---|
| `wallpapers` | `GET /wallpapers` | list available + active + background mode |
| `wallpapers-clear --yes` | `DELETE /wallpapers` | clear active wallpaper |
| `wallpapers-get <filename> [--out PATH]` | `GET /wallpapers/{filename}` | download one image |
| `wallpapers-set <filename>` | `POST /wallpapers/{filename}` | set as active |

### Music player

| Subcommand | Endpoint | Notes |
|---|---|---|
| `music-status` | `GET /music/status` | running / playback / playlist / track |
| `music-play` | `POST /music/play` | start playback |
| `music-stop` | `POST /music/stop` | stop playback |
| `music-next` | `POST /music/next` | skip to next track |
| `music-playback <type>` | `POST /music/playback/{type}` | mode: `random` / `loop` / `single` (server-validated) |
| `music-playlist` | `GET /music/playlist` | list available playlists |
| `music-playlist-set <name>` | `POST /music/playlist/{name}` | switch active playlist |

### Scripts

| Subcommand | Endpoint | Notes |
|---|---|---|
| `scripts-list` | `GET /scripts/list` | scripts in `/media/fat/Scripts/` (incl. `canLaunch`) |
| `scripts-launch <filename>` | `POST /scripts/launch/{filename}` | run a script |
| `scripts-console` | `POST /scripts/console` | toggle the on-screen script console |
| `scripts-kill --yes` | `POST /scripts/kill` | kill the running script |

### Settings — INI files

| Subcommand | Endpoint | Notes |
|---|---|---|
| `settings-inis` | `GET /settings/inis` | list configured INIs and which is active |
| `settings-inis-set <int>` | `PUT /settings/inis` | switch active INI by id |
| `settings-ini-get <id>` | `GET /settings/inis/{id}` | read INI as a JSON dict |
| `settings-ini-set <id> --from-file PATH` | `PUT /settings/inis/{id}` | write a key-value JSON dict (`--from-stdin` also works) |
| `settings-menu-mode <mode>` | `PUT /settings/core/menu` | set the OSD menu mode |

### Settings — Remote service

| Subcommand | Endpoint | Notes |
|---|---|---|
| `settings-remote-restart --yes` | `POST /settings/remote/restart` | restart the Remote service (will briefly drop the API) |
| `settings-remote-log [--out PATH]` | `GET /settings/remote/log` | download the service log |
| `settings-remote-peers` | `GET /settings/remote/peers` | list known peer devices |
| `settings-remote-logo [--out PATH]` | `GET /settings/remote/logo` | download the logo asset |

### System lifecycle

| Subcommand | Endpoint | Notes |
|---|---|---|
| `reboot --yes` | `POST /settings/system/reboot` | full MiSTer restart (~30 s offline) |

## Valid keystroke names

Pass any of these to `key` or `keys`:

```
up   down   left   right
volume_up   volume_down   volume_mute
menu   back   confirm   cancel   osd
screenshot   raw_screenshot
pair_bluetooth   change_background
core_select   user   reset
toggle_core_dates   console   exit_console
computer_osd
```

Most useful: `reset`, `osd`, `menu`, `screenshot`, arrow keys, `confirm`/`cancel`. Unknown names are rejected client-side.

## Reset Semantics

For Oric core work, treat a true cold core start as a launch of the RBF or
MGL, not as `reset-core`. Use:

```
python3 .claude/skills/mister-remote/scripts/mister-remote.py launch /media/fat/_Aoric/Oric.rbf
```

or launch the relevant `.mgl`.

| User says | Use |
|---|---|
| "cold boot the Oric core" / "start fresh" | `launch /media/fat/_Aoric/Oric.rbf` or launch the target `.mgl`. This is the reliable core cold-start path. |
| "press reset" / "send reset" | `reset-core` or `key reset`. Sends MiSTer's reset key; depending on the running context it may leave the core and return to MENU. |
| "soft reset to menu" / "exit core" | `launch-menu`. Drops back to the MiSTer main menu without rebooting. |
| "reboot mister" / "restart the mister" | `reboot --yes`. Full system restart. **Confirm with the user first.** |
| "restart the remote service" | `settings-remote-restart --yes`. Bounces only the Remote daemon (~5 s API outage). |

## Screenshot workflow

`POST /screenshots` is fire-and-forget — it returns an empty stub and the file is written asynchronously. `screenshot-capture-and-download` snapshots the listing, posts the capture, then polls `GET /screenshots` until a new entry appears (timeout: `max(--timeout, 10s)`):

```
python3 .claude/skills/mister-remote/scripts/mister-remote.py screenshot-capture-and-download
```

prints e.g.:

```json
{
  "core": "Oric",
  "filename": "20260510_190406-screen.png",
  "saved_to": "/home/niki/projects/Oric_MiSTer/mister_screenshots/20260510_190406-screen.png"
}
```

**Default destination:** `./mister_screenshots/<filename>` in CWD. The folder is auto-created and `mister_screenshots/` is gitignored. Override with `--out /path/file.png` (exact path) or `--out /path/dir/` (existing/trailing-slash dir).

## Discovering content

`menu-view` mirrors the MiSTer file browser. Useful starting points:

- `/media/fat/_Computer` — official Computer cores (Oric, Atari ST, BBC, etc.)
- `/media/fat/_Aoric` — this repo's dev/test build directory (timestamped + `Oric.rbf`)
- `/media/fat/_Console`, `/media/fat/_Arcade`, `/media/fat/_Other` — sibling category folders
- `/media/fat/Scripts` — scripts available to `scripts-launch`
- `/media/usb0/games/Oric/dsk` — Oric `.dsk` images on USB

Each item carries `path` / `name` / `filename` / `extension` / `type` / `modified` / `size`. Pass `path` to `launch` to start it.

For text searches, prefer `games-search <query>` if the games index has been built (`games-index` to (re)build).

## Launching Oric content

Oric `.dsk` images live at `/media/usb0/games/Oric/dsk/` (USB, not SD). Examples:

```
... launch-game /media/usb0/games/Oric/dsk/Cobra-Pinball.dsk
... launch-system Oric             # boot Oric core to BASIC, no media
... launch /media/fat/_Aoric/Oric.rbf   # cold boot a specific dev RBF
```

## Error recovery

- Connection refused / DNS failure: ask the user to `ping mister.local`. If that fails, fall back via `--host <ip>` (the build script uses `192.168.0.108`).
- HTTP 4xx/5xx: helper prints the response body to stderr; surface to user.
- Remote service not running: live in `/media/fat/Scripts/` on the device — suggest enabling it.

## Confirmation guards (commands that need `--yes`)

- `reboot` — full system restart
- `screenshot-delete` — deletes a file
- `wallpapers-clear` — clears active wallpaper
- `menu-delete` — deletes a file on the device
- `scripts-kill` — kills a running script
- `settings-remote-restart` — drops the API briefly

When the user asks for any of these, confirm intent before passing `--yes`.

## Out of scope (deliberate)

- WebSocket transport — no live key-hold, no chord/combo support. (Endpoints `kbd:`, `kbdRaw:`, `kbdRawDown:`, `kbdRawUp:`, `getIndexStatus` and the `coreRunning` / `gameRunning` / `menuNavigation` / `indexStatus` event stream are not exposed by the helper.)
- TLS / auth — the API is plain HTTP, no auth.
