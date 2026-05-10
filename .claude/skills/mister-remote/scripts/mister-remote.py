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


def base_url(args):
    return f"http://{args.host}:{args.port}/api"


def _request(method, url, *, data=None, timeout=5):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
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


def _get_json(args, path, *, timeout=None):
    timeout = timeout if timeout is not None else args.timeout
    with _request("GET", base_url(args) + path, timeout=timeout) as resp:
        return json.load(resp)


def _post(args, path, *, data=None, timeout=None):
    timeout = timeout if timeout is not None else args.timeout
    with _request("POST", base_url(args) + path, data=data, timeout=timeout) as resp:
        raw = resp.read()
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw.decode("utf-8", errors="replace")


def _print_json(value):
    if value is None:
        return
    if isinstance(value, str):
        print(value)
        return
    print(json.dumps(value, indent=2, sort_keys=True))


def cmd_sysinfo(args):
    _print_json(_get_json(args, "/sysinfo"))


def cmd_playing(args):
    _print_json(_get_json(args, "/games/playing"))


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
    _print_json(_post(args, f"/systems/{urllib.parse.quote(args.id, safe='')}"))


def cmd_launch_game(args):
    _print_json(_post(args, "/games/launch", data={"path": args.path}))


def cmd_launch(args):
    _print_json(_post(args, "/launch", data={"path": args.path}))


def cmd_launch_menu(args):
    _print_json(_post(args, "/launch/menu"))


def cmd_menu_view(args):
    _print_json(_post(args, "/menu/view", data={"path": args.path}))


def _validate_key(name):
    if name not in VALID_KEY_NAMES:
        sys.stderr.write(f"unknown key name: {name!r}\nvalid names:\n")
        for n in VALID_KEY_NAMES:
            sys.stderr.write(f"  {n}\n")
        sys.exit(1)


def cmd_key(args):
    _validate_key(args.name)
    _print_json(_post(args, f"/controls/keyboard/{urllib.parse.quote(args.name, safe='')}"))


def cmd_key_raw(args):
    _print_json(_post(args, f"/controls/keyboard-raw/{int(args.code)}"))


def cmd_keys(args):
    for n in args.names:
        _validate_key(n)
    for i, n in enumerate(args.names):
        if i:
            time.sleep(args.delay)
        _post(args, f"/controls/keyboard/{urllib.parse.quote(n, safe='')}")
        print(f"sent: {n}")


def cmd_reset_core(args):
    _post(args, "/controls/keyboard/reset")
    print("sent: reset")


def cmd_reboot(args):
    if not args.yes:
        sys.stderr.write(
            "refusing to reboot without --yes (this restarts the entire MiSTer).\n"
        )
        sys.exit(1)
    timeout = max(args.timeout, 30)
    _post(args, "/settings/system/reboot", timeout=timeout)
    print("reboot requested")


def cmd_screenshot(args):
    _print_json(_post(args, "/screenshots"))


def cmd_screenshot_list(args):
    _print_json(_get_json(args, "/screenshots"))


DEFAULT_SCREENSHOT_DIR = "mister_screenshots"


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


def _download_screenshot(args, core, filename, out_path):
    url = base_url(args) + f"/screenshots/{urllib.parse.quote(core, safe='')}/{urllib.parse.quote(filename, safe='')}"
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with _request("GET", url, timeout=args.timeout) as resp, out_path.open("wb") as fh:
        shutil.copyfileobj(resp, fh)
    return out_path


def cmd_screenshot_get(args):
    out = _resolve_screenshot_out(args, args.filename)
    path = _download_screenshot(args, args.core, args.filename, out)
    print(str(path))


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
    path = _download_screenshot(args, new_item["core"], new_item["filename"], out)
    print(json.dumps(
        {"core": new_item["core"], "filename": new_item["filename"], "saved_to": str(path)},
        indent=2,
    ))


def build_parser():
    p = argparse.ArgumentParser(
        prog="mister-remote",
        description="Talk to the mrext Remote HTTP API on a MiSTer FPGA.",
    )
    p.add_argument("--host", default=os.environ.get("MISTER_HOST", "mister.local"))
    p.add_argument("--port", type=int, default=int(os.environ.get("MISTER_PORT", "8182")))
    p.add_argument("--timeout", type=float, default=5.0)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("sysinfo", help="GET /sysinfo").set_defaults(func=cmd_sysinfo)
    sub.add_parser("playing", help="GET /games/playing").set_defaults(func=cmd_playing)
    sub.add_parser("systems", help="GET /systems (id/category/name)").set_defaults(func=cmd_systems)

    s = sub.add_parser("launch-system", help="POST /systems/{id}")
    s.add_argument("id")
    s.set_defaults(func=cmd_launch_system)

    s = sub.add_parser("launch-game", help='POST /games/launch with {"path": ...}')
    s.add_argument("path", help="absolute path on the MiSTer (e.g. /media/usb0/games/Oric/dsk/foo.dsk)")
    s.set_defaults(func=cmd_launch_game)

    s = sub.add_parser("launch", help='POST /launch — generic launcher for .rbf, .mra, .mgl, or game files')
    s.add_argument("path", help="absolute path on the MiSTer (e.g. /media/fat/_Aoric/Oric.rbf)")
    s.set_defaults(func=cmd_launch)

    sub.add_parser("launch-menu", help="POST /launch/menu (exits running core, soft-resets to MiSTer menu)").set_defaults(func=cmd_launch_menu)

    s = sub.add_parser("menu-view", help="POST /menu/view — list a directory on the MiSTer (discover cores/games)")
    s.add_argument("path", help="absolute directory path on the MiSTer (e.g. /media/fat/_Aoric or /media/fat/_Computer)")
    s.set_defaults(func=cmd_menu_view)

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

    s = sub.add_parser("reboot", help="POST /settings/system/reboot (full MiSTer restart)")
    s.add_argument("--yes", action="store_true", help="confirm the reboot")
    s.set_defaults(func=cmd_reboot)

    sub.add_parser("screenshot", help="POST /screenshots (capture)").set_defaults(func=cmd_screenshot)
    sub.add_parser("screenshot-list", help="GET /screenshots").set_defaults(func=cmd_screenshot_list)

    s = sub.add_parser("screenshot-get", help="download a screenshot to a local file")
    s.add_argument("core")
    s.add_argument("filename")
    s.add_argument("--out", help=f"output path or directory (default: ./{DEFAULT_SCREENSHOT_DIR}/{{filename}})")
    s.set_defaults(func=cmd_screenshot_get)

    s = sub.add_parser("screenshot-capture-and-download", help="capture, then download to a local file")
    s.add_argument("--out", help=f"output path or directory (default: ./{DEFAULT_SCREENSHOT_DIR}/{{filename}})")
    s.set_defaults(func=cmd_screenshot_capture_and_download)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
