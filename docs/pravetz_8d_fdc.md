# Pravetz 8D FDC Implementation

This note documents the current Pravetz 8D floppy-controller support in
the MiSTer core. The implementation keeps the original Pravetz controller
ROM banks at `$0320-$03FF`, implements the Apple II Disk II style
softswitches at `$0310-$031F`, and mounts Disk II `.nib` or Apple DOS
`.dsk` images through the MiSTer disk path.

The FPGA-side controller always consumes Disk II NIB track data. Raw
`.nib` images pass through directly. Apple DOS `.dsk` images require a
Main MiSTer build that enables the existing Apple II `.dsk` to `.nib`
translation path for the Oric core name.

## Source Layout

- `rtl/oricatmos.vhd` selects the Pravetz disk path when the selected ROM is
  Pravetz 8D (`rom = "10"`), muxes the HPS disk interface, and maps the
  page-3 ROM/FDC windows.
- `rtl/pravetz8d_fdc.vhd` is the Pravetz-specific wrapper around the
  Apple II disk controller.
- `rtl/apple2_disk/` contains the borrowed Disk II implementation:
  `disk_ii.vhd`, `drive_ii.vhd`, `disk_ii_rom.vhd`, `dpram.vhd`, and
  `floppy_track.sv`.
- `_Games/_Oric/dos_8d_nib.mgl` launches the core with a `.nib` image
  mounted in Drive A.
- `_Games/_Oric/dos_8d_dsk.mgl` launches the core with a `.dsk` image
  mounted in Drive A. This needs the matching Main MiSTer HPS change.

## Address Map

In Pravetz mode, page 3 is split this way:

| Address range | Owner | Notes |
| ------------- | ----- | ----- |
| `$0300-$030F` | VIA | Remains the normal Oric VIA window. |
| `$0310-$031F` | Pravetz FDC | Disk II style drive and data softswitches. |
| `$0320-$03FF` | Pravetz controller ROM | BANK0/BANK1 ROM window. |
| `$0380-$0383` | Pravetz bank/shadow latch | Write-only address triggers inside the ROM window. |

The core reserves `$0310-$03FF` for the Pravetz extension while in
Pravetz mode. This prevents the `$0310-$031F` FDC softswitch accesses
from also mutating mirrored VIA registers. `$0300-$030F` remains VIA so
the keyboard, PSG, and normal Oric I/O path keep working.

Reads in `$0310-$031F` come from `PRAVETZ8D_FDC_CTRL`. Reads in
`$0320-$03FF` come from the original Pravetz BANK0/BANK1 controller ROM.

## FDC Softswitches

`PRAVETZ8D_FDC_CTRL` decodes `$0310-$031F` and remaps the low nibble to
the Apple II Disk II `$C080-$C08F` softswitch model:

```vhdl
disk_addr <= unsigned(X"C08" & A(3 downto 0));
```

The current softswitch map is:

| Pravetz address | Disk II equivalent | Function |
| --------------- | ------------------ | -------- |
| `$0310` | `$C080` | Phase 0 off |
| `$0311` | `$C081` | Phase 0 on |
| `$0312` | `$C082` | Phase 1 off |
| `$0313` | `$C083` | Phase 1 on |
| `$0314` | `$C084` | Phase 2 off |
| `$0315` | `$C085` | Phase 2 on |
| `$0316` | `$C086` | Phase 3 off |
| `$0317` | `$C087` | Phase 3 on |
| `$0318` | `$C088` | Motor off |
| `$0319` | `$C089` | Motor on |
| `$031A` | `$C08A` | Select Drive A |
| `$031B` | `$C08B` | Select Drive B |
| `$031C` | `$C08C` | Q6 off; read/shift disk data |
| `$031D` | `$C08D` | Q6 on; sense write protect or load write latch |
| `$031E` | `$C08E` | Q7 off; read mode |
| `$031F` | `$C08F` | Q7 on; write mode |

The Disk II Q6/Q7 state controls the meaning of reads and writes:

| Q7 | Q6 | Mode |
| -- | -- | ---- |
| 0 | 0 | Read disk byte stream |
| 0 | 1 | Sense write protect; bit 7 set means protected |
| 1 | 0 | Write disk byte stream |
| 1 | 1 | Load write latch |

Reads return the Disk II data latch when Q6 is clear, or the selected
drive's write-protect status when Q6 is set. The borrowed Disk II write
path is wired and marks the active track dirty for HPS writeback.

## ROM Bank And Shadow Switches

The original Pravetz FDC ROM is exposed at `$0320-$03FF`. The active bank
is selected by writes to `$0380-$0383`; the written data byte is ignored.
Only the address bits matter:

| Address | Bank | High `$C000-$FFFF` view |
| ------- | ---- | ----------------------- |
| `$0380` | BANK0 | BASIC ROM visible |
| `$0381` | BANK0 | Shadow RAM visible |
| `$0382` | BANK1 | BASIC ROM visible |
| `$0383` | BANK1 | Shadow RAM visible |

`A1` selects BANK0/BANK1. `A0` selects BASIC ROM or shadow RAM in the
upper 16K window.

The shadow latch only maps RAM over `$C000-$FFFF`. Low RAM, zero page,
stack, screen memory, and page 3 I/O remain available while shadow RAM is
selected. The backing storage is the existing 64 KiB Oric RAM; there is
no separate overlay RAM block.

## Disk Image Path

Drive A and Drive B use the same OSD disk type contract as the Apple II
core: `NIBDSKDO PO`. In Pravetz mode:

- Drive A maps to MiSTer disk slot 0 and `sd_lba_fd0`.
- Drive B maps to MiSTer disk slot 1 and `sd_lba_fd1`.
- Drive C and Drive D are unused by the Pravetz FDC path.
- Outside Pravetz mode, the existing Microdisc path owns the disk HPS
  interface.

Each Disk II track is represented as `0x1A00` bytes. A 35-track `.nib`
image is therefore `35 * 0x1A00 = 0x38A00` bytes, or `232960` bytes.
The Pravetz RTL always requests these 13 512-byte LBAs per track.

For `.dsk` mounts, Main MiSTer recognizes the image as Apple II DSK,
converts each requested DSK track into the same NIB byte stream, and
converts dirty NIB tracks back into DSK sectors on writeback. The Oric
core does not contain a `.dsk` parser.

`floppy_track.sv` provides the per-drive track buffers. It loads the
requested track through the HPS block interface, exposes the byte stream
to `drive_ii.vhd`, and writes dirty tracks back through `sd_wr`.

## Clocking And Drive State

The wrapper derives an internal Disk II 2 MHz clock from `clk_sys`.
`disk_ii.vhd` handles phase coils, motor state, drive select, Q6/Q7, and
write-protect sensing. `drive_ii.vhd` handles head movement, byte timing,
track-buffer addressing, and track writes.

Mount changes are latched from `img_mounted(1 downto 0)`. A non-zero
`img_size` marks the corresponding Pravetz drive as mounted.

## Launcher And Validation

The launcher used for hardware validation is:

```xml
<mistergamedescription>
  <rbf>_Aoric/Oric</rbf>
  <file delay="2" type="s" index="0" path="/media/usb0/games/Oric/dsk/231.nib" />
  <reset delay="1" hold="1" />
</mistergamedescription>
```

The `.dsk` launcher uses the same flow with the raw DSK image:

```xml
<mistergamedescription>
  <rbf>_Aoric/Oric</rbf>
  <file delay="2" type="s" index="0" path="/media/usb0/games/Oric/dsk/231.dsk" />
  <reset delay="1" hold="1" />
</mistergamedescription>
```

The deployed test flow was:

1. Build and deploy the core with `./tools/oric-build`.
2. Launch `_Games/_Oric/dos_8d_nib.mgl`.
3. At the Pravetz BASIC prompt, type `CALL 800`.
4. Confirm the DOS boot path runs from the real controller ROM and the
   mounted `.nib` image.

## Current Limits

- `.nib` is the validated raw format for the Pravetz FDC path.
- `.dsk` support depends on Main MiSTer exposing Oric `.dsk` mounts
  through the Apple II DSK conversion path.
- The hardware smoke test validated the DOS boot/read path. A separate
  write-persistence test is still needed.
- Snapshot save/restore of live Pravetz FDC state is not implemented.
- Drive C and Drive D remain Microdisc-oriented and are not part of the
  Pravetz Disk II path.
