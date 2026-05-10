---
name: mister-remote
description: Drive the MiSTer FPGA over its mrext Remote HTTP API (default mister.local:8182). Use when the user asks to launch a core or game on the MiSTer, send keystrokes / press keys, take or download a screenshot from the MiSTer, reset the running core, or reboot the MiSTer. Wraps the wizzomafizzo/mrext remote API.
---

# mister-remote

Wrapper around the [wizzomafizzo/mrext](https://github.com/wizzomafizzo/mrext) Remote HTTP API. The MiSTer must be running the Remote service (default port `8182`). All commands go through one helper script.

## When to use

Trigger phrases that should invoke this skill:

- "launch the Oric core / launch system X on the mister"
- "launch this game / load this disk on the mister"
- "press menu / osd / arrow / reset on the mister"
- "send these keystrokes to the mister"
- "take a screenshot from the mister" / "screenshot the mister core"
- "download the latest screenshot"
- "reset the (mister) core"
- "reboot the mister" / "restart the mister"

Do **not** use this for source-level actions (compile, deploy `.rbf`) — those still go through `tools/oric-build`.

## Default config

- Host: `mister.local` (override with `--host` or env `MISTER_HOST`)
- Port: `8182` (override with `--port` or env `MISTER_PORT`)
- Timeout: 5 s (use higher for `reboot`)

## Helper script

All operations:

```
python3 .claude/skills/mister-remote/scripts/mister-remote.py <subcommand> [args]
```

| Subcommand | Purpose | Example |
|---|---|---|
| `sysinfo` | health/status check | `... sysinfo` |
| `playing` | currently running game | `... playing` |
| `systems` | list available systems/cores | `... systems` |
| `launch-system <id>` | launch a system/core by id (`POST /systems/{id}`) | `... launch-system Oric` |
| `launch-game <path>` | launch a game by absolute path (`POST /games/launch`) | `... launch-game /media/usb0/games/Oric/dsk/foo.dsk` |
| `launch <path>` | generic launcher (`POST /launch`) — handles `.rbf`, `.mra`, `.mgl`, game files | `... launch /media/fat/_Aoric/Oric.rbf` |
| `launch-menu` | `POST /launch/menu` — exit the running core (soft reset to MiSTer menu) | `... launch-menu` |
| `menu-view <path>` | `POST /menu/view` — list a directory on the device; use to discover cores | `... menu-view /media/fat/_Aoric` |
| `key <name>` | send one named keystroke | `... key osd` |
| `key-raw <code>` | send a raw uinput key code | `... key-raw 103` |
| `keys <name1> <name2> ...` | send a sequence of named keys | `... keys down down confirm` |
| `reset-core` | reset the running core (alias for `key reset`) | `... reset-core` |
| `reboot --yes` | reboot the entire MiSTer (requires `--yes`) | `... reboot --yes` |
| `screenshot` | capture; returns `{filename, core, modified, size}` | `... screenshot` |
| `screenshot-list` | list all stored screenshots | `... screenshot-list` |
| `screenshot-get <core> <filename> [--out PATH]` | download one screenshot | `... screenshot-get Oric oric-2026-05-10.png --out /tmp/x.png` |
| `screenshot-capture-and-download [--out PATH]` | capture + download in one call | `... screenshot-capture-and-download --out /tmp/x.png` |

JSON-returning commands print pretty-printed JSON on stdout. Errors go to stderr with a non-zero exit code.

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

Most useful in practice:

- `reset` — reset the running core (the API has no separate reset endpoint; this is it)
- `osd` — open/close the on-screen display (toggle)
- `menu` — open the MiSTer main menu
- `screenshot` — capture via keyboard (equivalent to `POST /screenshots`)
- `up` / `down` / `left` / `right` / `confirm` / `cancel` — menu navigation

Unknown names are rejected client-side and the helper prints the valid list.

## Reset semantics

| User says | Use |
|---|---|
| "reset the core" / "reset the oric" | `reset-core` (sends `key reset`). Restarts the currently running core only. Non-destructive. |
| "reboot mister" / "restart the mister" | `reboot --yes`. Full system restart. **Always confirm with the user before running this** — running cores lose state and the device drops off the network for ~30 seconds. |

## Screenshot workflow

The capture endpoint (`POST /screenshots`) is fire-and-forget — it returns an empty stub and the file is written asynchronously. The helper handles this by snapshotting the listing, posting the capture, then polling `GET /screenshots` until a new entry appears (timeout: `max(--timeout, 10s)`):

```
python3 .claude/skills/mister-remote/scripts/mister-remote.py screenshot-capture-and-download
```

prints e.g.:

```json
{
  "core": "Oric",
  "filename": "Oric_20260510_2114.png",
  "saved_to": "/home/niki/projects/Oric_MiSTer/mister_screenshots/Oric_20260510_2114.png"
}
```

**Default destination:** `./mister_screenshots/<filename>` in the current working directory. The folder is auto-created. The repo `.gitignore`s `mister_screenshots/` so captures don't get committed.

Override with `--out`:
- `--out /tmp/shot.png` — write to that exact file
- `--out /tmp/shots/` (trailing slash, or existing dir) — write `<filename>` into that directory

## Discovering cores / browsing the device

`menu-view` mirrors the MiSTer file browser. Useful starting points:

- `/media/fat/_Computer` — official Computer cores (Oric, Atari ST, BBC, etc.)
- `/media/fat/_Aoric` — this repo's dev/test build directory (timestamped + `Oric.rbf`)
- `/media/fat/_Console`, `/media/fat/_Arcade`, `/media/fat/_Other` — sibling category folders
- `/media/usb0/games/Oric/dsk` — Oric `.dsk` images on USB

Each item in the response carries `name`, `path`, `filename`, `extension`, `type`, `modified`, `size` — pass `path` to `launch` to start it.

## Launching Oric content

Oric `.dsk` images on this MiSTer live at `/media/usb0/games/Oric/dsk/` (on USB, not the SD card). Examples:

```
... launch-game /media/usb0/games/Oric/dsk/Cobra-Pinball.dsk
... launch-system Oric         # boot Oric core to BASIC, no media
```

`launch-system` accepts the system id from `... systems`.

## Error recovery

- Connection refused / DNS failure: ask the user to `ping mister.local`. If that fails, the device is off, not on the LAN, or `mister.local` mDNS isn't resolving — fall back to the IP via `--host 192.168.0.108`.
- HTTP 4xx/5xx: the helper prints the response body to stderr; surface that to the user.
- Remote service not running: on the MiSTer, the Remote service is in `/media/fat/Scripts/`; suggest the user verify it's enabled.

## Out of scope

- WebSocket transport — no live key-hold, no chord/combo support.
- Game search / index generation (`/games/search`, `/games/index`).
- INI editing (`/settings/inis/{id}`) and Scripts launcher (`/scripts/...`).
- TLS / auth — the API is plain HTTP, no auth.

These can be added as new subcommands without restructuring the skill.
