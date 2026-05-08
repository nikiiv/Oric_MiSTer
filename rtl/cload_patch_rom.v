//============================================================================
//  Tape load patch ROM — live read-side override
//
//  Sits on the CPU read bus and substitutes patch bytes for specific
//  ROM addresses when Ultra or Fast tape loading is selected.
//
//  Patch range: $E85F-$E8BB (93 bytes), the body of the Atmos CLOAD
//  handler at $E85B. Layout:
//
//      $E85F-$E8B6  : NOP × 88 (sled — funnels any mid-CLOAD JMPs)
//      $E8B7        : LDA #$01           ; A9 01
//      $E8B9        : STA $C000          ; 8D 00 C0
//                                         ; trigger fires; loader runs;
//                                         ; populates $02A9-$02AE etc.;
//                                         ; CPU resumes at $E8BC.
//      $E8BC+       : (unpatched original ROM)
//                     ↳ PLP                (balances $E85B PHP)
//                     ↳ verify-error path (skipped if not verifying)
//                     ↳ $E8D3 JSR $E651    print filename
//                     ↳ $E8D6 LDA $02AE; BEQ → BASIC autorun path
//                     ↳ $E8E5 JMP ($02A9)  MC autorun (jump to start)
//                     ↳ $E8E9-$E8F1       BASIC: $9C/$9D ← $02AB/$02AC
//                     ↳ $E8F3 JSR $C55F    line link setup
//                     ↳ $E8F6-$E900       BASIC autorun → JMP $C708
//
//  We keep:
//    $E85B  PHP                    (original — saves flags)
//    $E85C  JSR $E7B2              (original — parses CLOAD args,
//                                    populates $027F filename and
//                                    $025A/$025B JOIN/VERIFY flags)
//
//  Why NOP-sled instead of a self-contained patch:
//    Multi-stage MC tapes (e.g. gravitor.tap) have a stage-0 loader
//    stub that re-enters CLOAD body partway through, typically with
//    `JMP $E867`, expecting the original ROM tape-load path to pull
//    the next segment. With a 36-byte self-contained patch (the
//    earlier design at $E85F-$E882), `JMP $E867` would land on a
//    data byte interpreted as opcode `$02` (KIL) and jam the CPU.
//
//    The NOP-sled fixes this: any JMP into $E85F-$E8B6 NOP-sleds to
//    the trigger at $E8B7, fires another Ultra tape load, then
//    falls through to the original ROM at $E8BC for native autorun
//    dispatch. Multi-stage tapes load every segment via Ultra mode
//    instead of falling back to slow audio-pin decode.
//
//  Sources for the relevant ROM addresses: docs/Oric Rom.md.
//    CLOAD entry $E85B; argument parser $E7B2; post-load + autorun
//    block $E8BC-$E900; MC autorun JMP ($02A9) at $E8E5; BASIC
//    autorun JMP $C708 at $E900.
//============================================================================

module cload_patch_rom (
	input         ultra_enable,     // instant CLOAD segment loader patch
	input         fast_enable,      // ROM tape byte routine patch
	input  [7:0] fast_byte_data,    // TAP byte used as the LDA #imm operand
	input  [13:0] rom_addr,         // bios_addr from oricatmos.vhd (= cpu_ad[13:0])
	output        patch_active,     // 1 → CPU should read patch_data instead of ROM
	output  [7:0] patch_data
);

// 14-bit ROM offset: CPU $E85F → bios offset $285F (= $E85F & $3FFF).
wire in_cload_trampoline = (rom_addr >= 14'h285F) && (rom_addr <= 14'h28BB);
wire in_fast_getbyte     = (rom_addr >= 14'h26C9) && (rom_addr <= 14'h26D8);
wire in_fast_sync        = (rom_addr >= 14'h2735) && (rom_addr <= 14'h2737);

assign patch_active = (ultra_enable && in_cload_trampoline) ||
                      (fast_enable && (in_fast_getbyte || in_fast_sync));

reg [7:0] data_r;
always @(*) begin
	data_r = 8'hEA; // NOP default for patched padding bytes.

	if (fast_enable && in_fast_getbyte) begin
		case (rom_addr)
			// $E6C9: preserve Y/X, load next TAP byte as an immediate,
			// mirror it to $2F, restore Y/X, return A=$2F.
			14'h26C9: data_r = 8'h98; // TYA
			14'h26CA: data_r = 8'h48; // PHA
			14'h26CB: data_r = 8'h8A; // TXA
			14'h26CC: data_r = 8'h48; // PHA
			14'h26CD: data_r = 8'hA9; // LDA #fast_byte_data
			14'h26CE: data_r = fast_byte_data;
			14'h26CF: data_r = 8'h85; // STA $2F
			14'h26D0: data_r = 8'h2F;
			14'h26D1: data_r = 8'h68; // PLA
			14'h26D2: data_r = 8'hAA; // TAX
			14'h26D3: data_r = 8'h68; // PLA
			14'h26D4: data_r = 8'hA8; // TAY
			14'h26D5: data_r = 8'hA5; // LDA $2F
			14'h26D6: data_r = 8'h2F;
			14'h26D7: data_r = 8'h60; // RTS
			14'h26D8: data_r = 8'hEA; // padding
			default:  data_r = 8'hEA;
		endcase
	end
	else if (fast_enable && in_fast_sync) begin
		case (rom_addr)
			// $E735: bypass cassette pulse sync. The ROM's TAPESYNC
			// caller still reads bytes until it sees the $24 marker.
			14'h2735: data_r = 8'hA2; // LDX #$00
			14'h2736: data_r = 8'h00;
			14'h2737: data_r = 8'h60; // RTS
			default:  data_r = 8'hEA;
		endcase
	end
	else begin
		case (rom_addr)
			// $E8B7  LDA #$01
			14'h28B7: data_r = 8'hA9;
			14'h28B8: data_r = 8'h01;
			// $E8B9  STA $C000          (trigger — halts CPU; loader runs;
			//                            populates $02A9-$02AE / $9A/$9B;
			//                            CPU resumes at $E8BC = original ROM PLP)
			14'h28B9: data_r = 8'h8D;
			14'h28BA: data_r = 8'h00;
			14'h28BB: data_r = 8'hC0;
			default:  data_r = 8'hEA;
		endcase
	end
end
assign patch_data = data_r;

endmodule
