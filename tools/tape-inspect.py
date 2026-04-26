#!/usr/bin/env python3
"""Inspect an Oric .tap file: sync, header, name, and first 10 data bytes.

Handles multi-segment tapes (multiple back-to-back sync+header+payload blocks
in a single .tap file) by parsing each segment in turn.
"""

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
    suffix = f"<- {label}" if label else ""
    return f"  off={str(off):<4}  dec={b:>5}  hex={b:02X}    '{printable(b)}'  {suffix}"


def fmt_word(off_lo: int, off_hi: int, w: int, label: str = "") -> str:
    suffix = f"<- {label}" if label else ""
    rng = f"{off_lo}-{off_hi}"
    return f"  off={rng:<4}  dec={w:>5}  hex={w:04X}       {suffix}"


def parse_segment(data: bytes, offset: int, index: int):
    """Parse one tape segment starting at `offset` (where 0x16 sync begins).

    Returns the file offset just past this segment's payload, or None on error.
    """
    print(f"=== segment {index} (offset {offset}) ===")

    # ---- Sync zone ----
    i = offset
    while i < len(data) and data[i] == SYNC_BYTE:
        i += 1
    sync_count = i - offset

    if i >= len(data) or data[i] != SYNC_END:
        got = f"0x{data[i]:02X}" if i < len(data) else "EOF"
        print(f"sync : malformed — expected 0x16... 0x24, got {got} at offset {i}")
        return None

    bot_seg = i + 1  # first byte of header
    print(f"sync : {sync_count} x 0x16, then 0x24 at offset {i}")

    if len(data) < bot_seg + 9:
        print("hdr  : truncated — file too short for a 9-byte header")
        return None

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
    print(fmt_word(4, 5, end_addr,   "end address (big-endian)"))
    print(fmt_word(6, 7, start_addr, "start address (big-endian)"))
    print(fmt_byte(8, hdr[8], "separator"))

    payload_len = end_addr - start_addr + 1
    print(f"addr : start=${start_addr:04X}  end=${end_addr:04X}  "
          f"len={payload_len} bytes")

    # ---- Filename (null-terminated) ----
    name_off = bot_seg + 9
    nul = data.find(b"\x00", name_off)
    if nul < 0:
        print("name : no NUL terminator found")
        return None
    name_bytes = data[name_off:nul]
    name_str = name_bytes.decode("ascii", errors="replace") if name_bytes else "(empty)"
    print(f"name : \"{name_str}\"  ({len(name_bytes)} bytes + NUL)")

    # ---- First 10 program bytes, with absolute load addresses ----
    data_off = nul + 1
    n = min(10, len(data) - data_off, payload_len)
    print(f"data : first {n} bytes (file offset {data_off}, loads at ${start_addr:04X})")
    for k in range(n):
        b = data[data_off + k]
        addr = start_addr + k
        print(f"  ${addr:04X}  dec={b:>3}  hex={b:02X}  '{printable(b)}'")

    return data_off + payload_len


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <file.tap>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    data = path.read_bytes()
    print(f"file : {path}  ({len(data)} bytes)")

    offset = 0
    index = 1
    rc = 0
    while offset < len(data):
        # Scan forward to next sync run, tolerating any inter-segment padding.
        sync_start = data.find(bytes([SYNC_BYTE]), offset)
        if sync_start < 0:
            break
        if sync_start > offset:
            print(f"gap  : {sync_start - offset} non-sync byte(s) skipped before next segment")

        next_offset = parse_segment(data, sync_start, index)
        if next_offset is None:
            rc = 1
            break
        offset = next_offset
        index += 1

    print(f"segments: {index - 1}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
