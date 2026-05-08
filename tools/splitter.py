#!/usr/bin/env python3
"""Split a multi-segment Oric .tap file into one file per segment.

Each segment is written as a self-contained tape file alongside the input,
with names <stem>_0.tap, <stem>_1.tap, ... in the original directory. Any
inter-segment padding or trailing junk in the input is dropped.

Usage:
    python3 tools/splitter.py <file.tap>
"""

import argparse
import sys
from pathlib import Path

SYNC_BYTE = 0x16
SYNC_END  = 0x24

TYPE_NAMES = {0x00: "BASIC", 0x80: "Machine code"}


def parse_segment(data: bytes, offset: int):
    """Locate one segment starting at `offset`.

    Returns (sync_start, type_byte, name, payload_off, payload_len, next_offset)
    or raises ValueError on malformed framing.
    """
    i = offset
    while i < len(data) and data[i] == SYNC_BYTE:
        i += 1
    if i >= len(data) or data[i] != SYNC_END:
        raise ValueError(f"malformed sync at offset {offset}")
    bot = i + 1
    if len(data) < bot + 9:
        raise ValueError(f"truncated header at offset {bot}")
    hdr = data[bot:bot + 9]
    type_byte  = hdr[2]
    end_addr   = (hdr[4] << 8) | hdr[5]
    start_addr = (hdr[6] << 8) | hdr[7]
    payload_len = end_addr - start_addr + 1
    nul = data.find(b"\x00", bot + 9)
    if nul < 0:
        raise ValueError(f"missing name terminator after header at {bot + 9}")
    name = data[bot + 9:nul].decode("ascii", errors="replace")
    payload_off = nul + 1
    return offset, type_byte, name, payload_off, payload_len, payload_off + payload_len


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("input", type=Path, help="multi-segment .tap file")
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing output files")
    args = ap.parse_args()

    data = args.input.read_bytes()
    print(f"input  : {args.input} ({len(data)} bytes)", file=sys.stderr)

    # First pass: locate every segment and decide output paths.
    segments = []
    offset = 0
    while offset < len(data):
        sync_start = data.find(bytes([SYNC_BYTE]), offset)
        if sync_start < 0:
            break
        try:
            seg = parse_segment(data, sync_start)
        except ValueError as e:
            print(f"  ! {e} — stopping segment scan", file=sys.stderr)
            return 1
        segments.append(seg)
        offset = seg[5]  # next_offset

    if not segments:
        print("no valid tape segment found", file=sys.stderr)
        return 1

    stem = args.input.stem
    parent = args.input.parent
    suffix = args.input.suffix or ".tap"
    out_paths = [parent / f"{stem}_{i}{suffix}" for i in range(len(segments))]

    if not args.force:
        existing = [p for p in out_paths if p.exists()]
        if existing:
            for p in existing:
                print(f"refusing to overwrite {p} (use --force)", file=sys.stderr)
            return 2

    for i, ((sync_start, type_byte, name, payload_off, payload_len, next_off), out) \
            in enumerate(zip(segments, out_paths)):
        seg_bytes = data[sync_start:payload_off + payload_len]
        out.write_bytes(seg_bytes)
        type_label = TYPE_NAMES.get(type_byte, f"type ${type_byte:02X}")
        print(f"  -> {out} ({len(seg_bytes)} bytes, {type_label} \"{name}\")",
              file=sys.stderr)

    print(f"total  : {len(segments)} segment(s) written", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
