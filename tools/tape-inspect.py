#!/usr/bin/env python3
"""Inspect an Oric .tap file: sync, header, name, and first 10 data bytes."""

import sys
from pathlib import Path

SYNC_BYTE = 0x16
SYNC_END  = 0x24

TYPE_NAMES = {
    0x00: "BASIC",
    0x80: "Machine code",
}

AUTO_NAMES = {
    0x00: "no auto-run",
    0xC7: "auto-run",
    0x80: "no auto-run (alt)",
}


def printable(b: int) -> str:
    return chr(b) if 0x20 <= b < 0x7F else "."


def fmt_byte(off: int, b: int, label: str = "") -> str:
    suffix = f"   <- {label}" if label else ""
    return f"  off={off:>3}  dec={b:>3}  hex={b:02X}  '{printable(b)}'{suffix}"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <file.tap>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    data = path.read_bytes()
    print(f"file : {path}  ({len(data)} bytes)")

    # ---- Sync zone ----
    sync_count = 0
    while sync_count < len(data) and data[sync_count] == SYNC_BYTE:
        sync_count += 1

    if sync_count >= len(data) or data[sync_count] != SYNC_END:
        print(f"sync : malformed — expected 0x16... 0x24, got 0x{data[sync_count]:02X} at offset {sync_count}")
        return 1

    bot_seg = sync_count + 1  # first byte of header
    print(f"sync : {sync_count} x 0x16, then 0x24 at offset {sync_count}")

    if len(data) < bot_seg + 9:
        print("hdr  : truncated — file too short for a 9-byte header")
        return 1

    # ---- Header (9 bytes from bot_seg) ----
    hdr = data[bot_seg : bot_seg + 9]
    type_byte = hdr[2]
    auto_byte = hdr[3]
    end_addr  = (hdr[4] << 8) | hdr[5]
    start_addr = (hdr[6] << 8) | hdr[7]

    print("hdr  :")
    print(fmt_byte(0, hdr[0], "reserved"))
    print(fmt_byte(1, hdr[1], "reserved"))
    print(fmt_byte(2, hdr[2], f"type ({TYPE_NAMES.get(type_byte, '?')})"))
    print(fmt_byte(3, hdr[3], f"auto ({AUTO_NAMES.get(auto_byte, '?')})"))
    print(fmt_byte(4, hdr[4], "end_hi"))
    print(fmt_byte(5, hdr[5], "end_lo"))
    print(fmt_byte(6, hdr[6], "start_hi"))
    print(fmt_byte(7, hdr[7], "start_lo"))
    print(fmt_byte(8, hdr[8], "separator"))

    print(f"addr : start=${start_addr:04X} ({start_addr})  "
          f"end=${end_addr:04X} ({end_addr})  "
          f"len={end_addr - start_addr + 1} bytes")

    # ---- Filename (null-terminated) ----
    name_off = bot_seg + 9
    nul = data.find(b"\x00", name_off)
    if nul < 0:
        print("name : no NUL terminator found")
        return 1
    name_bytes = data[name_off:nul]
    name_str = name_bytes.decode("ascii", errors="replace") if name_bytes else "(empty)"
    print(f"name : \"{name_str}\"  ({len(name_bytes)} bytes + NUL)")

    # ---- First 10 program bytes, with absolute load addresses ----
    data_off = nul + 1
    n = min(10, len(data) - data_off, end_addr - start_addr + 1)
    print(f"data : first {n} bytes (file offset {data_off}, loads at ${start_addr:04X})")
    for i in range(n):
        b = data[data_off + i]
        addr = start_addr + i
        print(f"  ${addr:04X}  dec={b:>3}  hex={b:02X}  '{printable(b)}'")

    return 0


if __name__ == "__main__":
    sys.exit(main())
