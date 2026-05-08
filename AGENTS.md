# Oric MiSTer Core

This repository implements an Oric/Oric Atmos 8-bit computer core for
MiSTer. Active work includes Smart CLOAD fast tape loading, original
cassette-audio tape loading, Oricutron-compatible snapshot loading,
live ROM patching, Microdisc support, and MiSTer build/deploy tooling.

Use these indexes first:

- `docs/docs.md` summarizes the documentation set and points to the
  main technical references.
- `tools/tool.md` summarizes the build, TAP, and SNA helper tools.

High-value docs:

- `docs/build.md` - build/deploy workflow via `tools/oric-build`.
- `docs/tape_loading.md` - TAP loading modes, Autoload TAP, Smart CLOAD,
  and audio cassette fallback.
- `docs/sna_support.md` - snapshot loader format, restored state, and
  verification notes.
- `docs/oric_to_core_comm.md` - runtime communication patterns between
  the 6502 and FPGA core.
- `docs/live_rom_patching.md` - read-side ROM patching used by Smart
  CLOAD.
- `docs/Oric Rom.md` - searchable Atmos ROM disassembly.

Useful tools:

- `./tools/oric-build` - compile and deploy the core.
- `python3 tools/tape-inspect.py <file.tap>` - inspect Oric TAP files.
- `python3 tools/sna-inspect.py <file.sna>` - inspect Oricutron
  snapshots.

Oricutron source may be available next to this repository at
`../oricutron/` and is useful as the ground-truth reference for `.sna`
snapshot behavior.
