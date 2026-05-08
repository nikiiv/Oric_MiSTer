# Tape loading notes

The core supports two tape-loading paths, selected by the **Smart
CLOAD** P1 menu option:

## Autoload TAP = On (default)

After an F1 `.tap` selection finishes, the core resets the Oric, waits
for BASIC to reach the `READY` prompt, then injects `CLOAD""` followed
by Return through the normal keyboard path. The selected tape remains
buffered in `tapecache` across that reset.

Autoload only starts the command. The actual loading path is still
selected by the existing tape settings:

- With **Smart CLOAD = On**, the patched ROM triggers the instant
  `tap_segment_loader.v` path.
- With **Smart CLOAD = Off**, the stock ROM reads the cassette audio
  stream from the buffered TAP file.

## Smart CLOAD = On (default)

The patched ROM at `$E85F-$E8BB` triggers `tap_segment_loader.v`,
which copies one segment per `CLOAD` from the in-FPGA `tapecache`
spram directly into RAM. Loads finish in milliseconds and audio
isn't used.

Works for tapes whose multi-stage loaders re-enter the standard
CLOAD body (gravitor, MEMORIA, scubadive, single-segment BASIC
tapes, etc.). The NOP-sled in `cload_patch_rom.v` covers the common
re-entry addresses.

## Smart CLOAD = Off (audio cassette emulation)

The unpatched ROM runs the original tape decoder, reading bit
timing off VIA timer 2 from the audio waveform produced by
`cassette.v` + `cas_sig_gen.v`. Real ~2400-baud cassette speed.

Use this when Smart CLOAD doesn't work for a tape — typically tapes
whose multi-stage MC loaders read tape directly via `$E735` /
`$E6C9` (DIY decoders) rather than re-entering CLOAD.

**Wall-clock load times are slow.** Empirically:

| Tape                            | Size  | Audio-path load time |
| ------------------------------- | ----- | -------------------- |
| `MEMORIA.tap` (single-seg BASIC) | small | ~10-20 s |
| `gravitor.tap` (multi-seg, 14k payload) | ~14 KB | ~1-2 min |
| `welcome.tap` (multi-seg, 37k payload) | ~37 KB | **~5-8 min** |

The 5-8 min figure for welcome.tap is the actual measured time on
hardware — not the ~30s I had estimated earlier.

## Known limitations

- **welcome.tap-style "DIY MC loader" tapes** that bypass CLOAD and
  decode tape directly via VIA T2 / `$E735` / `$E6C9` will only
  load via the audio path (Smart CLOAD = Off). See section above
  for expected load time.
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

1. Open the menu → P1 → **Smart CLOAD** → toggle as needed.
2. F1 to load the `.tap` file. With **Autoload TAP = On**, the core
   resets and types `CLOAD""` automatically.
3. To use the old manual flow, set P1 → **Autoload TAP** to Off, F1 to
   load the `.tap` file, then type `CLOAD""` at the BASIC `READY`
   prompt.
4. With Smart CLOAD Off + Tape Audio set to Low/High you'll hear
   the audio waveform during the load.
