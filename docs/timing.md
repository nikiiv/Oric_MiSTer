# Timing notes: the "last 8 columns lose color" bug

## Symptom

For a long time, adding *unrelated* features to the core would randomly produce
builds where the last 8 visible columns (33–40 of 40) lost their color
attributes and rendered white-on-black. The RTL of the video path was untouched
in those builds; a recompile with slightly different logic elsewhere could make
the bug appear or disappear.

## It was not an fmax problem

Static timing analysis passed in the affected builds (TNS = 0 on every clock;
the 24 MHz core domain had over +13 ns of setup slack). Checking
`output_files/Oric.sta.summary` would never have caught it.

## Root cause (fixed 2026-07)

`rtl/ula.vhd` decoded `lRELOAD_SEL <= '1' when (lCTR_H >= 49)` combinationally
from the 6-bit horizontal character counter, and process `u_ld_reg` used it as
an **asynchronous level-sensitive clear** on the color attribute registers
`lREG_INK/STYLE/PAPER`.

At the counter transition **31 → 32** (`011111` → `100000`) all six bits
toggle. When placement/routing skew let bit 5 rise before bit 4 fell, the
`>= 49` comparator transiently asserted (transient values 49–63) and
asynchronously wiped the attribute registers at column 32 — white-on-black for
the rest of the line, i.e. exactly columns 33–40.

Why it was build-dependent and invisible:

- Whether the glitch occurs depends on LUT decomposition and routing skew,
  which the fitter re-rolls on any netlist change (`Oric.qsf` enables physical
  synthesis retiming/duplication). Adding any feature re-rolled the dice.
- STA does not analyze combinational glitches into async clear/load pins;
  recovery/removal only times the deassertion edge. Every affected build was
  "timing clean".

## The fix

The reload was made synchronous: it now happens inside the
`rising_edge(CLK_24)` branch of `u_ld_reg` when `lRELOAD_SEL = '1'`. Decode
glitches settle within the cycle and the path is an ordinary STA-checked setup
path. Functionally equivalent: the reload lands one 24 MHz edge after
`lCTR_H` reaches 49, with ~360 clock cycles of blanking margin before the next
visible column, and the attribute-load branch is gated by `BLANKINGn` (0 for
`lCTR_H >= 41`) so the two can never conflict.

## Rule for future work

**Never drive an asynchronous reset/clear/preset/load pin from decoded
combinational logic** — counter comparisons, address decodes, state decodes.
Only clean sources (external reset, reset-synchronizer output) may be async;
anything decoded must be sampled synchronously. STA will NOT catch violations
of this rule — the resulting bugs are placement-dependent and look like
"adding features breaks the video".

`rtl/video.vhd` is dead legacy code (not instantiated; `ula.vhd` is the live
implementation) but still contains the old async-reset style — do not copy
from it.

## Multicorner STA

`Oric.qsf` now sets `TIMEQUEST_MULTICORNER_ANALYSIS ON` (was OFF). Previously
only the slow 100 °C corner was analyzed, leaving fast-corner hold unchecked —
a second class of placement-dependent failure that "passing" STA would have
missed. The cost is only a longer `quartus_sta` step; the fitter is unaffected.
When reading `Oric.sta.summary`, all corners must show TNS = 0.
