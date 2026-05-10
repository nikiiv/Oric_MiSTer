#!/usr/bin/env python3
"""CLI wrapper around the wizzomafizzo/mrext Remote HTTP API on a MiSTer FPGA.

Default target: http://mister.local:8182/api (override with --host/--port or
the MISTER_HOST / MISTER_PORT environment variables).
"""

import argparse
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VALID_KEY_NAMES = (
    "up", "down", "left", "right",
    "volume_up", "volume_down", "volume_mute",
    "menu", "back", "confirm", "cancel", "osd",
    "screenshot", "raw_screenshot",
    "pair_bluetooth", "change_background",
    "core_select", "user", "reset",
    "toggle_core_dates", "console", "exit_console",
    "computer_osd",
)

DEFAULT_SCREENSHOT_DIR = "mister_screenshots"


# --- HTTP plumbing ----------------------------------------------------------

def base_url(args):
    return f"http://{args.host}:{args.port}/api"


def _request(method, url, *, data=None, raw_data=None, timeout=5):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif raw_data is not None:
        body = raw_data
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", errors="replace").strip()
        except Exception:
            pass
        sys.stderr.write(f"HTTP {e.code} {method} {url}\n")
        if detail:
            sys.stderr.write(detail + "\n")
        sys.exit(1)
    except urllib.error.URLError as e:
        sys.stderr.write(
            f"connection failed: {e.reason}\n"
            f"  target: {url}\n"
            f"  hints: ping {urllib.parse.urlparse(url).hostname}; "
            f"check that mrext Remote is running on the MiSTer (port 8182).\n"
        )
        sys.exit(2)


def _read_body(resp):
    raw = resp.read()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw.decode("utf-8", errors="replace")


def _get_json(args, path, *, timeout=None):
    timeout = timeout if timeout is not None else args.timeout
    with _request("GET", base_url(args) + path, timeout=timeout) as resp:
        return json.load(resp)


def _post(args, path, *, data=None, timeout=None):
    timeout = timeout if timeout is not None else args.timeout
    with _request("POST", base_url(args) + path, data=data, timeout=timeout) as resp:
        return _read_body(resp)


def _put(args, path, *, data=None, timeout=None):
    timeout = timeout if timeout is not None else args.timeout
    with _request("PUT", base_url(args) + path, data=data, timeout=timeout) as resp:
        return _read_body(resp)


def _delete(args, path, *, timeout=None):
    timeout = timeout if timeout is not None else args.timeout
    with _request("DELETE", base_url(args) + path, timeout=timeout) as resp:
        return _read_body(resp)


def _download(args, path, out_path):
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with _request("GET", base_url(args) + path, timeout=args.timeout) as resp, out_path.open("wb") as fh:
        shutil.copyfileobj(resp, fh)
    return out_path


def _print_json(value):
    if value is None:
        return
    if isinstance(value, str):
        print(value)
        return
    print(json.dumps(value, indent=2, sort_keys=True))


def _confirm(args, what):
    if not args.yes:
        sys.stderr.write(f"refusing to {what} without --yes\n")
        sys.exit(1)


def _quote(s):
    return urllib.parse.quote(str(s), safe="")


# --- System info ------------------------------------------------------------

def cmd_sysinfo(args):
    _print_json(_get_json(args, "/sysinfo"))


# --- Games ------------------------------------------------------------------

def cmd_playing(args):
    _print_json(_get_json(args, "/games/playing"))


def cmd_games_search(args):
    body = {"data": args.query}
    if args.system:
        body["system"] = args.system
    _print_json(_post(args, "/games/search", data=body))


def cmd_games_search_systems(args):
    _print_json(_get_json(args, "/games/search/systems"))


def cmd_games_index(args):
    _post(args, "/games/index")
    print("index requested (runs asynchronously; watch /sysinfo or WebSocket indexStatus)")


# --- Systems ----------------------------------------------------------------

def cmd_systems(args):
    data = _get_json(args, "/systems")
    if not isinstance(data, list):
        _print_json(data)
        return
    for s in data:
        sid = s.get("id", "")
        name = s.get("name", "")
        cat = s.get("category", "")
        print(f"{sid}\t{cat}\t{name}")


def cmd_launch_system(args):
    _print_json(_post(args, f"/systems/{_quote(args.id)}"))


# --- Launch -----------------------------------------------------------------

def cmd_launch_game(args):
    _print_json(_post(args, "/games/launch", data={"path": args.path}))


def cmd_launch(args):
    _print_json(_post(args, "/launch", data={"path": args.path}))


def cmd_launch_menu(args):
    _print_json(_post(args, "/launch/menu"))


def cmd_launch_new(args):
    _print_json(_post(args, "/launch/new", data={
        "gamePath": args.gamePath,
        "folder": args.folder,
        "name": args.name,
    }))


def cmd_launch_encoded(args):
    with _request("GET", base_url(args) + f"/l/{_quote(args.data)}", timeout=args.timeout) as resp:
        body = _read_body(resp)
    _print_json(body if body is not None else "ok")


# --- Menu / file ops --------------------------------------------------------

def cmd_menu_view(args):
    _print_json(_post(args, "/menu/view", data={"path": args.path}))


def cmd_menu_create(args):
    _print_json(_post(args, "/menu/files/create", data={
        "type": args.type,
        "folder": args.folder,
        "name": args.name,
    }))


def cmd_menu_rename(args):
    _print_json(_post(args, "/menu/files/rename", data={
        "fromPath": args.fromPath,
        "toPath": args.toPath,
    }))


def cmd_menu_delete(args):
    _confirm(args, f"delete {args.path}")
    _print_json(_post(args, "/menu/files/delete", data={"path": args.path}))


# --- Controls ---------------------------------------------------------------

def _validate_key(name):
    if name not in VALID_KEY_NAMES:
        sys.stderr.write(f"unknown key name: {name!r}\nvalid names:\n")
        for n in VALID_KEY_NAMES:
            sys.stderr.write(f"  {n}\n")
        sys.exit(1)


def cmd_key(args):
    _validate_key(args.name)
    _print_json(_post(args, f"/controls/keyboard/{_quote(args.name)}"))


def cmd_key_raw(args):
    _print_json(_post(args, f"/controls/keyboard-raw/{int(args.code)}"))


def cmd_keys(args):
    for n in args.names:
        _validate_key(n)
    for i, n in enumerate(args.names):
        if i:
            time.sleep(args.delay)
        _post(args, f"/controls/keyboard/{_quote(n)}")
        print(f"sent: {n}")


def cmd_reset_core(args):
    _post(args, "/controls/keyboard/reset")
    print("sent: reset")


# --- Screenshots ------------------------------------------------------------

def cmd_screenshot(args):
    _print_json(_post(args, "/screenshots"))


def cmd_screenshot_list(args):
    _print_json(_get_json(args, "/screenshots"))


def _resolve_screenshot_out(args, filename):
    if args.out:
        out = Path(args.out)
        if out.is_dir() or str(args.out).endswith(("/", os.sep)):
            out.mkdir(parents=True, exist_ok=True)
            return out / filename
        out.parent.mkdir(parents=True, exist_ok=True)
        return out
    folder = Path.cwd() / DEFAULT_SCREENSHOT_DIR
    folder.mkdir(parents=True, exist_ok=True)
    return folder / filename


def cmd_screenshot_get(args):
    out = _resolve_screenshot_out(args, args.filename)
    path = _download(args, f"/screenshots/{_quote(args.core)}/{_quote(args.filename)}", out)
    print(str(path))


def cmd_screenshot_delete(args):
    _confirm(args, f"delete screenshot {args.core}/{args.filename}")
    _print_json(_delete(args, f"/screenshots/{_quote(args.core)}/{_quote(args.filename)}"))


def _screenshot_keys(items):
    return {(s.get("core", ""), s.get("filename", "")) for s in items if s.get("filename")}


def cmd_screenshot_capture_and_download(args):
    before = _get_json(args, "/screenshots") or []
    before_keys = _screenshot_keys(before)
    _post(args, "/screenshots")
    deadline = time.time() + max(args.timeout, 10.0)
    new_item = None
    while time.time() < deadline:
        time.sleep(0.5)
        cur = _get_json(args, "/screenshots") or []
        candidates = [
            s for s in cur
            if s.get("filename") and (s.get("core", ""), s["filename"]) not in before_keys
        ]
        if candidates:
            candidates.sort(key=lambda s: s.get("modified", ""))
            new_item = candidates[-1]
            break
    if not new_item:
        sys.stderr.write(
            "capture: no new screenshot appeared within "
            f"{max(args.timeout, 10.0):.0f}s. Check that a core is running.\n"
        )
        sys.exit(1)
    out = _resolve_screenshot_out(args, new_item["filename"])
    path = _download(args, f"/screenshots/{_quote(new_item['core'])}/{_quote(new_item['filename'])}", out)
    print(json.dumps(
        {"core": new_item["core"], "filename": new_item["filename"], "saved_to": str(path)},
        indent=2,
    ))


# --- Wallpapers -------------------------------------------------------------

def cmd_wallpapers(args):
    _print_json(_get_json(args, "/wallpapers"))


def cmd_wallpapers_clear(args):
    _confirm(args, "clear active wallpaper")
    _print_json(_delete(args, "/wallpapers"))


def cmd_wallpapers_get(args):
    out = Path(args.out) if args.out else Path.cwd() / args.filename
    path = _download(args, f"/wallpapers/{_quote(args.filename)}", out)
    print(str(path))


def cmd_wallpapers_set(args):
    _print_json(_post(args, f"/wallpapers/{_quote(args.filename)}"))


# --- Music ------------------------------------------------------------------

def cmd_music_status(args):
    _print_json(_get_json(args, "/music/status"))


def cmd_music_play(args):
    _post(args, "/music/play")
    print("play")


def cmd_music_stop(args):
    _post(args, "/music/stop")
    print("stop")


def cmd_music_next(args):
    _post(args, "/music/next")
    print("next")


def cmd_music_playback(args):
    _post(args, f"/music/playback/{_quote(args.type)}")
    print(f"playback: {args.type}")


def cmd_music_playlist(args):
    _print_json(_get_json(args, "/music/playlist"))


def cmd_music_playlist_set(args):
    _post(args, f"/music/playlist/{_quote(args.name)}")
    print(f"playlist: {args.name}")


# --- Scripts ----------------------------------------------------------------

def cmd_scripts_list(args):
    _print_json(_get_json(args, "/scripts/list"))


def cmd_scripts_launch(args):
    _print_json(_post(args, f"/scripts/launch/{_quote(args.filename)}"))


def cmd_scripts_console(args):
    _post(args, "/scripts/console")
    print("console toggled")


def cmd_scripts_kill(args):
    _confirm(args, "kill the running script")
    _post(args, "/scripts/kill")
    print("kill requested")


# --- Settings ---------------------------------------------------------------

def cmd_settings_inis(args):
    _print_json(_get_json(args, "/settings/inis"))


def cmd_settings_inis_set(args):
    _put(args, "/settings/inis", data={"ini": int(args.ini)})
    print(f"active ini: {args.ini}")


def cmd_settings_ini_get(args):
    _print_json(_get_json(args, f"/settings/inis/{_quote(args.id)}"))


def cmd_settings_ini_set(args):
    if args.from_stdin:
        body = json.loads(sys.stdin.read())
    elif args.from_file:
        body = json.loads(Path(args.from_file).read_text())
    else:
        sys.stderr.write("settings-ini-set requires --from-file PATH or --from-stdin\n")
        sys.exit(1)
    if not isinstance(body, dict):
        sys.stderr.write("ini body must be a JSON object (key-value dict)\n")
        sys.exit(1)
    _put(args, f"/settings/inis/{_quote(args.id)}", data=body)
    print(f"ini {args.id} updated ({len(body)} keys)")


def cmd_settings_menu_mode(args):
    _put(args, "/settings/core/menu", data={"mode": args.mode})
    print(f"menu mode: {args.mode}")


def cmd_settings_remote_restart(args):
    _confirm(args, "restart the Remote service (may briefly drop the API)")
    _post(args, "/settings/remote/restart", timeout=max(args.timeout, 15))
    print("remote restart requested")


def cmd_settings_remote_log(args):
    out = Path(args.out) if args.out else Path.cwd() / "mister-remote.log"
    path = _download(args, "/settings/remote/log", out)
    print(str(path))


def cmd_settings_remote_peers(args):
    _print_json(_get_json(args, "/settings/remote/peers"))


def cmd_settings_remote_logo(args):
    out = Path(args.out) if args.out else Path.cwd() / "mister-remote-logo"
    path = _download(args, "/settings/remote/logo", out)
    print(str(path))


def cmd_generate_mac(args):
    _print_json(_get_json(args, "/settings/system/generate-mac"))


def cmd_reboot(args):
    _confirm(args, "reboot the entire MiSTer")
    timeout = max(args.timeout, 30)
    _post(args, "/settings/system/reboot", timeout=timeout)
    print("reboot requested")


# --- argparse wiring --------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="mister-remote",
        description="Talk to the mrext Remote HTTP API on a MiSTer FPGA.",
    )
    p.add_argument("--host", default=os.environ.get("MISTER_HOST", "mister.local"))
    p.add_argument("--port", type=int, default=int(os.environ.get("MISTER_PORT", "8182")))
    p.add_argument("--timeout", type=float, default=5.0)
    sub = p.add_subparsers(dest="cmd", required=True)

    # System info
    sub.add_parser("sysinfo", help="GET /sysinfo").set_defaults(func=cmd_sysinfo)

    # Games
    sub.add_parser("playing", help="GET /games/playing").set_defaults(func=cmd_playing)
    s = sub.add_parser("games-search", help="POST /games/search — full-text search the games index")
    s.add_argument("query", help="search string (matches filename)")
    s.add_argument("--system", help="restrict to a single system id (default: all systems)")
    s.set_defaults(func=cmd_games_search)
    sub.add_parser("games-search-systems", help="GET /games/search/systems — systems with an indexed corpus").set_defaults(func=cmd_games_search_systems)
    sub.add_parser("games-index", help="POST /games/index — (re)build the games search index (async)").set_defaults(func=cmd_games_index)

    # Systems
    sub.add_parser("systems", help="GET /systems (id/category/name)").set_defaults(func=cmd_systems)
    s = sub.add_parser("launch-system", help="POST /systems/{id}")
    s.add_argument("id")
    s.set_defaults(func=cmd_launch_system)

    # Launchers
    s = sub.add_parser("launch-game", help='POST /games/launch with {"path": ...}')
    s.add_argument("path", help="absolute path on the MiSTer (e.g. /media/usb0/games/Oric/dsk/foo.dsk)")
    s.set_defaults(func=cmd_launch_game)

    s = sub.add_parser("launch", help='POST /launch — generic launcher for .rbf, .mra, .mgl, or game files')
    s.add_argument("path", help="absolute path on the MiSTer (e.g. /media/fat/_Aoric/Oric.rbf)")
    s.set_defaults(func=cmd_launch)

    sub.add_parser("launch-menu", help="POST /launch/menu (exits running core, soft-resets to MiSTer menu)").set_defaults(func=cmd_launch_menu)

    s = sub.add_parser("launch-new", help="POST /launch/new — create a new launcher file in folder")
    s.add_argument("gamePath", help="absolute path of the target game on the MiSTer")
    s.add_argument("folder", help="destination folder on the MiSTer")
    s.add_argument("name", help="launcher filename (no extension)")
    s.set_defaults(func=cmd_launch_new)

    s = sub.add_parser("launch-encoded", help="GET /l/{data} — launch from a base64-url-encoded payload (QR/NFC)")
    s.add_argument("data", help="base64-url-encoded launch data")
    s.set_defaults(func=cmd_launch_encoded)

    # Menu / file ops
    s = sub.add_parser("menu-view", help="POST /menu/view — list a directory on the MiSTer (discover cores/games)")
    s.add_argument("path", help="absolute directory path on the MiSTer (e.g. /media/fat/_Aoric or /media/fat/_Computer)")
    s.set_defaults(func=cmd_menu_view)

    s = sub.add_parser("menu-create", help="POST /menu/files/create — create a file/folder in the MiSTer file browser")
    s.add_argument("type", help="file type (e.g. folder)")
    s.add_argument("folder", help="parent folder absolute path on the MiSTer")
    s.add_argument("name", help="new file/folder name")
    s.set_defaults(func=cmd_menu_create)

    s = sub.add_parser("menu-rename", help="POST /menu/files/rename — rename/move a file on the MiSTer")
    s.add_argument("fromPath", help="absolute source path on the MiSTer")
    s.add_argument("toPath", help="absolute destination path on the MiSTer")
    s.set_defaults(func=cmd_menu_rename)

    s = sub.add_parser("menu-delete", help="POST /menu/files/delete — delete a file on the MiSTer")
    s.add_argument("path", help="absolute path on the MiSTer to delete")
    s.add_argument("--yes", action="store_true", help="confirm the deletion")
    s.set_defaults(func=cmd_menu_delete)

    # Controls
    s = sub.add_parser("key", help="POST /controls/keyboard/{name}")
    s.add_argument("name", help=f"one of: {', '.join(VALID_KEY_NAMES)}")
    s.set_defaults(func=cmd_key)

    s = sub.add_parser("key-raw", help="POST /controls/keyboard-raw/{code}")
    s.add_argument("code", type=int)
    s.set_defaults(func=cmd_key_raw)

    s = sub.add_parser("keys", help="send a sequence of named keys")
    s.add_argument("names", nargs="+")
    s.add_argument("--delay", type=float, default=0.05, help="seconds between keys (default 0.05)")
    s.set_defaults(func=cmd_keys)

    sub.add_parser("reset-core", help="POST /controls/keyboard/reset (alias for `key reset`)").set_defaults(func=cmd_reset_core)

    # Screenshots
    sub.add_parser("screenshot", help="POST /screenshots (capture)").set_defaults(func=cmd_screenshot)
    sub.add_parser("screenshot-list", help="GET /screenshots").set_defaults(func=cmd_screenshot_list)

    s = sub.add_parser("screenshot-get", help="download a screenshot to a local file")
    s.add_argument("core")
    s.add_argument("filename")
    s.add_argument("--out", help=f"output path or directory (default: ./{DEFAULT_SCREENSHOT_DIR}/{{filename}})")
    s.set_defaults(func=cmd_screenshot_get)

    s = sub.add_parser("screenshot-delete", help="DELETE /screenshots/{core}/{filename}")
    s.add_argument("core")
    s.add_argument("filename")
    s.add_argument("--yes", action="store_true", help="confirm the deletion")
    s.set_defaults(func=cmd_screenshot_delete)

    s = sub.add_parser("screenshot-capture-and-download", help="capture, then download to a local file")
    s.add_argument("--out", help=f"output path or directory (default: ./{DEFAULT_SCREENSHOT_DIR}/{{filename}})")
    s.set_defaults(func=cmd_screenshot_capture_and_download)

    # Wallpapers
    sub.add_parser("wallpapers", help="GET /wallpapers — list available + active wallpaper").set_defaults(func=cmd_wallpapers)

    s = sub.add_parser("wallpapers-clear", help="DELETE /wallpapers — clear active wallpaper")
    s.add_argument("--yes", action="store_true", help="confirm the change")
    s.set_defaults(func=cmd_wallpapers_clear)

    s = sub.add_parser("wallpapers-get", help="GET /wallpapers/{filename} — download a wallpaper image")
    s.add_argument("filename")
    s.add_argument("--out", help="output file path (default: ./{filename})")
    s.set_defaults(func=cmd_wallpapers_get)

    s = sub.add_parser("wallpapers-set", help="POST /wallpapers/{filename} — set the active wallpaper")
    s.add_argument("filename")
    s.set_defaults(func=cmd_wallpapers_set)

    # Music
    sub.add_parser("music-status", help="GET /music/status").set_defaults(func=cmd_music_status)
    sub.add_parser("music-play", help="POST /music/play").set_defaults(func=cmd_music_play)
    sub.add_parser("music-stop", help="POST /music/stop").set_defaults(func=cmd_music_stop)
    sub.add_parser("music-next", help="POST /music/next").set_defaults(func=cmd_music_next)

    s = sub.add_parser("music-playback", help="POST /music/playback/{type}")
    s.add_argument("type", help="playback mode (e.g. random, loop, single)")
    s.set_defaults(func=cmd_music_playback)

    sub.add_parser("music-playlist", help="GET /music/playlist — list available playlists").set_defaults(func=cmd_music_playlist)
    s = sub.add_parser("music-playlist-set", help="POST /music/playlist/{name} — switch active playlist")
    s.add_argument("name")
    s.set_defaults(func=cmd_music_playlist_set)

    # Scripts
    sub.add_parser("scripts-list", help="GET /scripts/list").set_defaults(func=cmd_scripts_list)

    s = sub.add_parser("scripts-launch", help="POST /scripts/launch/{filename}")
    s.add_argument("filename", help="script filename from /media/fat/Scripts/ (with .sh)")
    s.set_defaults(func=cmd_scripts_launch)

    sub.add_parser("scripts-console", help="POST /scripts/console — toggle the on-screen script console").set_defaults(func=cmd_scripts_console)

    s = sub.add_parser("scripts-kill", help="POST /scripts/kill — kill the currently running script")
    s.add_argument("--yes", action="store_true", help="confirm the kill")
    s.set_defaults(func=cmd_scripts_kill)

    # Settings
    sub.add_parser("settings-inis", help="GET /settings/inis — list and active INI").set_defaults(func=cmd_settings_inis)

    s = sub.add_parser("settings-inis-set", help='PUT /settings/inis with {"ini": <int>} — switch active INI')
    s.add_argument("ini", help="INI id (integer)")
    s.set_defaults(func=cmd_settings_inis_set)

    s = sub.add_parser("settings-ini-get", help="GET /settings/inis/{id} — read a key-value INI")
    s.add_argument("id")
    s.set_defaults(func=cmd_settings_ini_get)

    s = sub.add_parser("settings-ini-set", help="PUT /settings/inis/{id} — write a key-value INI from JSON")
    s.add_argument("id")
    s.add_argument("--from-file", dest="from_file", help="path to a JSON file with the key-value body")
    s.add_argument("--from-stdin", dest="from_stdin", action="store_true", help="read JSON body from stdin")
    s.set_defaults(func=cmd_settings_ini_set)

    s = sub.add_parser("settings-menu-mode", help='PUT /settings/core/menu with {"mode": <str>}')
    s.add_argument("mode")
    s.set_defaults(func=cmd_settings_menu_mode)

    s = sub.add_parser("settings-remote-restart", help="POST /settings/remote/restart — restart the Remote service")
    s.add_argument("--yes", action="store_true", help="confirm the restart")
    s.set_defaults(func=cmd_settings_remote_restart)

    s = sub.add_parser("settings-remote-log", help="GET /settings/remote/log — download the Remote service log")
    s.add_argument("--out", help="output file path (default: ./mister-remote.log)")
    s.set_defaults(func=cmd_settings_remote_log)

    sub.add_parser("settings-remote-peers", help="GET /settings/remote/peers — list known peer devices").set_defaults(func=cmd_settings_remote_peers)

    s = sub.add_parser("settings-remote-logo", help="GET /settings/remote/logo — download the Remote logo asset")
    s.add_argument("--out", help="output file path (default: ./mister-remote-logo)")
    s.set_defaults(func=cmd_settings_remote_logo)

    sub.add_parser("generate-mac", help="GET /settings/system/generate-mac — propose a fresh MAC address").set_defaults(func=cmd_generate_mac)

    s = sub.add_parser("reboot", help="POST /settings/system/reboot — full MiSTer restart")
    s.add_argument("--yes", action="store_true", help="confirm the reboot")
    s.set_defaults(func=cmd_reboot)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
