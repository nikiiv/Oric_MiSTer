# Oric / Oric Atmos memory map

Purpose: a self-contained reference for the low-RAM pages of the Oric so we
can reason about ROM patches, Smart CLOAD, snapshot restore, Microdisc /
Jasmin / Pravetz DOS interactions, and software that pokes hardware
directly. The 6502 has no banking on the base machine; "page" below means
**256-byte 6502 page**, i.e. the high byte of the address.

Ground truth:

- *The ROM Disassembly* (Oric Advanced User Guide, BASIC 1.1 / Atmos 1.1)
  — Appendix C (page 0), Appendix D (page 2), main body for vectors.
- Defence Force Wiki, `oric:software:memory_maps`.
- OSDK memory map (TEXT and HIRES variants).
- cc65 `asminc/atmos.inc` (named labels for V1.1).
- `oric.free.fr/programming.html` ("Hardware Programming on the Oric") —
  the canonical hardware pin-out reference.
- `48katmos.freeuk.com` and Twilighte's `via.htm` — VIA register / port
  bit reference.
- defence-force forum t=644 (Pravetz 8D thread) — Pravetz disk ROM
  detection at `#320`.

## 1. Whole-machine map

The 6502 sees a flat 64 KB address space. The ULA (HCS 10017) generates
the chip-select signals: page 3 (`$0300-$03FF`) selects the I/O area, and
`$C000-$FFFF` selects the internal ROM. Everything else is the 48 KB DRAM
on the 48 K Oric Atmos (16 K on the original Oric-1, with a hole between
`$4000` and `$BFFF`). With a Microdisc / Jasmin / Telestrat fitted, the
16 KB "overlay RAM" hidden under the ROM at `$C000-$FFFF` can be enabled
via the disk interface.

### TEXT mode (default at power-on)

| Range          | Size    | Contents                                            |
| -------------- | ------- | --------------------------------------------------- |
| `$0000-$00FF`  | 256     | Page 0 — BASIC + OS variables (see §2)              |
| `$0100-$01FF`  | 256     | Page 1 — 6502 hardware stack (see §3)               |
| `$0200-$02FF`  | 256     | Page 2 — OS / BASIC system variables (see §4)       |
| `$0300-$03FF`  | 256     | Page 3 — I/O area (VIA, expansion devices) (see §5) |
| `$0400-$04FF`  | 256     | Page 4 — `$0400-$041F` user m/c, rest DOS (see §6)  |
| `$0500-$97FF`  | 37 KB   | Free RAM — BASIC program + variables grow up        |
| `$9800-$B3FF`  | 7 KB    | Reserved for HIRES; freed by `GRAB`, taken by `RELEASE` |
| `$B400-$B7FF`  | 1 KB    | Standard character set (redefinable, ASCII ≥ 32)    |
| `$B800-$BB7F`  | 896     | Alternate (semi-graphics) character set             |
| `$BB80-$BFDF`  | 1 120   | TEXT screen — 28 rows × 40 cols (row 0 = status)    |
| `$BFE0-$BFFF`  | 32      | Spare                                               |
| `$C000-$FFFF`  | 16 KB   | BASIC ROM (BASIC at `$C000-$ECC3`, OS at `$ECC4-$FFFF`); overlay RAM if enabled |

### HIRES mode (after `HIRES` command)

| Range          | Size  | Contents                                              |
| -------------- | ----- | ----------------------------------------------------- |
| `$0000-$04FF`  | 1 280 | Same five system pages as TEXT mode                   |
| `$0500-$97FF`  | 37 KB | Free RAM                                              |
| `$9800-$9BFF`  | 1 KB  | Standard character set                                |
| `$9C00-$9FFF`  | 896   | Alternate character set (with 128 byte gap)           |
| `$A000-$BF67`  | 8 000 | HIRES screen — 200 lines × 40 bytes (6 pixels/byte)   |
| `$BF68-$BFDF`  | 120   | Three rows × 40 bytes of TEXT at the bottom of HIRES  |
| `$BFE0-$BFFF`  | 32    | Spare                                                 |
| `$C000-$FFFF`  | 16 KB | BASIC ROM / overlay RAM                               |

The ULA always reads from `$BF68` for the bottom-of-screen text rows
regardless of mode, which is why the 8 000-byte HIRES bitmap stops at
`$BF67` rather than running to `$BFDF`.

## 2. Page 0 — `$0000-$00FF` (zero page)

Most of zero page is consumed by BASIC interpreter pointers and the
floating-point accumulators. Locations marked "V1.0 only" exist only on
the Oric-1 BASIC 1.0 ROM; everything else is identical between Oric-1 and
Atmos. **Locations not used by BASIC** are `$00-$0B`, `$BB,$BC`, and
`$F3-$F9` — these are safe scratch for user code that does not call back
into BASIC.

| Address      | V1.1 name (cc65) | Function                                         |
| ------------ | ---------------- | ------------------------------------------------ |
| `$00-$0B`    |                  | Free for user code                               |
| `$0C,$0D`    |                  | Indirect pointer for screen / hex-number area    |
| `$0E,$0F`    |                  | Indirect pointer for the screen                  |
| `$10,$11`    |                  | Address of HIRES cursor                          |
| `$12,$13`    | `SCRPTR`         | Address of TEXT cursor                           |
| `$14-$16`    |                  | Expression workspace                             |
| `$17`        |                  | Set to 1 if Ctrl-C pressed, otherwise 0          |
| `$18,$19`    |                  | Tokenising pointer                               |
| `$1A-$1C`    |                  | Jump location to print "Ready"                   |
| `$1D,$1E`    |                  | Counter for searching through program lines      |
| `$1F,$20`    |                  | Calculation of cursor address                    |
| `$21-$23`    |                  | Jump location for `USR` command                  |
| `$24-$26`    |                  | Expression workspace                             |
| `$27`        |                  | Temporary for characters being printed           |
| `$28`        |                  | `#FF` if dealing with strings                    |
| `$29`        |                  | Bit 7 set if using integer variable              |
| `$2A`        |                  | Garbage-collection flag / `DATA` skip flag       |
| `$2B`        |                  | Bit 7 inhibits use of integers; bit 6 = `STORE`/`RECALL` in use |
| `$2C`        |                  | Zero if redoing input from `START`               |
| `$2D`        |                  | Temporary for expression evaluator               |
| `$2E`        |                  | Ctrl-O flag (0 = print to screen enabled)        |
| `$2F`        |                  | Next byte to/from cassette                       |
| `$30`        |                  | Cursor position for BASIC printout               |
| `$31`        |                  | Screen line width                                |
| `$32`        |                  | 8 × multiple line width                          |
| `$33,$34`    |                  | Integer values to/from main FPA                  |
| `$35-$84`    | `BASIC_BUF`      | Input buffer (79 bytes)                          |
| `$35-$48`    |                  | Name of program required for `CLOAD` (V1.0 only) |
| `$49-$5D`    |                  | Name of program just loaded (V1.0 only)          |
| `$5F,$60`    |                  | Tape data start address (V1.0 only)              |
| `$61,$62`    |                  | Tape data end address (V1.0 only)                |
| `$63`        |                  | 1 if `AUTO` else 0 (V1.0 only)                   |
| `$64`        |                  | 0 = BASIC, 1 = machine code (V1.0 only)          |
| `$67`        |                  | Tape speed: 0 fast, 1 slow (V1.0 only)           |
| `$85`        |                  | String block stack pointer                       |
| `$86,$87`    |                  | Address of top active string                     |
| `$88-$90`    |                  | Temporary string stack                           |
| `$91,$92`    |                  | String address pointer                           |
| `$93,$94`    |                  | General memory pointer                           |
| `$95-$99`    |                  | Workspace for multiply / divide                  |
| `$9A,$9B`    |                  | Start-of-BASIC pointer                           |
| `$9C,$9D`    |                  | End-of-BASIC pointer                             |
| `$9E,$9F`    |                  | End-of-Variables pointer                         |
| `$A0,$A1`    |                  | End-of-Arrays pointer                            |
| `$A2,$A3`    |                  | Bottom-of-string-area pointer                    |
| `$A4,$A5`    |                  | Work pointer for allocating strings              |
| `$A6,$A7`    |                  | `HIMEM`                                          |
| `$A8,$A9`    |                  | Current line number (top byte `$FF` in command mode) |
| `$AA,$AB`    |                  | Previous line number                             |
| `$AC,$AD`    |                  | Last line start address                          |
| `$AE,$AF`    |                  | Temporary copy of line number                    |
| `$B0,$B1`    |                  | `DATA` pointer                                   |
| `$B2,$B3`    |                  | `DATA` pointer                                   |
| `$B4,$B5`    |                  | Last variable name accessed                      |
| `$B6,$B7`    |                  | Address of last variable value accessed          |
| `$B8,$B9`    |                  | Destination pointer for temporary assignment     |
| `$BA`        |                  | Temporary for expression evaluator               |
| `$BB,$BC`    |                  | Free for user code                               |
| `$BD-$C1`    |                  | Temporary FPA storage                            |
| `$BD,$BE`    |                  | `FN` (function) pointer                          |
| `$BF,$C0`    |                  | String pointer                                   |
| `$C2`        |                  | String pointer size (used in GC)                 |
| `$C3-$C5`    |                  | Jump location to evaluate numeric functions; `$C5` also rounds for math ops |
| `$C6-$CA`    |                  | Temporary FPA storage                            |
| `$C7,$C8`    |                  | Pointer                                          |
| `$C9,$CA`    |                  | Pointer                                          |
| `$CB-$CF`    |                  | Temporary FPA storage                            |
| `$CE,$CF`    |                  | Pointer for `STORE`                              |
| `$D0`        |                  | Exponent of main FPA                             |
| `$D1-$D4`    |                  | Mantissa of main FPA                             |
| `$D5`        |                  | Sign of mantissa for main FPA when unpacked      |
| `$D6`        |                  | Series-evaluation counter                        |
| `$D7`        |                  | Sign extend byte                                 |
| `$D8`        |                  | Exponent of work FPA                             |
| `$D9-$DC`    |                  | Mantissa of work FPA                             |
| `$DD`        |                  | Sign of mantissa for work FPA when unpacked      |
| `$DE,$DF`    |                  | String pointer / sign-XOR / rounding             |
| `$E0,$E1`    |                  | Array and string workspace                       |
| `$E2-$F2`    |                  | Routine to step through program for next non-space char |
| `$E8`        | `CHARGOT`        | Single-byte entry to that step routine           |
| `$E9,$EA`    | `TXTPTR`         | Position pointer in program                      |
| `$F3-$F9`    |                  | Free for user code                               |
| `$FA-$FE`    |                  | Copy of FP number used by `RND`                  |
| `$FF`        |                  | Used in number-to-string conversion              |

The "step through program" routine at `$00E2-$00F2` is the standard 6502
"`CHRGET`/`CHRGOT`" pattern: tight zero-page code that fetches the next
non-space character from `($E9,$EA)` and is `JSR`ed by every BASIC
parser. Patching `$E8` (`JSR $00E8`) is a classic interception point.

## 3. Page 1 — `$0100-$01FF` (6502 stack)

The 6502 hardware stack. The processor pushes downward from `$01FF` and
the CPU itself only sees the low byte of the SP. BASIC also pushes
arithmetic intermediates and `FOR/NEXT`/`GOSUB` records here, which is
why a runaway loop produces `?OUT OF MEMORY ERROR` — the stack page is
the limit.

There is no further sub-allocation table for page 1: the OS reset
routine at `$F88F` initialises SP to `$FF` and from then on it is
churned by every interrupt and subroutine call.

The Atmos manual's mention of "Page 1 is a stack for the use of the
arithmetic routines" refers to BASIC's use of the same page — the FPA
(floating-point accumulator) operands are pushed here during expression
evaluation. The 10-deep `FOR/NEXT` and `GOSUB` limits come from this
shared use.

## 4. Page 2 — `$0200-$02FF` (OS / BASIC variables)

Page 2 holds OS variables, the cursor state, IRQ-installable jump
vectors used by the ROM, the cassette filename buffers, and the four
parameter slots used by graphics and sound. The Oric-1 BASIC 1.0 ROM
laid these out slightly differently from Atmos BASIC 1.1; entries below
are V1.1 (Atmos) unless noted. cc65 names are from `atmos.inc`.

| Address       | V1.1 name (cc65) | Function                                          |
| ------------- | ---------------- | ------------------------------------------------- |
| `$0200,$0201` |                  | Pointer for screen handling                       |
| `$0202,$0203` |                  | Pointer for screen handling                       |
| `$0204-$0207` |                  | Work bytes for HIRES routines                     |
| `$0208`       |                  | Key address if pressed (`#38` if no key pressed)  |
| `$0209`       | `MODEKEY`        | Key status: `#38` default, `#A2` Ctrl, `#A4` Lshift, `#A5` Function (Atmos), Rshift |
| `$020A`       |                  | Saved key column for repeat                       |
| `$020B`       |                  | Unused, gets clobbered by `$208-$20A`             |
| `$020C`       | `CAPSLOCK`       | Bit 7 set if CAPS on (`#7F` not locked, `#FF` locked) |
| `$020E`       |                  | Repeat counter for keyboard                       |
| `$0210`       |                  | Temporary store of row of key being tested for repeat |
| `$0211`       |                  | Temporary store of keyboard row during strobe routine |
| `$0212`       |                  | Holds `FB` code in HIRES commands                 |
| `$0213`       | `PATTERN`        | Pattern data for HIRES screen                     |
| `$0214`       |                  | Temporary copy of pattern byte for drawing lines  |
| `$0215`       |                  | Position of pixel in byte for HIRES cursor        |
| `$0216,$0217` |                  | Temporary store of HIRES X and Y cursor positions |
| `$0218`       |                  | Temporary store for content of `$215`             |
| `$0219`       |                  | HIRES cursor — X coordinate                       |
| `$021A`       |                  | HIRES cursor — Y coordinate                       |
| `$021F`       |                  | Screen mode: 0 = LORES (TEXT), 1 = HIRES          |
| `$0220`       |                  | Machine size: 0 = 48 K Oric, 1 = 16 K Oric        |
| `$0228-$022A` |                  | Jump to IRQ routine (V1.0)                        |
| `$022B-$022D` |                  | Jump to NMI routine (V1.0)                        |
| `$0230`       |                  | RTI instruction (V1.0)                            |
| `$0238-$023A` |                  | Jump to PRINT CHARACTER on screen (V1.1)          |
| `$023B-$023D` |                  | Jump to GET KEY routine (V1.1)                    |
| `$023E-$0240` |                  | Jump to SEND BYTE TO PRINTER (V1.1)               |
| `$0241-$0243` |                  | Jump to PRINT TO STATUS LINE (V1.1)               |
| `$0244-$0246` | `IRQVec` (`$0245`) | Jump to IRQ routine (V1.1) — interceptable        |
| `$0247-$0249` |                  | Jump to NMI routine (V1.1)                        |
| `$024A-$024C` |                  | RTI instruction interceptable by a jump (V1.1)    |
| `$024D`       |                  | Tape speed: 0 fast, 1 slow (V1.1)                 |
| `$024E`       |                  | Keyboard initial repeat delay (V1.1)              |
| `$024F`       |                  | Keyboard successive repeat delay (V1.1)           |
| `$0251`       |                  | Cursor enable in Ctrl routines (V1.1)             |
| `$0252`       |                  | `ELSE` pending flag — 1 on, 0 off (V1.1)          |
| `$0256`       |                  | Printer width (V1.1)                              |
| `$0257`       |                  | Screen width (V1.1)                               |
| `$0258`       |                  | Printer cursor position (V1.1)                    |
| `$0259`       |                  | Screen cursor position (V1.1)                     |
| `$025A`       | `JOINFLAG`       | Cassette `JOIN` flag — `#4A` join, 0 don't (V1.1) |
| `$025B`       | `VERIFYFLAG`     | Cassette `VERIFY` flag — 1 verify, 0 load (V1.1)  |
| `$025C,$025D` |                  | Cassette verify error counter (V1.1)              |
| `$025F,$0260` |                  | 1-byte status-line message buffer                 |
| `$0261,$0262` |                  | Indirect jump for Ctrl-character routine          |
| `$0263,$0264` |                  | Temporary storage                                 |
| `$0265`       |                  | Current cursor state indicator: 0 off, 1 on       |
| `$0268`       | `CURS_Y`         | Cursor row number (status line is row 0)          |
| `$0269`       | `CURS_X`         | Cursor column position                            |
| `$026A`       | `STATUS`         | Flag byte (cursor on, screen output, keyclick disable, ESC seen, column-protect, double-height — see bit table) |
| `$026B`       | `BACKGRND`       | Paper colour (+16)                                |
| `$026C`       | `FOREGRND`       | Ink colour                                        |
| `$026D,$026E` |                  | Start address of screen memory                    |
| `$026F`       |                  | Number of text lines available on screen (V1.0)   |
| `$0270`       |                  | Cursor on/off flag                                |
| `$0271`       |                  | Cursor invert flag                                |
| `$0272,$0273` |                  | Keyboard timer                                    |
| `$0274,$0275` |                  | Cursor timer                                      |
| `$0276,$0277` | `TIMER3`         | Spare counter — used by `WAIT` (and printer V1.0) |
| `$0278,$0279` |                  | Address of second line on screen (V1.1)           |
| `$027A,$027B` |                  | Address of first line on screen (V1.1)            |
| `$027C,$027D` |                  | Number of characters in screen scroll, 26 × 40 = 1040 (V1.1) |
| `$027E`       |                  | Number of rows of text available (V1.1)           |
| `$027F-$028F` | `CFILE_NAME`     | Name of program to be loaded off cassette (V1.1)  |
| `$0293-$02A3` | `CFOUND_NAME`    | Name of file just loaded off cassette (V1.1)      |
| `$02A9,$02AA` | `FILESTART`      | Start address of data for/from cassette (V1.1)    |
| `$02AB,$02AC` | `FILEEND`        | End address of data for/from cassette (V1.1)      |
| `$02AD`       | `AUTORUN`        | Auto-run indicator: `$00` only load, `$C7` autorun (V1.1) |
| `$02AE`       | `LANGFLAG`       | Program type: `$00` BASIC, `$80` machine code (V1.1) |
| `$02AF`       |                  | Array type — copy of `$28` (V1.1)                 |
| `$02B0`       |                  | Array type — copy of `$29` (V1.1)                 |
| `$02B1`       | `LOADERR`        | Bit 7 set if format error                         |
| `$02C0`       |                  | Screen status: 0 GRAB, 2 TEXT, 3 HIRES            |
| `$02C1,$02C2` |                  | Charset start address in HIRES mode (V1.1)        |
| `$02C3`       |                  | HIRES cursor movement: 0 absolute, 1 relative     |
| `$02DF`       | `KEYBUF`         | Latest key from keyboard. Bit 7 set if valid      |
| `$02E0`       | `PARMERR`        | Non-zero if error in sound / graphics routines    |
| `$02E1,$02E2` | `PARAM1`         | First parameter for SOUND/graphics (low byte at `$02E1`) — also `INK` and `PAPER` |
| `$02E3,$02E4` | `PARAM2`         | Second parameter (low byte at `$02E3`)            |
| `$02E5,$02E6` | `PARAM3`         | Third parameter (low byte at `$02E5`)             |
| `$02E7,$02E8` |                  | Fourth parameter — only used by `MUSIC` and `PLAY` |
| `$02F1`       |                  | Bit 7 set if printer enabled                      |
| `$02F2`       |                  | Bit 7 = EDIT flag                                 |
| `$02F4`       |                  | TRACE flag (set if bit 7)                         |
| `$02F5,$02F6` | `BANGVEC`        | Indirect jump for `!` routine                     |
| `$02F8`       |                  | Temporary row indicator for `PLOT`                |
| `$02FB-$02FD` |                  | Jump to `&` routine                               |

`$026A` is the master flag byte:

| Bit | When set                                       |
| --- | ---------------------------------------------- |
| 0   | Cursor on                                      |
| 1   | Print-out to screen enabled                    |
| 2   | (unused)                                       |
| 3   | Disable keyclick                               |
| 4   | Previous printed character was ESC             |
| 5   | Protect columns 0 and 1 of screen              |
| 6   | Double-height characters                       |
| 7   | (unused)                                       |

The `Vl.1` jump-table block at `$0238-$0249` is the OS dispatch table.
On reset, `$F88F` copies a small jump table from ROM at `$F87C-$F88E`
into `$0238-$024A` so the OS can be redirected by overwriting these
three-byte JMPs in RAM. `IRQVec` (`$0244`-`$0246`) is the standard
interception point used by tape loaders, debuggers, and Sedoric.

The four parameter slots `$02E1-$02E8` are how BASIC commands marshal
arguments to the OS routines: `INK n` writes `n` to `$02E1`, `PAPER n`
writes to `$02E1` too, and `SOUND a,b,c` fills `$02E1` / `$02E3` /
`$02E5`. ROM patches that need to short-circuit a call site can read
these directly.

## 5. Page 3 — `$0300-$03FF` (I/O area)

The ULA decodes any access to page 3 and drops `IO` low; the on-board
6522 VIA responds to `$0300-$030F`. For `$0310-$03FF` the ULA *also*
asserts I/O, but expansion devices on the bus can pull the `I/O CONTROL`
line low to inhibit the internal VIA and claim the address themselves.
That is how Microdisc, Jasmin, Pravetz, the ACIA, the lightpen and
joystick interfaces share the page.

Because the ULA only needs page 3 to be detected to drop `IO`, every VIA
register at `$0300-$030F` is also visible at every `$0310 + 16k` mirror
within page 3 if no expansion device claims that address. The convention
is to always access the VIA at `$0300-$030F`; mirrored access can be
broken by an attached card.

### 5.1 6522 VIA register map (`$0300-$030F`)

| Addr   | Reg   | Function                                                    |
| ------ | ----- | ----------------------------------------------------------- |
| `$0300`| IORB  | Port B I/O register (handshake-aware)                       |
| `$0301`| IORA  | Port A I/O register (handshake-aware)                       |
| `$0302`| DDRB  | Port B data direction (1 = output)                          |
| `$0303`| DDRA  | Port A data direction                                       |
| `$0304`| T1CL  | Timer 1 counter low                                         |
| `$0305`| T1CH  | Timer 1 counter high                                        |
| `$0306`| T1LL  | Timer 1 latch low                                           |
| `$0307`| T1LH  | Timer 1 latch high                                          |
| `$0308`| T2CL  | Timer 2 latch / counter low                                 |
| `$0309`| T2CH  | Timer 2 counter high                                        |
| `$030A`| SR    | Shift register                                              |
| `$030B`| ACR   | Auxiliary control register (timer modes, latching)          |
| `$030C`| PCR   | Peripheral control register (CA1/CA2/CB1/CB2 modes)         |
| `$030D`| IFR   | Interrupt flag register (write 1 to clear)                  |
| `$030E`| IER   | Interrupt enable register                                   |
| `$030F`| IORA  | Port A I/O register without handshake — preferred for PSG bus |

Port pin assignments on the Oric main board:

| VIA pin   | Used for                                                |
| --------- | ------------------------------------------------------- |
| PA0..PA7  | Shared 8-bit bus to AY-3-8912 PSG **and** Centronics    |
| CA1       | Centronics ACK input                                    |
| CA2       | PSG `BC1`                                               |
| PB0..PB2  | Keyboard row select (3-bit, 8 rows demuxed)             |
| PB3       | Keyboard sense input (1 = key pressed)                  |
| PB4       | Centronics `STROBE` output                              |
| PB5       | Not connected on Oric-1/Atmos                           |
| PB6       | Cassette motor relay                                    |
| PB7       | Cassette output (1-bit DAC)                             |
| CB1       | Cassette input                                          |
| CB2       | PSG `BDIR`                                              |

VIA timer 1 is what the BASIC ROM uses for the 100 Hz "system tick"
interrupt that decrements timers in page 2 (cursor blink, `WAIT`,
keyboard auto-repeat).

### 5.2 PSG (AY-3-8912) access

The PSG has no memory address. Its `BC1` and `BDIR` lines are wired to
VIA `CA2` and `CB2`, so writing to `$030C` (PCR) selects the PSG
operation, then port A (`$030F` for the no-handshake path) carries the
data:

| BDIR (CB2) | BC1 (CA2) | Operation                      |
| ---------- | --------- | ------------------------------ |
| 0          | 0         | PSG idle                       |
| 0          | 1         | Read selected PSG register     |
| 1          | 0         | Write selected PSG register    |
| 1          | 1         | Latch register index           |

PSG register 14 (`$0E`) is its own 8-bit I/O port, and on the Oric it
selects the keyboard column being scanned: a single 0 bit in an
otherwise `$FF` value picks one of the 8 columns (negative logic).
That column bit ANDs with the row selected via PB0..PB2, and the
result appears on PB3.

### 5.3 Page 3 expansion-device map

| Range          | Device                                              |
| -------------- | --------------------------------------------------- |
| `$0300-$030F`  | Internal VIA 6522 (always present)                  |
| `$0310`        | DK'tronics joystick interface — left port           |
| `$0310-$0313`  | Microdisc FDC WD1793                                |
| `$0314-$031B`  | Microdisc additional registers (drive/side/density/IRQ enable/ROMDIS, see §5.4) |
| `$0310-$031F`  | Pravetz FDC                                         |
| `$031C-$031F`  | Internal ACIA 6551 (Telestrat, Atmos RS232 cards)   |
| `$0320`        | DK'tronics joystick interface — right port          |
| `$0320-$032F`  | RS232 extension (Atmos) / second VIA 6522 (Telestrat) |
| `$0320-$03FF`  | **Pravetz disk ROM (8ddoshi.rom) — see §5.5**       |
| `$0330-$035F`  | Spare                                               |
| `$0360-$0371`  | Real-time clock ICM7170 (Telestrat / Atmos add-on)  |
| `$0380-$03DF`  | Spare                                               |
| `$03E0-$03E1`  | Oric Lightpen                                       |
| `$03E2-$03F3`  | Spare                                               |
| `$03F4-$03FF`  | Jasmin FDC WD1773                                   |

### 5.4 Microdisc registers (`$0314-$031B`)

Write to `$0314`:

| Bit | Meaning                                                          |
| --- | ---------------------------------------------------------------- |
| 7   | EPROM select (active low)                                        |
| 6,5 | Drive select 0..3                                                |
| 4   | Side select                                                      |
| 3   | Double-density enable (0 = double, 1 = single)                   |
| 2   | Data-separator clock divisor (with bit 3): 1 = double, 0 = single |
| 1   | ROMDIS — 0 disables internal BASIC ROM (overlay RAM visible)     |
| 0   | 1 enables FDC INTRQ to drive CPU IRQ and to be readable at `$0314` |

Read of `$0314` returns INTRQ in bit 7 (negative logic — 0 means FDC
requested an interrupt). Read of `$0318` returns DRQ in bit 7 (0 = ready
to transfer a byte).

### 5.5 Jasmin registers (`$03F4-$03FF`)

Below `$03F8` is the FDC 1773. Above it is interface logic:

| Address       | Function                                               |
| ------------- | ------------------------------------------------------ |
| `$03F8`       | bit 0 = side select                                    |
| `$03F9`       | Disk-controller reset (any write resets the FDC)       |
| `$03FA`       | bit 0 = overlay-RAM access (1 = enabled)               |
| `$03FB`       | bit 0 = ROMDIS (1 = internal BASIC ROM disabled)       |
| `$03FC-$03FF` | Drive 0/1/2/3 select (any write to one selects the corresponding drive) |

### 5.6 Pravetz 8D disk extension

The Pravetz 8D is a Bulgarian Oric Atmos clone whose floppy interface
is patterned after the Apple II Disk II rather than the Microdisc /
Jasmin lineage. The disk-side ROM (`8ddoshi.rom`) lives in a 2716
EPROM on the controller card, and its pages are made visible inside
page 3 of the Oric address space:

- **First EPROM page mapped at `$0320-$03FF`.** The first executable
  byte is at `$0320`. The Oric ROM variant `pravetzd.rom` autoboots
  by reading `$0320` and checking for `$78` (the `SEI` opcode that
  begins the disk init code) — if present, it boots the disk;
  otherwise it falls back to BASIC.
- **Second EPROM page** is selected by toggling a "second trigger" in
  the overlay controller; both pages share the same `$0320-$03FF`
  window, so the disk firmware bank-switches itself.
- The unmodified `pravetzt.rom` (tape-only Pravetz) does not autoboot
  the disk. To launch DOS the user types `CALL 800` in BASIC, which
  enters the disk ROM at `$0320` (`800` decimal). After DOS loads,
  the user runs a program by typing `-name.exe`; programmatically
  `CALL DEEK(#2A9)` (i.e. `CALL` to the address stored in `FILESTART`
  at `$02A9,$02AA`) jumps to the start of the most recently loaded
  binary.

For the MiSTer core, the practical implication is that **`CALL #320`
on a Pravetz 8D enters the FDC controller's on-board ROM**, not Oric
RAM — the byte at `#320` is `$78` only when the Pravetz disk EPROM
overlay is active, and the same `#320-#3FF` window holds the ACIA on
a Telestrat or RTC on `#0360`. Any code that conditionally probes
`#320` for `$78` is doing the same FDD-detection trick as
`pravetzd.rom`.

## 6. Page 4 — `$0400-$04FF`

Per the Atmos manual:

> Page 4 addresses between `#0400` and `#0420` are available for the
> user's machine-code programs, and the rest of the page is reserved
> for system use.

Concretely:

| Range         | Use                                                                    |
| ------------- | ---------------------------------------------------------------------- |
| `$0400-$0420` | Free user m/c on bare Atmos. Used heavily by short utility loaders.    |
| `$0421-$04FF` | Reserved for the OS / DOS:                                             |
|               | - **Sedoric** keeps its DOS dispatcher and command parser here.        |
|               | - **Microdisc**: when a Microdisc is connected, the boot ROM copies a small stub into `$0400-$04FF`. |
|               | - **Jasmin / TDOS**: TDOS lives in overlay RAM, but also uses page 4. This is the historical source of the Jasmin/Microdisc software-incompatibility complaints. |
|               | - **Pravetz DOS**: the Bulgarian DOS uses the area in much the same way Sedoric does. |

Software that uses page 4 as scratch should expect to corrupt DOS state
on systems where a disk is connected. The reverse is also true — a TAP
loader that hands control back to the BASIC `Ready` prompt with a
disk-DOS active will see the DOS reclaim its page-4 dispatcher.

## 7. ROM and CPU vectors

### 7.1 ROM layout

| Range          | Contents                                              |
| -------------- | ----------------------------------------------------- |
| `$C000-$ECC3`  | BASIC interpreter (commands, expression evaluator, FPA, tokeniser) |
| `$ECC4-$FFFF`  | Operating system: input/output, IRQ/NMI/RESET handlers, screen, keyboard, tape, sound primitives |

Hot ROM entry points (Atmos 1.1, from the AUG and `cc65/atmos.inc`):

| Addr     | Name        | Purpose                                       |
| -------- | ----------- | --------------------------------------------- |
| `$C592`  | `GETLINE`   | Input line from keyboard                      |
| `$EC21`  | `TEXT`      | `TEXT` command                                |
| `$EC33`  | `HIRES`     | `HIRES` command                               |
| `$F0C8`  | `CURSET`    | Set HIRES cursor position                     |
| `$F0FD`  | `CURMOV`    | Move HIRES cursor                             |
| `$F110`  | `DRAW`      | Draw a line                                   |
| `$F12D`  | `CHAR`      | Plot character on HIRES                       |
| `$F1C8`  | `POINT`     | Read HIRES pixel                              |
| `$F204`  | `PAPER`     | Set paper colour                              |
| `$F210`  | `INK`       | Set ink colour                                |
| `$F77C`  | `PRINT`     | Print to current output                       |
| `$F88F`  | (RESET)     | Reset entry — called from `$FFFC` vector       |
| `$F9AA`  | (RESET6522) | Reset the VIA to known state                   |
| `$FA9F`/`$FA85` | `PING`/`PING1` | Ping sound effect                       |
| `$FAB5`/`$FA9B` | `SHOOT`/`SHOOT1` | Shoot sound effect                    |
| `$FACB`/`$FAB1` | `EXPLODE`/`EXPLODE1` | Explode sound effect              |
| `$FAE1`/`$FAC7` | `ZAP`/`ZAP1` | Zap sound effect                          |
| `$FB14`/`$FAFA` | `TICK`/`TICK1` | Tick sound effect                       |
| `$FB2A`/`$FB10` | `TOCK`/`TOCK1` | Tock sound effect                       |

### 7.2 CPU hardware vectors (`$FFFA-$FFFF`)

| Vector  | Address  | Default target | Effect                                      |
| ------- | -------- | -------------- | ------------------------------------------- |
| NMI     | `$FFFA`  | `$0247`        | Indirected through page 2 (`JMP` at `$0247`) |
| RESET   | `$FFFC`  | `$F88F`        | Cold start                                   |
| IRQ/BRK | `$FFFE`  | `$0244`        | Indirected through page 2 (`JMP` at `$0244`) |

Because both NMI and IRQ vectors point into page 2 RAM, almost all
runtime ROM extensions (tape fast-loaders, debuggers, Sedoric, and the
TAP-segment loader in this core) hook by overwriting the `JMP`
instructions at `$0244` (IRQ) and `$0247` (NMI).

## 8. Hardware overview

A block diagram of how the chips talk:

```
              +-----------+
              |   6502    |  1 MHz, no NMI on Telestrat.
              +-----+-----+
                    |
        +-----------+----------+----------+
        |           |          |          |
+-------v-----+ +---v---+ +----v----+ +---v---+
|     ULA     | |  RAM  | |   ROM   | | I/O   |  Page 3
| HCS 10017   | | 48 K  | | 16 K @  | | $0300 |  decoded
| video + MMU | |       | | $C000   | | -$3FF |  by ULA
+--+----------+ +-------+ +---------+ +---+---+
   | video                                |
   | sync                            +----+----+--------+--------+
                                     |    VIA  |  PSG   | bus    |
                                     |   6522  | (8912) | exp.   |
                                     +----+----+----+---+--------+
                                          |         |     ext. FDC, ACIA, etc.
                                  +-------+----+    |
                                  | KB rows /  |    |
                                  | tape / ptr |    +--- KB cols (PSG IOA)
                                  +------------+
```

- **6502** at 1 MHz, NMI tied to a button on Oric-1/Atmos (and to nothing
  on Telestrat).
- **ULA** (`HCS 10017`) is the memory-management glue plus video
  generator. It generates clocks, reads the screen image once per frame,
  and asserts internal `IO` for any access to page 3 and `ROM_SEL` for
  any access to `$C000-$FFFF`.
- **VIA 6522** at `$0300-$030F` carries the keyboard sense, PSG select
  lines, cassette in/out, and Centronics handshake. Timer 1 drives the
  100 Hz system tick.
- **AY-3-8912 PSG** is *not* memory-mapped. Its data bus is shared with
  the Centronics port on VIA port A; its select lines are CA2/CB2.
  Register 14 is its 8-bit I/O port and selects the keyboard column.
- **Keyboard** is an 8 × 8 passive matrix scanned by software: write a
  3-bit row index to `PB0-PB2`, then write a column-select byte to PSG
  register 14, then read `PB3`.
- **Cassette** uses `PB7` as a 1-bit output (square-wave generator) and
  `CB1` as the input edge-detect line; VIA timer 2 measures inter-edge
  times for SLOW (300 baud, 2400/1200 Hz) and FAST encodings.
- **Screen** is generated directly by the ULA reading RAM. Background
  and foreground colour, character set, blink, double-height, 50/60 Hz,
  and TEXT/HIRES are all controlled by **serial attribute bytes** (bits
  6..5 = 00) embedded in the screen data. The first attribute on a line
  takes effect for the rest of the line, and the attribute byte itself
  displays as 6 background-coloured pixels.

## 9. Specific helpers for this core

### 9.1 What `CALL #320` does

The behaviour depends on whether a disk extension is fitted:

- **Bare Atmos** (no extension): `$0320-$032F` is RAM. `CALL $320`
  jumps into uninitialised page 3 — a crash unless the user POKEd code
  there first. The Atmos manual lists `$0320-$032F` as "RS232
  extension".
- **Microdisc / Jasmin**: `$0320` is still in the open page-3 window
  (not claimed by the WD179x at `$0310-$031B` or `$03F4-$03FF`). On
  these systems the address is unused.
- **Pravetz 8D with disk fitted**: `$0320` is the first byte of the
  on-controller `8ddoshi.rom`, normally `$78` (`SEI`). `CALL $320`
  enters the disk firmware. This is the same path `pravetzd.rom` takes
  automatically; users running `pravetzt.rom` reach DOS via `CALL 800`
  (decimal `800` = `$0320`) — the two `CALL`s are the *same* address.
- **Telestrat**: `$0320-$032F` is the second VIA 6522, so `CALL $320`
  jumps into a register, not code.

To detect a Pravetz disk from the Atmos side, `pravetzd.rom` reads
`PEEK($0320)` and checks for `$78`. The MiSTer core can simulate the
same behaviour by mapping a Pravetz EPROM image into `$0320-$03FF` of
the I/O page when the appropriate disk extension is selected.

### 9.2 Useful page-2 hooks for ROM patching

- **IRQ vector `$0244`** — interceptable IRQ entry. The default
  installed by `$F88F` is a `JMP` to the ROM IRQ service; a fast tape
  loader writes its own three-byte `JMP` here and chains.
- **`$023B-$023D`** — Get-key dispatcher. Handy for injecting synthetic
  key events.
- **`$024D` (tape speed)** — toggling between 0 (FAST, 2400 Hz) and 1
  (SLOW, 300 baud) without going through `STORE`/`RECALL`.
- **`$02A9-$02AC` (`FILESTART`/`FILEEND`)** — after a CLOAD, holds the
  loaded file's range. Smart CLOAD updates these when bypassing the
  ROM tape routine, so BASIC's `RUN` and `CONT` keep working.
- **`$02DF` (`KEYBUF`)** — last key with bit 7 = "valid". `$0779 LSR
  $02DF` (used in the `LIST` pause routine) clears the validity bit.

### 9.3 Useful zero-page hooks

- **`$00E8` (`CHARGOT`)** — entry into the BASIC tokenised-stream
  reader; many ROM routines `JSR $00E8` to fetch the next character.
- **`$00E9,$00EA` (`TXTPTR`)** — current position in the program; can
  be temporarily redirected to scan a string buffer in zero page.
- **`$009A,$009B`–`$00A7`** — start-of-BASIC, end-of-BASIC,
  end-of-variables, end-of-arrays, bottom-of-strings, `HIMEM`. These
  are the exact pointers a snapshot-style `RUN` of a freshly loaded
  binary needs to fix up.

## Sources

- *The ROM Disassembly* (Oric Advanced User Guide), Atmos BASIC 1.1.
  Library copy:
  <https://library.defence-force.org/books/content/oric_advanced_user_guide_rom_disassembly.pdf>
  (Appendix C = page 0, Appendix D = page 2).
- Defence Force Wiki, `oric:software:memory_maps`:
  <https://wiki.defence-force.org/doku.php?id=oric:software:memory_maps>.
- OSDK memory map: <https://www.osdk.org/index.php?page=documentation&subpage=memorymap>.
- cc65 `atmos.inc`:
  <https://github.com/cc65/cc65/blob/master/asminc/atmos.inc>.
- "Hardware Programming on the Oric" (oric.free.fr), the canonical
  hardware/PSG/keyboard/screen reference:
  <http://oric.free.fr/programming.html>.
- 48katmos site, port and VIA references:
  <http://www.48katmos.freeuk.com/ports.htm>.
- Twilighte's VIA documentation:
  <http://twilighte.oric.org/twinew/via.htm>.
- Pravetz 8D thread on the Defence Force forum (jorodr / Xeron / Dbug):
  <https://forum.defence-force.org/viewtopic.php?t=644>.
- Atmos manual (`docs/manual_atmos.md` in this repo) — chapter 5 ("Down
  memory lane") and chapter 11 ("Input/Output").
