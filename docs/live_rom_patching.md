# Live ROM patching

How to swap bytes inside the Atmos BIOS (or Oric 1 BIOS, or a
loadable .rom) at runtime, without modifying the ROM image on disk
and without re-streaming the BIOS through the ioctl path. This is
the mechanism the **Smart CLOAD** POC uses to hijack the CLOAD
handler at `$E85F`.

## Why live patching

Three reasons we landed on this approach:

1. **No re-load loop.** Patching the ioctl stream as it flows into
   the `altbios` SPRAM only takes effect when the user re-loads a
   .rom file. Toggling a menu option doesn't re-stream the BIOS, so
   ioctl-time patching needs an awkward "reload your ROM file"
   step. Live patching toggles instantly with Apply & Reset.
2. **Built-in ROMs work too.** The default Atmos ROM is synthesised
   from `rtl/rom/BASIC11A.vhdl` — no ioctl stream exists for it.
   A read-side override sits between the ROM and the CPU regardless
   of the source, so the same patch works for the built-in Atmos,
   built-in Oric 1, and any loadable BIOS.
3. **Scales for free.** A 200-byte patch is the same wiring as a
   5-byte one. The patch ROM is just a `case` table and the
   override is one address-range comparator on the bus.

## Architecture

```
                          ┌──────────────────────┐
       smart_cload_en ───►│                      │
                          │  cload_patch_rom.v   │
       bios_addr[13:0] ──►│  (rtl/, Verilog)     │
                          │                      │──► patch_active
                          │                      │──► patch_data[7:0]
                          └──────────────────────┘
                                                   │
                                                   ▼
              ┌──────────────────── oricatmos.vhd ─────────────────────┐
              │                                                        │
   cpu_ad ──► │  read mux:                                             │
              │    IF patch_active='1' THEN cpu_di <= patch_data;      │
              │    ELSIF ... (built-in Atmos / Oric 1 / loadable BIOS) │
              │    ELSIF ... (RAM / VIA / disk)                        │
              │                                                        │
              └────────────────────────────────────────────────────────┘
                                                   │
                                                   ▼
                                                cpu_di → 6502
```

The patch module exposes two outputs (`patch_active`, `patch_data`).
`oricatmos.vhd` consumes them as inputs and substitutes them for
`cpu_di` whenever `patch_active='1'` (top-priority ELSIF in the
read mux at `oricatmos.vhd:555`).

The patch is **read-side only** — the BIOS contents in spram or VHDL
ROM are never modified. The CPU just *sees* different bytes when it
fetches inside the patched address range.

## Anatomy of a patch

`rtl/cload_patch_rom.v` is the live example. Three pieces:

### 1. Range check

```verilog
wire in_cload_trampoline = (rom_addr >= 14'h285F) && (rom_addr <= 14'h2863);
assign patch_active = enable && in_cload_trampoline;
```

`rom_addr` is the 14-bit BIOS offset (= `cpu_ad[13:0]`, since the
BIOS ROM at `$C000-$FFFF` masks down to 14 bits: `$E85F & $3FFF =
$285F`). Add more ranges with `||` when you have non-contiguous
patches.

### 2. Patch byte table

```verilog
always @(*) begin
    case (rom_addr)
        14'h285F: data_r = 8'h8D; // STA abs
        14'h2860: data_r = 8'hFE; // $02FE lo
        14'h2861: data_r = 8'h02; // $02FE hi
        14'h2862: data_r = 8'h28; // PLP
        14'h2863: data_r = 8'h60; // RTS
        default:  data_r = 8'hEA; // NOP — never reached while patch_active=0
    endcase
end
```

A pure combinational lookup. Synthesises into a small ROM/LUT
table; size scales linearly with the number of case rows. 256-byte
payloads use 256 rows; 1 KiB payloads use 1024 rows. No flip-flops,
no clocked logic — the synthesiser tends to pack these efficiently.

### 3. Enable gate

`enable` is wired to a status bit (`smart_cload_en = status[56]` in
the current example). When low, `patch_active` is forced to 0 and
the CPU sees the original ROM. When high, the patch is live.

## Address-space layout

The Atmos BIOS sits at `$C000-$FFFF` (16 KiB). Inside that, useful
address ranges:

| Range          | Size  | Notes                                                     |
| -------------- | ----- | --------------------------------------------------------- |
| `$C000-$DFFF`  | 8 KiB | BASIC interpreter — most "BASIC keywords" live here.      |
| `$E000-$EFFF`  | 4 KiB | More BASIC + tape I/O (CLOAD `$E85B`, CSAVE `$E909`).     |
| `$F000-$F7FF`  | 2 KiB | Floating-point math.                                      |
| `$F800-$FFFF`  | 2 KiB | Char ROM, IRQ vector, NMI/reset vectors at top 6 bytes.   |

Disassembly references in the repo: `docs/Oric Rom.md` and `docs/Oric
Rom.html` carry the full Atmos 1.1b listing with anchors at every
labelled address.

## Combining with bus-snoop mailboxes

Live patching becomes useful when paired with a snoop trigger
(`docs/oric_to_core_comm.md` Pattern A). The Smart CLOAD example:

1. Patch CLOAD body with a NOP sled at `$E85F-$E8B6` ending in
   `LDA #$01 / STA $C000` at `$E8B7`.
2. `oricatmos.vhd` decodes the `STA $C000` into a `c000_we` strobe.
3. `tap_segment_loader.v` halts the CPU, scans the F1-buffered
   `tapecache` for the next sync+marker, parses the 9-byte header,
   streams the body into RAM, and writes the BASIC-state side
   effects at `$02A9-$02AE` (start/end/autorun/type) so the
   unpatched ROM's autorun dispatch at `$E8BC-$E900` finishes the
   job natively.

So the patch is the *trampoline* into a host handler. The actual
work happens in Verilog, not 6502. This pattern is far cheaper than
writing 200-byte 6502 routines, and the patched code is just a
2-3 instruction handoff.

Avoid using a `$02xx` system-RAM address as the mailbox — game
code may write there for its own purposes and spuriously trigger
your handler. ROM-space addresses (`$C000+`) are safer because
well-behaved game code never writes to them. (We learned this the
hard way: an early POC used `$02FE` and Xenon3 corrupted its own
screen by tripping the handler.)

If a future feature does need real 6502 logic (e.g. a custom file
format that maps differently into RAM), the patch ROM can hold an
arbitrarily long routine. The 6502 fetches it transparently — same
instruction-fetch path as a "real" ROM byte.

## Limits and caveats

- **Read-only.** This mechanism only substitutes data on CPU reads.
  Writes to ROM addresses still go nowhere (or to whatever the
  existing decode says — typically discarded, but the bus value is
  observable, see Pattern A). To "modify" ROM behaviour from within
  ROM you'd need a self-modifying-code-like approach, which is what
  the patch table already provides at compile time anyway.
- **Single-cycle only.** The patch is combinational on the address;
  the CPU sees patch data with the same one-cycle latency as a real
  ROM fetch. Don't add registers between `rom_addr` and `data_r` —
  it would shift the data by a cycle and the CPU would read garbage.
- **No bypass for code locations the ROM doesn't reach.** If the
  Atmos ROM never branches to your patched address (because it's
  buried in unused space), nothing executes. Always patch a real
  entry point or a routine the ROM dispatches into.
- **Patch ROM is synth-time.** The case table is baked into the
  bitstream; changing patch bytes requires a Quartus rebuild.
  For runtime-changeable patches you'd need an spram-backed table
  loaded over ioctl — not implemented today, easy to add later.

## Adding a new patch

1. Disassemble the target entry — find the address(es) of the bytes
   you want to override. `docs/Oric Rom.md` is searchable for keyword
   names like `CLOAD`, `CSAVE`, `LOAD`, `SAVE`, `LIST`, `RUN`.
2. Decide the gate — a new status bit in `Oric.sv` `CONF_STR`, an
   always-on, or a more complex condition.
3. Extend `cload_patch_rom.v` (or fork into a new module if the
   semantic is unrelated) with:
   - A new `in_*` range wire.
   - New case rows for the substitute bytes.
   - The right OR'ing in `patch_active`.
4. If you need a snoop trigger to pair with the patch, add a new
   `*_we` (and optionally `*_data`) mailbox decode in
   `oricatmos.vhd`. See `docs/oric_to_core_comm.md` Pattern A.
5. Build, deploy, verify with `PEEK` from BASIC:
   ```basic
   FOR I=#XXXX TO #YYYY:PRINT HEX$(PEEK(I));" ";:NEXT
   ```
   The bytes you read should match the patch table when the gate is
   on, and the original ROM bytes when the gate is off.

## References

- Smart CLOAD POC commit: `f36f0dc` (merged in `27754e9`).
- `rtl/cload_patch_rom.v` — current patch table.
- `rtl/oricatmos.vhd:555` — the `cpu_di` read mux ELSIF chain.
- `docs/Oric Rom.md` — Atmos 1.1b disassembly with address anchors.
- Companion doc on the bus channels themselves:
  `docs/oric_to_core_comm.md`.
