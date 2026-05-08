# Tools summary

This directory contains small command-line helpers for building the MiSTer core
and inspecting or manipulating Oric tape/snapshot files. Run paths below from
the repository root unless noted.

## Build tool

- `oric-build` compiles `Oric.qpf` inside the `raetro/quartus:mister` Docker
  image. By default it also deploys the generated `output_files/Oric.rbf` to
  `root@192.168.0.108:/media/fat/_Aoric`.
- Useful options:
  - `--no-deploy` compiles only.
  - `--clean` removes `db`, `incremental_db`, and `output_files` before build.
  - `--no-hdmi` injects `MISTER_DEBUG_NOHDMI=1` for faster development builds.
  - `--snap-debug` injects `SNAP_DEBUG=1` to paint captured snapshot CPU
    registers on the text screen after load.
- The script expects to be run from the repo root and checks for `Oric.qpf`.
  Deploys are timestamped with the current date/time and short git SHA, then
  copied to a stable `Oric.rbf` name on the MiSTer.

Example:

```sh
./tools/oric-build --no-deploy
./tools/oric-build --clean --no-hdmi
```

## TAP inspection and manipulation

- `tape-inspect.py` prints the structure of an Oric `.tap` file. It handles
  multi-segment tapes, reports sync/header/name/address information, and can
  detokenize BASIC payloads.
- Output modes:
  - `--short` is the default and shows a 10-byte preview per segment.
  - `--basic` detokenizes BASIC segments and previews machine-code segments.
  - `--full` detokenizes BASIC and fully dumps machine-code payloads as hex and
    decimal rows.

Example:

```sh
python3 tools/tape-inspect.py --basic tap/example.tap
```

- `splitter.py` splits a multi-segment `.tap` into one self-contained file per
  segment, named `<stem>_0.tap`, `<stem>_1.tap`, and so on next to the input.
  Inter-segment padding and trailing junk are dropped. It refuses to overwrite
  existing outputs unless `--force` is used.

Example:

```sh
python3 tools/splitter.py tap/game.tap
python3 tools/splitter.py --force tap/game.tap
```

- `merger.py` concatenates one or more `.tap` files into a single multi-segment
  tape in command-line order. With `--replace-cload`, it walks BASIC segments
  and rewrites tokenized `CLOAD` bytes to `PRINT` outside string literals before
  merging.

Example:

```sh
python3 tools/merger.py -o tap/combined.tap tap/part1.tap tap/part2.tap
python3 tools/merger.py -o tap/combined.tap --replace-cload tap/loader.tap tap/payload.tap
```

## Snapshot inspection

- `sna-inspect.py` walks an Oricutron `.sna` typed-block container and decodes
  known blocks: `OSN`, `DATA`, `TAP`, `PCH`, `CPU`, `AY`, and `VIA`.
- It reports block offsets and payload sizes, validates expected fixed block
  sizes where known, decodes big-endian fields, previews unknown blocks, and
  identifies `DATA` payloads as RAM or tape buffer based on the preceding block.
- This is the matching diagnostic tool for the snapshot format documented in
  `docs/sna_support.md` and `docs/oricutron_snapshot_internals.md`.

Example:

```sh
python3 tools/sna-inspect.py snapshots/example.sna
```

## Notes

- The Python tools use only the standard library.
- All TAP parsing assumes Oric framing with repeated `0x16` sync bytes followed
  by `0x24`, a 9-byte header, a NUL-terminated filename, and a payload length
  derived from the start/end addresses.
- Snapshot parsing assumes Oricutron's 8-byte block envelope and big-endian
  numeric fields.
