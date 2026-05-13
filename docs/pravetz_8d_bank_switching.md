# Pravetz 8D Bank Switching POC

This note documents the current Pravetz 8D disk-controller proof of
concept in the MiSTer core. It is intentionally narrow: it validates the
page-3 controller ROM window and the high-16K overlay RAM mechanism. It
does not yet emulate the real Pravetz FDC byte stream or Apple II-style
drive electronics.

## Hardware Model

The Pravetz 8D disk extension exposes controller ROM in page 3:

- `$0320-$03FF` is the controller ROM window.
- `$0380-$0383` are address-triggered softswitches inside that same
  window. Writes latch bank and overlay state; the written value is
  ignored.

The four softswitch addresses are:

| Address | Bank | High `$C000-$FFFF` view |
| ------- | ---- | ----------------------- |
| `$0380` | 0    | BASIC ROM visible       |
| `$0381` | 0    | overlay RAM visible     |
| `$0382` | 1    | BASIC ROM visible       |
| `$0383` | 1    | overlay RAM visible     |

`A1` selects bank 0/1. `A0` selects ROM/overlay-RAM view.

Important detail: overlay selection must only affect the high 16K
window. Low RAM, zero page, stack, screen RAM, and page 3 I/O must
remain accessible while `$C000-$FFFF` is mapped to overlay RAM. In the
core this means the latched overlay state should drive `MAPn` low only
for CPU accesses where `A15..A14 = 11`.

## Core Backing RAM

The existing Oric main RAM is a 64 KiB BRAM:

```verilog
spram #(.address_width(16)) ram (...)
```

So the physical storage for `$C000-$FFFF` already exists. ROM visibility
is a read mux/decode decision; writes to the high 16K can land in the
same BRAM when overlay RAM is selected. The POC does not allocate a
separate 16 KiB overlay BRAM.

This is also why low RAM must remain selected while overlay is active:
the POC's BANK1 routine needs to read a temporary buffer below `$9800`
and write it into `$C000-$FFFF`.

## Current POC Behavior

The POC maps the original 8D FDC controller ROM bytes at `$0320-$03FF`
when the selected machine ROM is Pravetz 8D.

The byte source is `8D-FDC_ROM.bin` / Oricutron `8dos2.rom`, SHA-256:

```text
f34606ddeea2b888f20c111fd107e1a9951df63fc9f47feace1bfb24be642b77
```

The mapped banks are:

| Runtime window | EPROM source | Role |
| -------------- | ------------ | ---- |
| BANK0 `$0320-$03FF` | offsets `$020-$0FF` | boot stub and DOS dispatch thunks |
| BANK1 `$0320-$03FF` | offsets `$120-$1FF` | RWTS read-sector routine |

The original BANK0 boot stub at `$0320` copies a six-byte trampoline to
`$02EA-$02EF`, then runs it. The trampoline writes `$0382` to select
BANK1 and jumps back to `$0320`.

The original BANK1 code is the disk read-sector routine. It expects a
real Pravetz / Apple Disk II-style byte stream from the `$0310-$031F`
controller softswitches, especially `$031C`. That byte stream is not
implemented by this POC yet.

As a result, `CALL 800` now enters the original firmware path. Until the
FDC byte stream exists, reaching BANK1 is expected to stall in the
read-sector routine rather than print the old synthetic `BANK0` /
`BANK1` proof strings.

The remaining proof surface at this stage is byte-for-byte ROM identity
and correct `$0380-$0383` bank / overlay latching, not successful DOS
boot.

## Scratch Buffer Choice

The temporary 16 KiB buffer is `$5800-$97FF`.

This range was chosen because:

- it is exactly 16 KiB;
- it ends before `$9800`, where HIRES-reserved memory starts;
- it avoids the text-mode character sets at `$B400-$BB7F`;
- it avoids the text screen/status area at `$BB80-$BFDF`;
- it avoids the overlay destination at `$C000-$FFFF`.

An earlier `$7800-$B7FF` buffer was invalid because it overwrote the
text-mode standard character set at `$B400-$B7FF`, causing screen glyph
corruption during validation.

## Validation Notes

Hardware smoke tests on MiSTer previously verified the synthetic ROM POC:

- Pravetz 8D boots as the default ROM selection.
- BANK0: `POKE 896,0 : CALL 800` writes `BANK0` and returns to BASIC.
- BANK1: `POKE 898,0 : CALL 800` reaches `P2`, copies the patched ROM
  image to overlay RAM, and returns with the prompt changed to `BANK1`.

The build used for validation closed timing with positive setup and hold
slack.

Those visible `BANK0` / `BANK1` tests no longer apply after replacing the
synthetic ROM with the original FDC banks.

## Open Work

This POC is not the final Pravetz disk implementation. Remaining work:

- replace synthetic bank ROM bytes with real Pravetz controller ROM
  content or a faithful generated equivalent;
- emulate the real `$0310-$031F` FDC/drive softswitch behavior;
- decide how snapshots should preserve Pravetz overlay state and overlay
  RAM contents;
- decide whether the current `.sna` loader should stop skipping the
  extra Oricutron overlay RAM payload when a disk interface is active.
