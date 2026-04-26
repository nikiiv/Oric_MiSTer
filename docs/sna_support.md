# Oricutron-compatible snapshot (.sna) support

Working reference for snapshot save/restore in this core. The on-FPGA
implementation is not yet built; this doc captures the file-format
contract and the mapping from Oricutron fields to our RTL signals so the
implementation phase can proceed without re-deriving any of it.

## Why snapshots

The DMA tape loader breaks any program that self-relocates between
segments (e.g. `tap/scubadive.tap`'s BASIC loader at `$0501` that copies
itself to `$8501`, then CLOADs MC payloads that overwrite `$0400-$3400`).
Rather than reverse-engineering each loader's quirks, we capture the
full machine state once after the program is loaded and running, then
restore from that snapshot in milliseconds.

The format is **Oricutron-compatible** so files round-trip with the
desktop emulator (`pete-gordon/oricutron`).

## File format

- **Extension:** `.sna`
- **Endianness:** big-endian for all multi-byte numeric fields
- **Container:** sequence of typed blocks; max file size 256 KiB
- **Authoritative reference:** `snapshot.c` in
  https://github.com/pete-gordon/oricutron. The field tables below were
  cross-checked against that source and validated by walking a real
  Oricutron-saved `.sna` with `tools/sna-inspect.py`.

### Block envelope

Every block is:

| Offset | Size | Field   | Value                                                         |
| ------ | ---- | ------- | ------------------------------------------------------------- |
| 0      | 4    | tag     | 4-byte ASCII tag, NUL-padded (e.g. `"OSN\0"`)                 |
| 4      | 4    | size    | u32 BE — payload size in bytes (excludes the 8-byte envelope) |
| 8      | size | payload | block-specific data                                           |

Blocks may appear in any order. A reader skips unknown tags by reading
`size` and seeking forward.

### Blocks we write/read in v1

We emit the **minimum block set Oricutron needs to load and run** an
Atmos snapshot, plus we honour the same set on load. All other Oricutron
blocks are skipped on load and omitted on save; Oricutron handles
missing optional blocks gracefully.

| Tag       | Size  | Purpose                                                |
| --------- | ----- | ------------------------------------------------------ |
| `OSN\0`   | 21    | Machine config (model, video, etc.)                    |
| `DATA`*   | 81920 | RAM image (follows `OSN`, 80 KiB on Atmos — see below) |
| `CPU\0`   | 21    | 6502 register file + IRQ/NMI state                     |
| `AY\0\0`  | 153   | AY-3-8912 register file + oscillator/envelope state    |
| `VIA\0`   | 39    | 6522 register file + timer counters + line states      |

\* Oricutron emits the RAM payload as a `DATA` envelope immediately
following `OSN`. **For Atmos** `oric->memsize` is `65536 + 16384` bytes
(the extra 16 KiB is the disk-overlay RAM that always exists in the
machine struct, even when no drive is attached). Our core only has 64 KiB
of main RAM — when **saving** for Oricutron, pad the upper 16 KiB with
zeros; when **loading** an Oricutron snapshot, ignore the upper 16 KiB.

**Block ordering matters for the parent→DATA association.** Oricutron
walks blocks linearly and treats any `DATA` block as belonging to the
preceding non-`DATA` block (`bkh[i-1].datablock = &bkh[i]`). So the
canonical order is:

```
OSN, DATA(RAM), [TAP, DATA(tape buffer)], [PCH], CPU, AY, VIA, [optional ...]
```

Optional blocks Oricutron writes when applicable but does not require on
load: `TAP\0` + its `DATA`, `PCH\0`, drive blocks (`JSM`, `MDC`, `PRV` +
`PVD`, `WDD`, `DSK`), Telestrat blocks (`BNK`, `ACI`, `AUX`, `TVA`),
symbol blocks (`SYR`, `SYU`, `SY0..SY7`), breakpoints (`BKP`).

### Field-level mapping (our core ↔ Oricutron fields)

For each block, fields we have direct signals for are marked **[live]**;
fields that are Oricutron-internal scratch we don't reproduce are marked
**[zero]** (write `0`, ignore on load). Audio/timer counters we'll plumb
out as part of the implementation are marked **[plumb]**.

#### `OSN\0` (21 bytes)

| Off | Size | Field                | Source                                      |
| --- | ---- | -------------------- | ------------------------------------------- |
| 0   | 1    | machine type         | **[live]** `2` for Atmos (0=Oric-1, 1=Oric-1 16K, 2=Atmos, 3=Telestrat, 4=Pravetz) |
| 1   | 4    | overclock multiplier | **[zero]** `1`                              |
| 5   | 4    | overclock shift      | **[zero]** `0`                              |
| 9   | 2    | vsync timing         | **[live]** `272` for 50 Hz (Oricutron value)|
| 11  | 1    | rom disable flag     | **[live]** `0` (no ROM-disable in our core) |
| 12  | 1    | rom enable flag      | **[live]** `1`                              |
| 13  | 1    | vsync hack flag      | **[zero]** `0`                              |
| 14  | 1    | drive type           | **[live]** `0` (no disk in v1)              |
| 15  | 1    | tape turbo flag      | **[zero]** `0`                              |
| 16  | 1    | video mode           | **[live]** ULA mode (Oricutron uses `2` = HIRES, etc.) |
| 17  | 4    | keymap               | **[zero]** `0`                              |

Followed by: `DATA` block, **80 KiB** payload (= `oric->memsize`). First
64 KiB is the address-space RAM image (`$0000-$FFFF`); upper 16 KiB is
the disk-overlay area Oricutron always allocates. Pad the upper 16 KiB
with zeros when saving from this core.

#### `CPU\0` (21 bytes)

| Off | Size | Field         | Source                                        |
| --- | ---- | ------------- | --------------------------------------------- |
| 0   | 4    | cycle counter | **[zero]** `0`                                |
| 4   | 2    | PC            | **[live]** T65 `Regs[63:48]` (need to expose) |
| 6   | 2    | last PC       | **[zero]** `0`                                |
| 8   | 2    | calc PC       | **[zero]** `0`                                |
| 10  | 2    | calc int      | **[zero]** `0`                                |
| 12  | 1    | NMI flag      | **[zero]** `0`                                |
| 13  | 1    | A             | **[live]** T65 `Regs[7:0]`                    |
| 14  | 1    | X             | **[live]** T65 `Regs[15:8]`                   |
| 15  | 1    | Y             | **[live]** T65 `Regs[23:16]`                  |
| 16  | 1    | S             | **[live]** T65 `Regs[39:32]`                  |
| 17  | 1    | P             | **[live]** T65 `Regs[31:24]`                  |
| 18  | 1    | IRQ flag      | **[zero]** `0`                                |
| 19  | 1    | NMI count     | **[zero]** `0`                                |
| 20  | 1    | calc opcode   | **[zero]** `0`                                |

Verify the T65 `Regs` bit ordering against `rtl/T65/T65.vhd` during
implementation — the table above reflects the conventional layout but
forks vary.

#### `VIA\0` (39 bytes)

Authoritative order from `snapshot.c:286-320`.

| Off | Size | Field          | Source                                       |
| --- | ---- | -------------- | -------------------------------------------- |
| 0   | 1    | IFR            | **[live]** `r_ifr`                           |
| 1   | 1    | IRB            | **[live]** `r_irb`                           |
| 2   | 1    | ORB            | **[live]** `r_orb`                           |
| 3   | 1    | IRBL (latched) | **[zero]** `0` — no separate latch in m6522.vhd |
| 4   | 1    | IRA            | **[live]** `r_ira`                           |
| 5   | 1    | ORA            | **[live]** `r_ora`                           |
| 6   | 1    | IRAL (latched) | **[zero]** `0`                               |
| 7   | 1    | DDRA           | **[live]** `r_ddra`                          |
| 8   | 1    | DDRB           | **[live]** `r_ddrb`                          |
| 9   | 1    | T1L_L          | **[live]** `r_t1l_l`                         |
| 10  | 1    | T1L_H          | **[live]** `r_t1l_h`                         |
| 11  | 2    | T1C            | **[plumb]** `t1c`                            |
| 13  | 1    | T2L_L          | **[live]** `r_t2l_l`                         |
| 14  | 1    | T2L_H          | **[live]** `r_t2l_h`                         |
| 15  | 2    | T2C            | **[plumb]** `t2c`                            |
| 17  | 1    | SR             | **[live]** `r_sr`                            |
| 18  | 1    | ACR            | **[live]** `r_acr`                           |
| 19  | 1    | PCR            | **[live]** `r_pcr`                           |
| 20  | 1    | IER            | **[live]** `r_ier`                           |
| 21  | 1    | CA1            | **[zero]** `0` — line state, can re-derive   |
| 22  | 1    | CA2            | **[zero]** `0`                               |
| 23  | 1    | CB1            | **[zero]** `0`                               |
| 24  | 1    | CB2            | **[zero]** `0`                               |
| 25  | 1    | SR count       | **[plumb]** `sr_cnt`                         |
| 26  | 1    | T1 reload      | **[zero]** `0`                               |
| 27  | 1    | T2 reload      | **[zero]** `0`                               |
| 28  | 2    | SR time        | **[zero]** `0`                               |
| 30  | 1    | T1 run         | **[plumb]** `t1c_active`                     |
| 31  | 1    | T2 run         | **[plumb]** `t2c_active`                     |
| 32  | 1    | CA2 pulse      | **[zero]** `0`                               |
| 33  | 1    | CB2 pulse      | **[zero]** `0`                               |
| 34  | 1    | SR trigger     | **[zero]** `0`                               |
| 35  | 4    | IRQ bit        | **[zero]** `0`                               |

#### `AY\0\0` (153 bytes)

Authoritative order from `snapshot.c:251-283`. NUM_AY_REGS = 15
(AY-3-8910 register file plus IO Port A index).

| Off | Size | Field                                     | Source                                |
| --- | ---- | ----------------------------------------- | ------------------------------------- |
| 0   | 1    | bus mode (`bmode`)                        | **[zero]** `0`                        |
| 1   | 1    | current register (`creg`)                 | **[live]** AY address latch           |
| 2   | 15   | `eregs[15]` — register file               | **[live]** AY register file           |
| 17  | 8    | 8 keystates                               | **[live]** keyboard column read state |
| 25  | 12   | 3 tone periods (u32 each)                 | **[live]** from regs 0-5              |
| 37  | 4    | noise period (u32)                        | **[live]** from reg 6                 |
| 41  | 4    | envelope period (u32)                     | **[live]** from regs 11-12            |
| 45  | 18   | per-channel `tonebit/noisebit/vol` (u16×3 each) | **[plumb]** ff/vol per channel  |
| 63  | 2    | newout                                    | **[zero]** `0`                        |
| 65  | 12   | per-channel timer `ct[3]` (u32 each)      | **[plumb]** `a/b/c_count`             |
| 77  | 4    | noise timer `ctn` (u32)                   | **[plumb]** `n_count`                 |
| 81  | 4    | envelope timer `cte` (u32)                | **[plumb]** envelope counter          |
| 85  | 48   | per-channel `tonepos/tonestep/sign/out` (u32×4 each) | **[zero]** mostly `0`      |
| 133 | 4    | envelope position                         | **[plumb]** envelope phase            |
| 137 | 4    | current noise value                       | **[plumb]** noise LFSR                |
| 141 | 4    | RNG rack (`rndrack`)                      | **[plumb]** noise LFSR                |
| 145 | 4    | key bit delay                             | **[zero]** `0`                        |
| 149 | 4    | current key offset                        | **[zero]** `0`                        |

Oricutron's AY model is internally rich; our `psg.v` is much simpler.
We plumb out tone/noise/envelope counters (per the "registers + internal
counters" choice); the per-channel `tonepos/tonestep/sign/out` block is
Oricutron audio-rendering scratch and may safely be zero on load.

### State we DO NOT capture in v1

- **Tape state (`TAP`)** — tape is irrelevant once a program is loaded.
- **ROM patches (`PCH`)** — Oricutron's fast-disk/fast-tape patches; n/a.
- **Disk controller blocks** (`MDC`, `WDD`, `JSM`, `PRV`, `DSK`) — no disk.
- **Telestrat blocks** (`BNK`, `ACI`, `TVA`) — Atmos only in v1.
- **Debug blocks** (`SYR`, `SYU`, `BKP`) — never relevant.

### Typical file size (minimal block set)

```
"OSN\0"  envelope(8) + 21        =     29 bytes
"DATA"   envelope(8) + 81920     =  81928 bytes
"CPU\0"  envelope(8) + 21        =     29 bytes
"AY\0\0" envelope(8) + 153       =    161 bytes
"VIA\0"  envelope(8) + 39        =     47 bytes
Total                            ≈  82194 bytes (~80 KiB)
```

Reference: a real Oricutron save of scubadive is **99,778 bytes** —
that includes optional `TAP` (46 + tape buffer 13830), `PCH` (76),
and `SYR` (3600) blocks. Our minimal save will be ~80 KiB. Well under
the 256 KiB cap; no compression needed.

## Open implementation questions (for the next plan)

1. **Trigger** — new "Save snapshot" / "Load snapshot" menu items;
   separate ioctl indexes (likely `5` for load, `6` for save); whether
   to also bind a hot-key.
2. **Capture mechanism** — read RAM through the existing spram address
   mux (reverse direction of the DMA loader); CPU/VIA/AY register
   fields exposed via new wiring up through `oricatmos`.
3. **Counter plumbing** — adding `snap_*` debug outputs to `m6522.vhd`
   and `psg.v` for the **[plumb]** fields.
4. **CPU halt during save AND load** — extend the existing
   `cpu_halt | dma_active` chain with a `snap_active` term.
5. **RAM restore** — write 64 KiB through the spram mux exactly as the
   DMA loader does for tapes.

## Tooling

`tools/sna-inspect.py` — walks the block container and decodes every
known block's fields against the layouts above. Sanity-checked against
a real `scubadive.sna` saved by Oricutron 1.x (Atmos, no drive). All
expected sizes (`OSN=21`, `CPU=21`, `AY=153`, `VIA=39`, `TAP=46`,
`PCH=76`, `DATA=81920` for Atmos RAM) matched on first run, and the
decoded TXTTAB (`$8501`) matches scubadive's known runtime relocation
behaviour — strong evidence the layout above is correct.

```sh
python3 tools/sna-inspect.py path/to/snapshot.sna
```

## Verification path (before any RTL)

1. Hand-craft a minimal `.sna` (correct envelopes, all-zero payloads,
   plain RAM dump lifted from `scubadive.sna`) and confirm Oricutron
   loads it without error. **DONE** for ground-truth verification.
2. Walk a real Oricutron save with `tools/sna-inspect.py` and
   cross-check fields against the tables above. **DONE.**
3. Once RTL is built, save a snapshot from MiSTer, load it in Oricutron
   (and the reverse), and verify the program continues running
   visually/audibly.

## References

- Oricutron source — `snapshot.c`:
  https://github.com/pete-gordon/oricutron/blob/master/snapshot.c
- Oricutron repository:
  https://github.com/pete-gordon/oricutron
- Forum thread on `.sna` layout:
  https://forum.defence-force.org/viewtopic.php?t=1001&start=150
- `tools/sna-inspect.py` — block walker / field decoder (in this repo)
