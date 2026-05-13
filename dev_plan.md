# Pravetz 8D FDC Vanilla Implementation

## Summary

Implement Pravetz 8D floppy support by reusing the Apple II Disk II
controller path already present in `Apple-II_MiSTer`. The first milestone
supports `.nib` images only, with read/write and dirty-track writeback, and
reuses the existing Oric Drive A/B mount slots.

## Implementation

- Borrow the Apple II disk RTL unchanged where practical:
  `disk_ii.vhd`, `drive_ii.vhd`, `disk_ii_rom.vhd`, `dpram.vhd`, and
  `floppy_track.sv`.
- Add `PRAVETZ8D_FDC_CTRL`, a Pravetz-specific wrapper that:
  - decodes `$0310-$031F`;
  - remaps those accesses to Apple Disk II `$C080-$C08F` softswitch behavior;
  - latches Drive A/B mount changes and feeds Apple `.nib` track buffers;
  - exposes Drive A/B HPS block requests and writeback.
- Keep the existing Pravetz ROM behavior:
  - `$0320-$03FF` remains the BANK0/BANK1 controller ROM window;
  - `$0380-$0383` keeps selecting BANK0/BANK1 and high-16K ROM/RAM shadowing.
- In Pravetz ROM mode, mux Drive A/B HPS disk signals to `PRAVETZ8D_FDC_CTRL`.
  In non-Pravetz modes, leave Microdisc as the active disk backend.
- In Pravetz ROM mode, keep `$0300-$030F` mapped to the VIA and reserve
  `$0310-$03FF` for the Pravetz extension so Disk II softswitch accesses do
  not also mutate mirrored VIA registers.
- Update the OSD so Drive A/B accept `DSK` and `NIB`; Drive C/D remain
  Microdisc-style `DSK`.

## Out of Scope

- Main_MiSTer `.dsk` to `.nib` conversion for the Oric core.
- HPS-side `.dsk` writeback bugs.
- Pravetz snapshot serialization of FDC state.
- Extra Pravetz-only mount slots.

## Acceptance Tests

- Build a normal deployable core with `./tools/oric-build`.
- Mount `231.nib` in Drive A, select Pravetz 8D ROM, cold-launch the core,
  and boot DOS through the real `$0320` controller ROM path.
- Verify reads from `$0310-$031F` return Disk II style latch data or
  write-protect state, while `$0320-$03FF` still returns original BANK0/BANK1
  ROM bytes.
- Verify a simple DOS write persists after cold relaunch and remount.
- Verify Oric Atmos/Oric 1 plus Microdisc still boot DSK images outside
  Pravetz mode.
