#!/usr/bin/env python3
"""Inspect an Oric .tap file: sync, header, name, and segment payload.

Handles multi-segment tapes. Verbosity selectable via three switches:

  --short  (default) first 10 bytes preview for every segment
  --basic  BASIC detokenized; machine code = 10-byte preview
  --full   BASIC detokenized; machine code = 16 hex + 16 decimal per row
"""

import argparse
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

# Oric Atmos BASIC v1.1 keyword tokens (byte >= 0x80 in tokenized programs).
TOKENS = {
    0x80: "END",     0x81: "EDIT",    0x82: "STORE",   0x83: "RECALL",
    0x84: "TRON",    0x85: "TROFF",   0x86: "POP",     0x87: "PLOT",
    0x88: "PULL",    0x89: "LORES",   0x8A: "DOKE",    0x8B: "REPEAT",
    0x8C: "UNTIL",   0x8D: "FOR",     0x8E: "LLIST",   0x8F: "LPRINT",
    0x90: "NEXT",    0x91: "DATA",    0x92: "INPUT",   0x93: "DIM",
    0x94: "CLS",     0x95: "READ",    0x96: "LET",     0x97: "GOTO",
    0x98: "RUN",     0x99: "IF",      0x9A: "RESTORE", 0x9B: "GOSUB",
    0x9C: "RETURN",  0x9D: "REM",     0x9E: "HIMEM",   0x9F: "GRAB",
    0xA0: "RELEASE", 0xA1: "TEXT",    0xA2: "HIRES",   0xA3: "SHOOT",
    0xA4: "EXPLODE", 0xA5: "ZAP",     0xA6: "PING",    0xA7: "SOUND",
    0xA8: "MUSIC",   0xA9: "PLAY",    0xAA: "CURSET",  0xAB: "CURMOV",
    0xAC: "DRAW",    0xAD: "CIRCLE",  0xAE: "PATTERN", 0xAF: "FILL",
    0xB0: "CHAR",    0xB1: "PAPER",   0xB2: "INK",     0xB3: "STOP",
    0xB4: "ON",      0xB5: "WAIT",    0xB6: "CLOAD",   0xB7: "CSAVE",
    0xB8: "DEF",     0xB9: "POKE",    0xBA: "PRINT",   0xBB: "CONT",
    0xBC: "LIST",    0xBD: "CLEAR",   0xBE: "GET",     0xBF: "CALL",
    0xC0: "!",       0xC1: "NEW",     0xC2: "TAB(",    0xC3: "TO",
    0xC4: "FN",      0xC5: "SPC(",    0xC6: "@",       0xC7: "AUTO",
    0xC8: "ELSE",    0xC9: "THEN",    0xCA: "NOT",     0xCB: "STEP",
    0xCC: "+",       0xCD: "-",       0xCE: "*",       0xCF: "/",
    0xD0: "^",       0xD1: "AND",     0xD2: "OR",      0xD3: ">",
    0xD4: "=",       0xD5: "<",       0xD6: "SGN",     0xD7: "INT",
    0xD8: "ABS",     0xD9: "USR",     0xDA: "FRE",     0xDB: "POS",
    0xDC: "HEX$",    0xDD: "&",       0xDE: "SQR",     0xDF: "RND",
    0xE0: "LN",      0xE1: "EXP",     0xE2: "COS",     0xE3: "SIN",
    0xE4: "TAN",     0xE5: "ATN",     0xE6: "PEEK",    0xE7: "DEEK",
    0xE8: "LOG",     0xE9: "LEN",     0xEA: "STR$",    0xEB: "VAL",
    0xEC: "ASC",     0xED: "CHR$",    0xEE: "PI",      0xEF: "TRUE",
    0xF0: "FALSE",   0xF1: "KEY$",    0xF2: "SCRN",    0xF3: "POINT",
    0xF4: "LEFT$",   0xF5: "RIGHT$",  0xF6: "MID$",    0xF7: "GO",
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


def detokenize_line(body: bytes) -> str:
    out = []
    in_string = False
    for b in body:
        if in_string:
            out.append(chr(b) if 0x20 <= b < 0x7F else f"\\x{b:02X}")
            if b == 0x22:  # closing "
                in_string = False
        elif b < 0x80:
            out.append(chr(b) if 0x20 <= b < 0x7F else f"\\x{b:02X}")
            if b == 0x22:  # opening "
                in_string = True
        else:
            out.append(TOKENS.get(b, f"[${b:02X}]"))
    return "".join(out)


def print_basic(payload: bytes, load_addr: int) -> None:
    p = 0
    line_count = 0
    while p + 4 <= len(payload):
        nxt = payload[p] | (payload[p + 1] << 8)
        if nxt == 0:
            break
        line_no = payload[p + 2] | (payload[p + 3] << 8)
        try:
            end = payload.index(b"\x00", p + 4)
        except ValueError:
            print(f"  ! line {line_no}: missing 0x00 terminator before end of payload")
            break
        body = payload[p + 4:end]
        print(f"  {line_no:>5}  {detokenize_line(body)}")
        line_count += 1
        next_p = nxt - load_addr
        if next_p <= p or next_p >= len(payload):
            print(f"  ! corrupt next-line link ${nxt:04X} (out of payload)")
            break
        p = next_p
    print(f"lines: {line_count}")


def print_hex_short(payload: bytes, load_addr: int, file_off: int, n: int = 10) -> None:
    n = min(n, len(payload))
    print(f"data : first {n} bytes (file offset {file_off}, loads at ${load_addr:04X})")
    for i in range(n):
        b = payload[i]
        addr = load_addr + i
        print(f"  ${addr:04X}  dec={b:>3}  hex={b:02X}  '{printable(b)}'")


def print_hex_long(payload: bytes, load_addr: int, file_off: int) -> None:
    print(f"data : {len(payload)} bytes (file offset {file_off}, loads at ${load_addr:04X})")
    for row in range(0, len(payload), 16):
        chunk = payload[row:row + 16]
        addr = load_addr + row
        hex_cells = [f"{b:02X}" for b in chunk] + ["  "] * (16 - len(chunk))
        dec_cells = [f"{b:>3}" for b in chunk] + ["   "] * (16 - len(chunk))
        print(f"  ${addr:04X}  {' '.join(hex_cells)}\t{' '.join(dec_cells)}")


SEG_RULE = "=" * 60


def parse_segment(data: bytes, offset: int, index: int, mode: str):
    """Parse one tape segment starting at `offset` (where 0x16 sync begins).

    Returns the file offset just past this segment's payload, or None on error.
    """
    if index > 1:
        print()
    print(SEG_RULE)
    print(f"  segment {index}  (file offset {offset})")
    print(SEG_RULE)

    # ---- Sync zone ----
    i = offset
    while i < len(data) and data[i] == SYNC_BYTE:
        i += 1
    sync_count = i - offset

    if i >= len(data) or data[i] != SYNC_END:
        got = f"0x{data[i]:02X}" if i < len(data) else "EOF"
        print(f"sync : malformed — expected 0x16... 0x24, got {got} at offset {i}")
        return None

    bot_seg = i + 1
    print(f"sync : {sync_count} x 0x16, then 0x24 at offset {i}")

    if len(data) < bot_seg + 9:
        print("hdr  : truncated — file too short for a 9-byte header")
        return None

    # ---- Header (9 bytes from bot_seg) ----
    hdr = data[bot_seg:bot_seg + 9]
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

    # ---- Payload ----
    data_off = nul + 1
    payload = data[data_off:data_off + payload_len]

    if mode == "short":
        print_hex_short(payload, start_addr, data_off)
    elif type_byte == 0x00:
        print(f"basic: detokenized program ({payload_len} bytes)")
        print_basic(payload, start_addr)
    elif mode == "full":
        print_hex_long(payload, start_addr, data_off)
    else:
        print_hex_short(payload, start_addr, data_off)

    return data_off + payload_len


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--short", dest="mode", action="store_const", const="short",
                   help="first 10 bytes preview for every segment (default)")
    g.add_argument("--basic", dest="mode", action="store_const", const="basic",
                   help="BASIC segments detokenized as source; "
                        "machine code = 10-byte preview")
    g.add_argument("--full",  dest="mode", action="store_const", const="full",
                   help="BASIC detokenized; machine code dumped as 16 bytes "
                        "hex then tab then 16 bytes decimal per row")
    ap.set_defaults(mode="short")
    ap.add_argument("file", type=Path, help="path to .tap file")
    args = ap.parse_args()

    data = args.file.read_bytes()
    print(f"file : {args.file}  ({len(data)} bytes)")

    offset = 0
    index = 1
    rc = 0
    while offset < len(data):
        sync_start = data.find(bytes([SYNC_BYTE]), offset)
        if sync_start < 0:
            break
        if sync_start > offset:
            print(f"gap  : {sync_start - offset} non-sync byte(s) skipped before next segment")

        next_offset = parse_segment(data, sync_start, index, args.mode)
        if next_offset is None:
            rc = 1
            break
        offset = next_offset
        index += 1

    print(f"segments: {index - 1}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
