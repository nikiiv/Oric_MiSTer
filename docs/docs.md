# Documentation summary

This directory contains both project workflow notes and technical references for
the Oric Atmos MiSTer core. The most active implementation topics are fast tape
loading, live ROM patching, Oricutron-compatible snapshots, and runtime
communication between the emulated 6502 and the FPGA core.

## Start here

- `build.md` explains how to build the core with `tools/oric-build`, including
  Docker/Quartus prerequisites, compile-only and deploy modes, clean builds,
  debug macros, release artifact naming, and common build/deploy failures.
- `tape_loading.md` is the short operational guide for tape loading. It
  explains Smart CLOAD, the slower audio cassette fallback, which tapes need
  each path, expected load times, and the menu steps for switching modes.
- `sna_support.md` is the main reference for `.sna` snapshot support in this
  core. It documents the currently working LOAD path, the Oricutron block
  format, field-level mapping into RTL state, ignored blocks, unfinished SAVE
  support, and verification history.

## Core implementation references

- `oric_to_core_comm.md` describes runtime communication patterns between the
  6502 and the FPGA core. It covers bus-snooped write mailboxes, halting the CPU
  to access RAM through the spram mux, read-side ROM overrides, and the current
  `$C000` mailbox used by Smart CLOAD and the user LED latch.
- `live_rom_patching.md` explains the read-side ROM patch mechanism used by
  Smart CLOAD. It documents why live patching is used, how
  `rtl/cload_patch_rom.v` and the `oricatmos.vhd` read mux work, how ROM-space
  addresses map to 14-bit offsets, and how to add new synth-time patches.
- `oricutron_snapshot_internals.md` summarizes Oricutron's own snapshot
  implementation from `snapshot.c`. It is the producer/consumer format
  reference for block IDs, big-endian fields, save order, load order, optional
  blocks, and how Oricutron attaches `DATA` chunks.

## Oric reference material

- `Oric Rom.md` is a converted Atmos 1.1b ROM disassembly with anchors and
  cross-references. It is the searchable source for BASIC routines, tape
  routines such as CLOAD/CSAVE, keyboard, graphics, sound, reset, IRQ, and ROM
  entry points used by patches.
- `Oric Rom.html` is the HTML companion for the same ROM disassembly.
- `manual_atmos.md` is a text conversion of the Oric Atmos manual. It covers
  setup, BASIC programming, tape usage, graphics, sound, machine code,
  input/output, memory maps, ROM routines, 6502 opcodes, and expansion-port
  details.

## Current project state captured by the docs

- Smart CLOAD is the default fast tape path. It patches the ROM around CLOAD,
  snoops a write to `$C000`, then lets `tap_segment_loader.v` copy the next TAP
  segment from `tapecache` into RAM and update BASIC state where needed.
- Some tapes bypass the standard CLOAD path with custom machine-code loaders.
  Those require Smart CLOAD off and use the original audio cassette emulation.
- Snapshot LOAD is implemented for RAM, CPU registers, AY registers/current
  register, VIA registers, VIA timers, active flags, and IFR source flags.
  Snapshot SAVE is not implemented.
- Oricutron `.sna` files are typed block containers using 8-byte envelopes and
  big-endian numeric fields. The core honors the minimal Atmos restore set and
  skips tape, patch, disk, Telestrat, symbol, and debug blocks.
- ROM patching is read-side only. It does not modify the BIOS image in memory;
  it substitutes bytes on CPU fetches when a patch gate is active.
