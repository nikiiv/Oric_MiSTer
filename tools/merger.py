#!/usr/bin/env python3
"""Concatenate multiple Oric .tap files into a single multi-segment tape.

Inputs are appended in command-line order. Optionally rewrites CLOAD as PRINT
in every BASIC segment of every input before concatenation.

Usage:
    python3 tools/merger.py -o OUT [--replace-cload] INPUT [INPUT ...]
"""

import argparse
import sys
from pathlib import Path

SYNC_BYTE = 0x16
SYNC_END  = 0x24

TOK_CLOAD = 0xB6
TOK_PRINT = 0xBA

TYPE_NAMES = {0x00: "BASIC", 0x80: "Machine code"}


def parse_segment(data: bytes, offset: int):
    """Locate one segment starting at `offset`.

    Returns (type_byte, name, start_addr, payload_off, payload_len, next_offset)
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
    return type_byte, name, start_addr, payload_off, payload_len, payload_off + payload_len


def patch_basic(buf: bytearray, payload_off: int, payload_len: int, load_addr: int) -> int:
    """Walk BASIC lines in buf[payload_off:payload_off+payload_len] and flip
    CLOAD (0xB6) -> PRINT (0xBA) outside string literals. Returns count."""
    end = payload_off + payload_len
    p = payload_off
    replaced = 0
    while p + 4 <= end:
        nxt = buf[p] | (buf[p + 1] << 8)
        if nxt == 0:
            break
        try:
            line_end = buf.index(0x00, p + 4, end)
        except ValueError:
            break
        in_string = False
        for q in range(p + 4, line_end):
            b = buf[q]
            if in_string:
                if b == 0x22:
                    in_string = False
            elif b == 0x22:
                in_string = True
            elif b == TOK_CLOAD:
                buf[q] = TOK_PRINT
                replaced += 1
        next_p = nxt - load_addr + payload_off
        if next_p <= p or next_p >= end:
            break
        p = next_p
    return replaced


def process_input(buf: bytearray, replace_cload: bool):
    """Walk every segment in `buf`. Returns (segment_count, basic_count, replaced).

    Patches BASIC payloads in place when replace_cload is True.
    Raises ValueError if no valid segment is found at all.
    """
    offset = 0
    seg_count = 0
    basic_count = 0
    replaced = 0
    while offset < len(buf):
        sync_start = buf.find(bytes([SYNC_BYTE]), offset)
        if sync_start < 0:
            break
        type_byte, _name, start_addr, payload_off, payload_len, next_off = \
            parse_segment(bytes(buf), sync_start)
        seg_count += 1
        if type_byte == 0x00:
            basic_count += 1
            if replace_cload:
                replaced += patch_basic(buf, payload_off, payload_len, start_addr)
        offset = next_off
    if seg_count == 0:
        raise ValueError("no valid tape segment found")
    return seg_count, basic_count, replaced


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("-o", "--output", required=True, type=Path,
                    help="destination .tap file")
    ap.add_argument("--replace-cload", action="store_true",
                    help="rewrite CLOAD as PRINT in every BASIC segment of every input")
    ap.add_argument("inputs", nargs="+", type=Path,
                    help="source .tap files, merged in order")
    args = ap.parse_args()

    out_resolved = args.output.resolve()
    for inp in args.inputs:
        if inp.resolve() == out_resolved:
            print(f"refusing to overwrite input {inp} via --output", file=sys.stderr)
            return 2

    print(f"output : {args.output}", file=sys.stderr)
    merged = bytearray()
    total_replaced = 0
    for inp in args.inputs:
        try:
            buf = bytearray(inp.read_bytes())
        except OSError as e:
            print(f"error reading {inp}: {e}", file=sys.stderr)
            return 1
        try:
            seg_count, basic_count, replaced = process_input(buf, args.replace_cload)
        except ValueError as e:
            print(f"error in {inp}: {e}", file=sys.stderr)
            return 1

        seg_word = "segment" if seg_count == 1 else "segments"
        if args.replace_cload:
            note = (f"{replaced} CLOAD->PRINT across {basic_count} BASIC"
                    if basic_count else "no BASIC segments")
            print(f"  + {inp} ({len(buf)} bytes, {seg_count} {seg_word}, {note})",
                  file=sys.stderr)
        else:
            print(f"  + {inp} ({len(buf)} bytes, {seg_count} {seg_word})",
                  file=sys.stderr)
        merged.extend(buf)
        total_replaced += replaced

    args.output.write_bytes(bytes(merged))
    if args.replace_cload:
        print(f"total  : {len(merged)} bytes, {len(args.inputs)} input(s), "
              f"{total_replaced} replacement(s)", file=sys.stderr)
    else:
        print(f"total  : {len(merged)} bytes, {len(args.inputs)} input(s)",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
