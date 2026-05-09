# Tape loading notes

The core supports three tape-loading paths, selected by the **Tape
Load** P1 menu option:

The selected TAP is buffered in the shared FPGA file cache also used
for SNA uploads. TAP uploads are clamped to 160 KiB, sized for the
largest known Oric TAP in this repository (`petscii.tap`, about
146 KiB). Larger TAP uploads are clamped at the cache limit instead of
wrapping and corrupting earlier bytes.

## Autoload TAP = On (default)

After an F1 `.tap` selection finishes, the core resets the Oric, waits
for BASIC to reach the `READY` prompt, then injects `CLOAD""` followed
by Return through the normal keyboard path. The selected tape remains
buffered in the shared file cache across that reset.

Autoload only starts the command. The actual loading path is still
selected by the existing tape settings:

- **Ultra** patches CLOAD and triggers the instant
  `tap_segment_loader.v` path.
- **Fast** patches the ROM cassette sync/byte routines and feeds TAP
  bytes from the shared file cache through the patched `GETTAPEBYTE`
  routine.
- **Off** leaves the ROM untouched; the stock ROM reads the cassette
  audio stream from the buffered TAP file.

## Tape Load = Fast (default)

Fast mode keeps the ROM's byte-by-byte load flow, but replaces the
slow cassette timing routines:

- `$E735` (`SYNCTAPE`) returns immediately; the ROM's caller still
  reads bytes until it sees the TAP `$24` marker.
- `$E6C9` (`GETTAPEBYTE`) preserves X/Y and returns the next TAP
  byte from `tap_byte_streamer.v` via a patched `LDA #imm`.

This targets custom loaders that bypass the CLOAD body but still call
the ROM tape routines. It does not cover loaders that implement their
own VIA/timer cassette decoder.

Fast is the preferred default: it keeps the ROM in charge of parsing
headers, filenames, BASIC setup, machine-code loading, and autorun
decisions, while only replacing the slow cassette byte acquisition.

## Tape Load = Ultra

The patched ROM at `$E85F-$E8BB` triggers `tap_segment_loader.v`,
which copies one segment per `CLOAD` from the shared FPGA file cache
directly into RAM. Loads finish in milliseconds and audio isn't used.

Ultra remains available for instant segment loading, but Fast is more
compatible because the original ROM still performs the tape-load state
updates. The NOP-sled in `cload_patch_rom.v` covers common re-entry
addresses for tapes whose multi-stage loaders re-enter the standard
CLOAD body.

## Tape Load = Off (audio cassette emulation)

The unpatched ROM runs the original tape decoder, reading bit
timing off VIA timer 2 from the audio waveform produced by
`cassette.v` + `cas_sig_gen.v`. Real ~2400-baud cassette speed.

Use this for maximum compatibility with code that reads the cassette
VIA/timer behavior directly instead of using the ROM routines.

**Wall-clock load times are slow.** Empirically:

| Tape                            | Size  | Audio-path load time |
| ------------------------------- | ----- | -------------------- |
| `MEMORIA.tap` (single-seg BASIC) | small | ~10-20 s |
| `gravitor.tap` (multi-seg, 14k payload) | ~14 KB | ~1-2 min |
| `welcome.tap` (multi-seg, 37k payload) | ~37 KB | **~5-8 min** |

The 5-8 min figure for welcome.tap is the actual measured time on
hardware — not the ~30s I had estimated earlier.

## Known limitations

- **Raw VIA cassette loaders** that decode VIA T2 / CB1 directly still
  require Tape Load = Off.
- **Tape Turbo** (faster audio-path decode via ROM threshold
  patching) was prototyped on the abandoned `turbo_fast_loader`
  branch and didn't reach a working state — the BASIC ROM's pulse
  discriminator at `$E731 CMP #$FE` doesn't have an obvious
  proportional patch value, and empirical iteration through `$7F`
  / `$40` failed to lock sync at 2× cassette speed. Reaching a
  working turbo would require deeper instrumentation
  (testbench-driven simulation of `cas_sig_gen` → VIA T2 → ROM
  decoder) to find the exact threshold value, which is more
  effort than the use case currently justifies.

## How to switch modes

1. Open the menu → P1 → **Tape Load** → select Fast, Ultra, or Off.
2. F1 to load the `.tap` file. With **Autoload TAP = On**, the core
   resets and types `CLOAD""` automatically.
3. To use the old manual flow, set P1 → **Autoload TAP** to Off, F1 to
   load the `.tap` file, then type `CLOAD""` at the BASIC `READY`
   prompt.
4. With Tape Load Off + Tape Audio set to Low/High you'll hear
   the audio waveform during the load.
