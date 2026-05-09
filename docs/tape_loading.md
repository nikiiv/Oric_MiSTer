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

- `$E735` (`SYNCTAPE`) performs a byte-level TAP leader seek, looking
  for at least two `$16` leader bytes followed by the `$24` marker.
  It leaves the byte pointer at the leader so the ROM's caller still
  consumes the leader and marker through `$E6C9`.
- `$E6C9` (`GETTAPEBYTE`) preserves X/Y and returns the next TAP
  byte from `tap_byte_streamer.v` via a patched `LDA #imm`.

This targets custom loaders that bypass the CLOAD body but still call
the ROM tape routines. It does not cover loaders that implement their
own VIA/timer cassette decoder.

Fast is the preferred default: it keeps the ROM in charge of parsing
headers, filenames, BASIC setup, machine-code loading, and autorun
decisions, while only replacing the slow cassette byte acquisition.

The byte-level leader seek exists because Fast mode bypasses the
ROM's original bit-level cassette synchronizer. The stock ROM first
aligns on tape leader bits, then its TAPESYNC caller scans bytes for
the `$24` header marker. If Fast mode simply returned from `$E735`,
named loads that reject an earlier segment could resume scanning from
inside that segment's payload and mistake a payload `$24` for a header.
Seeking to a real TAP leader run before returning from `$E735` restores
the useful effect of ROM sync while keeping the byte stream itself raw.

Fast mode tracks its position as a byte offset into the cached TAP
file, not as a segment counter. New TAP loads, Reset/Apply, and
autoload resets arm a one-shot raw rewind: the next ROM tape-sync call
starts its leader seek from offset 0 and lets the ROM consume the TAP
leader, marker, header, filename, and payload itself. After that,
unnamed loads continue sequentially from the byte after the previous
loaded or skipped segment.

Repository TAPs have been observed with two, three, and four `$16`
leader bytes before `$24`, so the Fast SYNCTAPE seek accepts two or
more leader bytes rather than requiring the ROM's nominal three-byte
post-sync check.

### Named CLOAD Rewind

The **Named CLOAD Rewind** P1 setting controls where Fast mode starts
searching when BASIC executes a named load:

- **On** (default): when the ROM stores a non-empty requested filename
  for `CLOAD"NAME"`, the Fast byte streamer rewinds to the start of the
  cached TAP at the next ROM tape-sync call. The ROM then performs
  normal filename matching; non-matching segments are skipped by the
  next byte-level leader seek.
- **Off**: named loads continue from the current stream position.

Unnamed `CLOAD""` is always sequential: each call continues from the
byte after the last loaded or skipped segment.

Regression note: `PROG.tap` should autoload `PROG-A` first; that
program then issues `CLOAD"PROG-C"`, so the expected final result is
`PROG C`, not `PROG B`.

Regression note: `Xenon3.tap` should load `G1`, then find `G2` without
printing garbage on the status line. That case specifically exercises
rewind + name mismatch + later segment search.

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
4. In Fast mode, leave **Named CLOAD Rewind** On if you want
   `CLOAD"NAME"` to search from the first TAP segment.
5. With Tape Load Off + Tape Audio set to Low/High you'll hear
   the audio waveform during the load.
