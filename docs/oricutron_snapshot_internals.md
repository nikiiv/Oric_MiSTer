# Oricutron snapshot internals

Reference for how the Oricutron emulator saves and restores its `.sna`
snapshot files. All of this lives in `snapshot.c`, with the public API
in `snapshot.h:23-24`:

```c
SDL_bool save_snapshot(struct machine *oric, char* filename);
SDL_bool load_snapshot(struct machine *oric, char* filename);
```

This document is the *producer/consumer* spec — it describes Oricutron's
own behaviour. The MiSTer core's compatibility layer is documented
separately in [`sna_support.md`](sna_support.md).

---

## File format overview

A snapshot is a flat sequence of **chunks**. Each chunk has an 8-byte
header:

| Bytes | Meaning                                                       |
| ----- | ------------------------------------------------------------- |
| 0–3   | 4-character ASCII ID (`"OSN\0"`, `"CPU\0"`, `"VIA\0"`, …)     |
| 4–7   | Big-endian 32-bit payload size (excludes the 8-byte header)   |

Some chunks own a separate `"DATA"` chunk that immediately follows
them. That's how variable-length blobs (RAM image, tape contents, disk
images) are attached to a fixed-size descriptor chunk. The loader links
each `DATA` block back to the previous block via
`bkh[i-1].datablock = &bkh[i]` (`snapshot.c:644-647`).

All multi-byte integers are **big-endian**. Strings are length-prefixed
with a 32-bit count that **includes the trailing NUL**
(`putstr`, `snapshot.c:96-101`).

---

## Saving — `save_snapshot` (`snapshot.c:151-550`)

### Writer machinery

The writer uses a 256 KiB scratch buffer (`MAX_BLOCK`, `snapshot.c:50`)
and a small DSL of macros:

| Macro                  | What it does                                                                                                                |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `NEWBLOCK("XYZ\0")`    | Flushes the previous block to disk, then begins a new one. Reserves bytes 0–7 for the header. (`snapshot.c:120-131`)        |
| `PUTU8` / `U16` / `U32`| Append big-endian integers. (`snapshot.c:54-83`)                                                                            |
| `PUTDATA(ptr, n)`      | Append raw bytes. (`snapshot.c:85-93`)                                                                                      |
| `PUTSTR(s)`            | Append a length-prefixed C string. (`snapshot.c:95-101`)                                                                    |
| `DATABLOCK(ptr, n)`    | Flushes the current block, then writes a `"DATA"` chunk straight from caller memory (bypasses the scratch). Used for RAM, tape, disk images. (`snapshot.c:133-149`) |
| `WRITEBLOCK()`         | Patches the size field at offset 4 and `fwrite`s the buffer. (`snapshot.c:103-117`)                                         |

### Block save order

1. **`OSN\0` — main / machine block** (`snapshot.c:174-186`)
   Machine type, overclock multiplier/shift, vsync state, ROM-disable /
   ROM-on flags, the vsync hack flag, drive type
   (`DRV_JASMIN` / `DRV_MICRODISC` / `DRV_PRAVETZ` / `DRV_NONE`),
   tape-turbo, video mode, keymap. Then a `DATA` chunk holding the
   **entire RAM image** (`oric->mem`, length `oric->memsize`).

2. **`TAP\0` — tape state** (`snapshot.c:188-205`)
   Bit/byte position, parity, tape length, current offset, byte counter,
   motor flag, raw-tape flag, header / turbo metadata, plus a `DATA`
   chunk with the tape buffer itself.

3. **`PCH\0` — patch points** (`snapshot.c:207-231`)
   PC addresses and target addresses for the floppy/tape ROM patch hooks
   (`pch_fd_*`, `pch_tt_*`). Required because Oricutron patches the ROM
   at runtime to accelerate I/O.

4. **`CPU\0` — 6502 state** (`snapshot.c:233-248`)
   Cycle count, `PC`, `lastpc`, `calcpc`, `calcint`, NMI flag, A/X/Y/SP,
   the packed flags byte (`MAKEFLAGS`), IRQ flag, NMI counter, current
   opcode.

5. **`AY\0\0` — AY-3-8912 sound chip** (`snapshot.c:250-283`)
   Bus mode, current register, all 14 register copies (`eregs`),
   keyboard row state (8 bytes — keyboard goes through PSG ports),
   tone / noise / envelope periods, per-channel tone / noise / volume
   bits, output sample, channel counters and step state, envelope
   position, noise PRNG accumulator, key-scan delay state.

6. **`VIA\0` — main 6522 VIA** (`snapshot.c:285-319`)
   Every register and internal latch: IFR, IRA / IRB / IRAL / IRBL,
   ORA / ORB, DDRA / DDRB, T1 / T2 latches and counters, SR, ACR, PCR,
   IER, CA1 / CA2 / CB1 / CB2 line states, SR bit count and timing,
   run flags, pulse flags, IRQ-bit cache.

7. **Drive-controller block(s)** depending on `oric->drivetype`
   (`snapshot.c:322-387`):
   - **`JSM\0`** — Jasmin overlay / ROM-disable. Sets `do_wd17xx`.
   - **`MDC\0`** — Microdisc status, INTRQ, DRQ, disk-ROM flag. Sets
     `do_wd17xx`.
   - **`PRV\0`** — Pravetz overlay, ROM-disable, extension, current
     drive, currentop. Then for each of two drives: volume, select,
     motor, write-ready, byte / half-track position, dirty / protect
     flags. **Both drive images are concatenated into one `DATA` block**
     because the format only allows one `DATA` per chunk
     (see comment at `snapshot.c:362-366`).
     Per-drive image headers (`PVD\0`) follow with the rawimage length,
     the sector pointer **converted to an offset** from the rawimage
     base (`0xffffffff` if NULL), and the rawimage payload.

8. **`WDD\0` — WD17xx FDC** (only if `do_wd17xx`, `snapshot.c:389-425`)
   All controller registers and current op state, plus one **`DSK\0`**
   chunk per attached disk (up to 4): drive number, geometry
   (numtracks, numsides, geometry, cached track / side), rawimage
   length, and a `DATA` chunk with the rawimage bytes.

9. **Telestrat extras** (only if `oric->type == MACH_TELESTRAT`,
   `snapshot.c:427-474`)
   - **`BNK\0`** — types of all 8 banks plus current bank.
   - **`ACI\0`** — ACIA (6551) register file.
   - **`TVA\0`** — second VIA, same layout as `VIA\0`.

10. **Symbols and breakpoints** (`snapshot.c:476-530`) — `SYR\0` (ROM
    symbols), `SYU\0` (user symbols), `SY0`–`SY7` (Telestrat per-bank
    symbols) using length-prefixed strings; and `BKP\0` with 16 PC
    breakpoints + 16 memory breakpoints. Only written if non-empty.

11. Final `WRITEBLOCK()` flushes whatever's still in the scratch buffer;
    the file is closed and the buffer is freed.

On the WWW (Emscripten) build, `EM_ASM(FS.syncfs(...))` runs at the end
so the file is persisted out of the in-memory FS
(`snapshot.c:539-547`).

---

## Loading — `load_snapshot` (`snapshot.c:797-1560`)

The loader is **two-pass and random-access** rather than streaming.

### Pass 1 — index the file (`getheaders`, `snapshot.c:567-655`)

Reads through the file from start to end, validating each 8-byte header
against the file size, and records `{id, file_offset_of_payload,
payload_size}` into an array `bkh[]` of `struct blockheader`. While
walking, any `DATA` block is attached to the previous block
(`bkh[i-1].datablock`).

### Helpers

- `load_block(id, expectedsize, datarequired)` — finds a block by ID,
  optionally enforces an exact payload size and the presence of a
  `DATA` chunk, allocates a buffer, `fseek`s and reads the payload
  (`snapshot.c:677-730`). It is **idempotent**: a second call returns
  the cached buffer with `offs` rewound. The payload is then consumed
  with `getu8` / `getu16` / `getu32` / `getdata`
  (`snapshot.c:756-795`) which advance `blk->offs`.
- `read_block(blk, dest)` — used for blobs that go straight into a
  target buffer (RAM, tape, disk image) instead of into a temporary
  cache (`snapshot.c:732-754`).

### Pass 2 — restore state in a fixed order

1. **`OSN\0` first** (`snapshot.c:820-826`).
   Reads `type` and `drivetype` straight from the buffer at offsets 0
   and 14. Validates `type < MACH_LAST`.

2. **`swapmach(oric, NULL, (drivetype<<16)|type)`** (`snapshot.c:840`).
   This is the key step: it reconfigures the emulator (allocates RAM of
   the right size, loads the correct ROM, sets drive-controller
   bookkeeping, etc.) **before** any state is restored. After this,
   `oric->memsize` and `oric->drivetype` are checked against what's in
   the file; mismatch → abort (`snapshot.c:843-851`).

3. **RAM** is read directly into `oric->mem` via
   `read_block(blk->datablock, …, oric->mem)` (`snapshot.c:854`).

4. **Clean slate for things being replaced** — `clear_patches(oric)` and
   free the existing tape buffer (`snapshot.c:863-869`) so the
   snapshot's values aren't merged with stale state.

5. The rest of the OSN payload (offsets 1–20: overclock, vsync, romdis,
   romon, vsynchack, tapeturbo, vid_mode, keymap) is then consumed via
   the `getu*` helpers (`snapshot.c:871-882`). Note: the `drivetype`
   byte at offset 14 is skipped (`blk->offs++`, `snapshot.c:878`)
   because it's already been consumed.

6. Video bookkeeping (`vid_freq`, `vid_addr`, `vid_ch_base`) is
   **recomputed** from the restored `vid_mode` and the static
   `vidbases[]` table (`snapshot.c:886-896`). Those derived pointers
   aren't stored.

7. **`CPU\0`** restored, including `SETFLAGS(i)` to unpack the flags
   byte back into the individual P-register bits
   (`snapshot.c:898-926`).

8. **`AY\0\0`** restored. After loading `eregs`, `ay.regs` is also
   overwritten with `eregs` (`snapshot.c:942`) because at runtime the AY
   has both an "external" register snapshot and a "live" copy.

9. **`VIA\0`** restored (`snapshot.c:976-1022`).

10. **`TAP\0`** restored (`snapshot.c:1024-1081`). Reallocates `tapebuf`
    to match the saved size and reads the `DATA` payload into it; if
    there's no datablock, length is forced to 0.

11. **`PCH\0`** is **optional** (`required=SDL_FALSE`,
    `snapshot.c:1084-1111`) — older snapshots may not have it.

12. **Drive controller** (`snapshot.c:1113-1282`):
    - `JSM\0` / `MDC\0` — read state; sets `do_wd17xx = SDL_TRUE`.
    - `PRV\0` (Pravetz) — read state into a temp buffer, then split the
      concatenated 2-drive raw image back into
      `pravetz.drv[0/1].image`. Then iteratively read `PVD\0` blocks
      (`snapshot.c:1208-1280`): each one allocates a `diskimage`,
      allocates the rawimage payload, reads it in, restores the
      rawimage length and converts the saved offset back into a
      `sector_ptr` (`0xffffffff` → NULL). Files are given synthetic
      names `SNAPDISK<i>.DSK` under `diskpath`.
      `blk->id[0]=0` is a trick to mark the block "consumed" so the
      next `load_block("PVD\0", …)` finds the next one rather than the
      same one.

13. **`WDD\0`** + iterative `DSK\0` blocks (`snapshot.c:1284-1401`)
    when `do_wd17xx`. Same iteration trick. After the rawimage is
    loaded, `diskimage_cachetrack(...)` repopulates the track cache,
    and `wd17xx_find_sector(...)` re-derives `currsector` for the
    active drive — those pointers, like the video pointers, are
    recomputed rather than serialized.

14. **Telestrat extras** when `type == MACH_TELESTRAT`
    (`snapshot.c:1403-1500`): `BNK\0`, `ACI\0`, `AUX\0` (read but not
    parsed beyond loading the block), `TVA\0`.

15. **Symbols and breakpoints** are loaded only under
    `#ifdef WWW_MONITOR` (`snapshot.c:1502-1553`). The `BKP\0` parser
    uses signed 32-bit reads (`gets32`) and walks both PC and memory
    breakpoints, recomputing the `anybp` / `anymbp` summary flags.

16. **Cleanup** — `free_blockheaders()` releases the index and any
    cached block buffers, the file is closed, `setmenutoggles(oric)`
    refreshes GUI checkmarks against the freshly-loaded state, and if
    the user was in the debug monitor before the load,
    `setemumode(EM_DEBUG)` puts them back.

---

## Notes worth flagging

- **Forward compatibility is rigid** for required blocks. Most calls to
  `load_block` pass an explicit `expectedsize` (e.g. 21, 153, 39, 46)
  and reject the file on mismatch (`snapshot.c:700-705`). Adding fields
  to those blocks is a hard format break. The optional `PCH\0` block is
  the model for safer evolution.

- **Backward compatibility hooks**: `PCH\0` and `BKP\0` are loaded with
  `required=SDL_FALSE`, so older snapshots without them still load.

- **Derived state is intentionally not saved**: video address pointers,
  the WD17xx track cache, `currsector`, AY `regs` (vs `eregs`) — these
  are reconstructed from primary state during load.

- **`swapmach` ordering matters**: every state restore happens *after*
  the machine has been reconfigured, so `oric->mem`, `oric->drivetype`,
  ROM contents, etc. are guaranteed consistent.

- **GUI entry points** are `savesnap` / `loadsnap` in
  `gui.c:1391-1403`; they prompt for a path (default `snapshots/`
  directory) and call straight into `save_snapshot` / `load_snapshot`.
  Snapshots are also auto-detected when a file is dropped into the
  loader (`gui.c:1009-1012`, `gui.c:1234-1237`) via `IMG_SNAPSHOT` in
  `machine.h:77`.

---

## Block-ID quick reference

| ID         | Required | Has DATA? | Fixed size | Contents                              |
| ---------- | -------- | --------- | ---------- | ------------------------------------- |
| `OSN\0`    | yes      | yes (RAM) | 21         | Machine config + RAM image            |
| `TAP\0`    | yes      | optional  | 46         | Tape state + tape buffer              |
| `PCH\0`    | no       | no        | 76         | ROM patch addresses                   |
| `CPU\0`    | yes      | no        | 21         | 6502 register file                    |
| `AY\0\0`   | yes      | no        | 153        | PSG state                             |
| `VIA\0`    | yes      | no        | 39         | 6522 VIA state                        |
| `JSM\0`    | yes (Jasmin)     | no | 2  | Jasmin controller                     |
| `MDC\0`    | yes (Microdisc)  | no | 4  | Microdisc controller                  |
| `PRV\0`    | yes (Pravetz)    | yes | 9+2*10 | Pravetz controller + raw images   |
| `PVD\0`    | no (iterated)    | yes | 10  | Per-drive Pravetz disk image      |
| `WDD\0`    | yes (WD17xx)     | no | 38  | WD17xx FDC state                      |
| `DSK\0`    | no (iterated)    | yes | 16  | Per-drive disk image (WD17xx)     |
| `BNK\0`    | yes (Telestrat)  | no | 9   | Bank types + current bank             |
| `ACI\0`    | yes (Telestrat)  | no | ACIA_LAST | ACIA register file              |
| `AUX\0`    | yes (Telestrat)  | no | ACIA_LAST | (Read but not parsed)           |
| `TVA\0`    | yes (Telestrat)  | no | 39  | Telestrat second VIA                  |
| `SYR\0`    | no               | no | var | ROM symbols (length-prefixed)      |
| `SYU\0`    | no               | no | var | User symbols                       |
| `SY0`–`SY7`| no (Telestrat)   | no | var | Per-bank symbols                  |
| `BKP\0`    | no (debug build) | no | 128 | 16 PC + 16 mem breakpoints         |
| `DATA`     | —        | —         | var        | Payload of the previous chunk         |
