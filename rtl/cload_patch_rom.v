//============================================================================
//  Smart CLOAD patch ROM — live read-side override (NOP-sled design)
//
//  Sits on the CPU read bus and substitutes patch bytes for specific
//  ROM addresses when smart_cload_en is high.
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
//    the trigger at $E8B7, fires another Smart CLOAD load, then
//    falls through to the original ROM at $E8BC for native autorun
//    dispatch. Multi-stage tapes load every segment via Smart CLOAD
//    instead of falling back to slow audio-pin decode.
//
//  Sources for the relevant ROM addresses: docs/Oric Rom.md.
//    CLOAD entry $E85B; argument parser $E7B2; post-load + autorun
//    block $E8BC-$E900; MC autorun JMP ($02A9) at $E8E5; BASIC
//    autorun JMP $C708 at $E900.
//============================================================================

module cload_patch_rom (
	input         enable,           // smart_cload_en — gates the override entirely
	input  [13:0] rom_addr,         // bios_addr from oricatmos.vhd (= cpu_ad[13:0])
	output        patch_active,     // 1 → CPU should read patch_data instead of ROM
	output  [7:0] patch_data
);

// 14-bit ROM offset: CPU $E85F → bios offset $285F (= $E85F & $3FFF).
wire in_cload_trampoline = (rom_addr >= 14'h285F) && (rom_addr <= 14'h28BB);

assign patch_active = enable && in_cload_trampoline;

reg [7:0] data_r;
always @(*) begin
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
		// $E85F-$E8B6: 88-byte NOP sled. Default below covers it.
		// (Default is also harmless outside the patch range because
		//  patch_active is gated on in_cload_trampoline.)
		default:  data_r = 8'hEA; // NOP
	endcase
end
assign patch_data = data_r;

endmodule
