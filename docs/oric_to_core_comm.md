# Oric ↔ core communication

How the 6502 inside the emulated Oric and the surrounding FPGA core
talk to each other at runtime. Documents the patterns proven by the
Smart CLOAD POC (`27754e9`) and the host LED mailbox POC.

## Why

The DMA tape loader and snapshot loader are *boot-time* paths — the
core writes RAM before letting the CPU run. We also need *running-time*
channels:

- 6502 → core: the running program signals the host (e.g. "I just
  parsed a filename, do something with it").
- core → 6502: the host injects state the program will see (e.g.
  override a ROM byte, paint the status row, change a register).

Both directions exist on real Oric expansions (the disk controller is
the textbook example: it lives behind a magic IO range and shares
state via memory). We replicate that in FPGA without a physical
expansion bus — by tapping the existing 6502 address/data lines
inside `rtl/oricatmos.vhd`.

## Pattern A — 6502 → core: bus-snoop write trigger

A small decode in `oricatmos.vhd` watches every CPU cycle. When the
address bus matches a chosen mailbox AND the cycle is a write, we
emit a 1-cycle strobe to the top level. Optionally, we also mirror
the data byte (`cpu_do`) so the host can capture *what* the program
wrote.

Decode template (architecture body, near other IO decodes):

```vhdl
mailbox_we   <= '1' WHEN ula_phi2 = '1'
                      AND cpu_rw = '0'
                      AND cpu_ad(15 DOWNTO 0) = X"...."
                ELSE '0';
mailbox_data <= cpu_do;          -- only meaningful while *_we = '1'
```

Pair these with new `OUT` ports on the entity, then route to the
top level for whatever consumer needs them.

### Picking the mailbox address

| Region          | OK?  | Why                                                 |
| --------------- | ---- | --------------------------------------------------- |
| `$0000-$00FF`   | risky | Zero page — heavily used by BASIC/ROM.              |
| `$0100-$01FF`   | no   | 6502 stack.                                         |
| `$0200-$02FF`   | OK*  | System RAM. Pick a byte BASIC doesn't touch.        |
| `$0300-$03FF`   | **avoid** | VIA mirrors itself across this whole range — a write to *any* `$03xx` byte also writes a VIA register, toggling ORB / printer strobe / cassette relay. |
| `$0400-$BFFF`   | OK   | Main RAM.                                           |
| `$C000-$FFFF`   | OK   | ROM space — writes go nowhere (read returns ROM byte) but the bus carries the value, so the snoop sees it.        |

\* The mailbox byte is "deposited" into RAM as a harmless side effect
unless we override it. For `$C000` (ROM space) the byte never lands
anywhere; the snoop sees the bus value regardless.

**Important footgun: don't pick a `$02xx` system-RAM address as a
mailbox unless you're sure no game code writes there.** An early
POC used `$02FE` and a corresponding `cload_handler.v` consumer; we
removed it after Xenon3 (an MC game) happened to issue stray writes
to `$02FE` in normal play, which spuriously fired the handler and
painted "CLOAD:…" garbage at `$BB80-$BFE7`, corrupting the screen.
ROM-space addresses ($C000+) are safer because well-behaved game
code never writes to them.

### Examples in this codebase

| Mailbox  | Strobe        | Data carried | Consumer                               |
| -------- | ------------- | ------------ | -------------------------------------- |
| `$C000`  | `c000_we`     | `c000_data`  | `Oric.sv` `led_user_pokeable` latch → `LED_USER` pin (value 1=on, 0=off); in Tape Load = Ultra also fires `tap_segment_loader.v` when value==1 + `tape_loaded` |

The `$C000` mailbox is dual-use:
- BASIC `POKE #C000, 1` lights `LED_USER` (Atmos POKE issues an
  unconditional `STA ($33),Y` per `docs/Oric Rom.md:3333`).
- The Ultra tape patch ROM at `$E85F-$E8BB` is a NOP-sled ending
  with `LDA #$01 / STA $C000` — that fires the same mailbox to
  trigger a tape-segment load via `tap_segment_loader.v`.

Fast tape loading does not use a CPU-visible mailbox. It patches
`$E735` to request byte-level TAP leader alignment and `$E6C9` so
the next TAP byte from `tap_byte_streamer.v` appears as the immediate
operand of `LDA #imm`, then advances the prefetcher when the CPU
fetches that operand.

## Pattern B — core → 6502: halt + paint via spram bus

To write into main RAM (or read it back), the core grabs the spram
address bus while the CPU is parked. The mux in `Oric.sv` prioritises
the active loaders, then the CPU:

```
if (snap_active)     spram <= snap_*;
else if (tap_active) spram <= tap_*;
else                 spram <= cpu_*;
```

`*_active` outputs from the loader OR into `oricatmos.cpu_halt` so
the CPU stops issuing cycles for the duration. Add a new arm by:

1. Building a module that exposes `active`, `ram_addr`, `ram_data`,
   `ram_we` (and optionally consumes `ram_q` for reads).
2. Adding another `else if` to the mux.
3. OR'ing `*_active` into the cpu_halt expression.

### Reading main RAM (3-cycle pipeline)

(Historic note: the read-back pattern was originally proven by
`cload_handler.v` in an early POC; that module has been removed but
the timing analysis below still applies to anyone adding a new RAM-
reading loader.) Single-port BRAM
plus the mux register adds two cycles between "drive ram_addr" and
"sample ram_q":

| Cycle | What happens                                     |
| ----- | ------------------------------------------------ |
| T0    | Loader sets `ram_addr <= X`, `ram_we <= 0`.       |
| T1    | `Oric.sv` mux registers `spram_addr <= X`.        |
| T2    | spram clocks: `q <= mem[X]`.                      |
| T3    | Loader samples `ram_q` — value is `mem[X]`.       |

So the FSM needs `S_READ_SET → S_READ_WAIT1 → S_READ_WAIT2 → S_READ_CAP`
to land on the right cycle. Writing is one cycle simpler — drive
`ram_addr/ram_data/ram_we`, the mux pipes it to spram next cycle, done.

### Examples

| Module                   | What it does                                          |
| ------------------------ | ----------------------------------------------------- |
| `snap_loader.v`          | Restores `.sna` snapshot — RAM, AY, VIA register file. |
| `tap_segment_loader.v`   | Smart CLOAD per-segment loader; populates `$02A9-$02AE` so the ROM's autorun path takes over. |

## Pattern C — core → 6502: read-side ROM override (no halt)

For *reads* of ROM addresses, the core can intercept the data path
directly without halting the CPU. Two `IN` ports on `oricatmos.vhd`
(`patch_active`, `patch_data[7:0]`) feed a top-priority ELSIF in the
`cpu_di` read mux:

```vhdl
IF cpu_rw = '1' AND ula_phi2 = '1' AND patch_active = '1' THEN
    cpu_di <= patch_data;
ELSIF ... (existing ROM/IO/RAM decode chain)
```

Whatever drives `patch_active`/`patch_data` (typically a synth-time
patch table indexed by the ROM offset) wins over all three ROM
sources — built-in Atmos, built-in Oric 1, built-in Pravetz 8D, and
the loadable BIOS.

This is documented in detail in `docs/live_rom_patching.md`. The
short version: gate it on a status bit, build a `case` table for
the patch bytes, range-check the address. Adding a 200-byte
payload is just more case rows — no extra plumbing.

## Pattern D — 6502 → MiSTer host (LED, etc.)

A specialisation of Pattern A where the consumer is a top-level
`emu` output pin rather than RAM. Strobe + data → register at
`Oric.sv` → drive the pin.

```verilog
reg led_user_pokeable = 1'b0;
always @(posedge clk_sys) begin
    if (reset) led_user_pokeable <= 1'b0;
    else if (c000_we) begin
        if (c000_data == 8'd1) led_user_pokeable <= 1'b1;
        else if (c000_data == 8'd0) led_user_pokeable <= 1'b0;
        // any other value: ignore — sticky latch
    end
end
assign LED_USER = ioctl_download | fdd_busy | tape_adc_act
                | led_user_pokeable;
```

The OR with the existing activity sources keeps the LED useful for
download/disk/tape feedback even when the user latch is off.

The same shape extends to multi-bit registers (e.g. an 8-bit
"status word" mailbox with one snoop trigger and a registered byte).

## Where each piece lives

| File                       | Role                                                                |
| -------------------------- | ------------------------------------------------------------------- |
| `rtl/oricatmos.vhd`        | All bus decodes (cpu_rw / cpu_ad / cpu_do / ula_phi2). New mailbox = new decode here. |
| `Oric.sv`                  | Top-level wiring; spram mux; cpu_halt OR-chain; status bits; pin assigns. |
| `rtl/tap_segment_loader.v` | Pattern B example (halt + cache scan + RAM stream + side-effect writes). |
| `rtl/cload_patch_rom.v`    | Pattern C reference (ROM-read override).                            |
| `rtl/snap_loader.v`        | Pattern B sibling — halt/restore shape used for `.sna` snapshots.    |

## Open extensions

- **Read-side mailbox** (6502 reads host state). Mirror image of
  Pattern D: when CPU reads a chosen address, `oricatmos.vhd`
  substitutes a host-supplied byte (just another ELSIF in the
  read mux, gated on a host-driven enable + 8-bit data). Useful for
  status registers, RTC, host-set parameters.
- **Bidirectional MMIO region** (e.g. 16-byte block at `$BFF0`) —
  generalises Patterns A/D to a small register bank.
- **Multi-LED / 8-bit GPIO** — extend `c000_data` consumption to
  drive additional MiSTer outputs.

## References

- Smart CLOAD POC commit: `f36f0dc` (merged in `27754e9`).
- Atmos ROM disassembly: `docs/Oric Rom.md` (CLOAD entry `$E85B`,
  POKE handler `$D94F`).
- Snapshot LOAD docs: `docs/sna_support.md`.
