//============================================================================
//  Smart CLOAD patch ROM — live read-side override
//
//  Sits on the CPU read bus and substitutes patch bytes for specific
//  ROM addresses when smart_cload_en is high. Implemented as a plain
//  case statement — adding more patch ranges (or replacing the entire
//  CLOAD body with a 200-byte routine) is just adding more case rows.
//
//  Current payload: 36 bytes at $E85F..$E882 that hijack the Atmos
//  CLOAD handler. Original sequence at $E85B is
//      $E85B  PHP / JSR $E7B2 / LDA $02AD / ORA $02AE / BNE $E871 / ...
//  We keep the PHP+JSR (so $E7B2 parses the filename to $027F and
//  the JOIN/VERIFY flags to $025A/$025B) and overwrite from $E85F
//  with the full post-load sequence — mirrors what the original
//  ROM does at $E8E9-$E900 after a successful tape load:
//
//      $E85F  LDA #$01           ; deterministic 1 for the mailbox
//      $E861  STA $C000          ; trigger — halts CPU; loader runs;
//                                  populates $02xx and $9A/$9B from
//                                  the segment header; resumes CPU.
//      $E864  PLP                ; balance the PHP at $E85B
//      $E865  LDX $02AB          ; copy end-of-basic into $9C/$9D
//      $E868  LDA $02AC          ;   (mirror $E8E9-$E8F1)
//      $E86B  STX $9C
//      $E86D  STA $9D
//      $E86F  JSR $C55F          ; set up BASIC line link pointers
//                                  (mirror $E8F3 — without this,
//                                  LIST and RUN see broken state).
//      $E872  LDA $02AD          ; autorun flag
//      $E875  BEQ done           ; not auto-run → RTS
//      $E877  LDA $02AE          ; file type
//      $E87A  BEQ basic_ar       ; type=$00 (BASIC) → JMP $C708
//      $E87C  JMP ($02A9)        ; type=$80 (MC) → indirect to start
//      $E87F  JMP $C708          ; basic_ar: enter BASIC RUN
//      $E882  RTS                ; done: back to READY>
//
//  $C000 is the unified host mailbox — value 1 lights LED_USER and
//  triggers the multi-stage tap segment loader; value 0 only clears
//  LED_USER.
//
//  Source for the addresses: docs/Oric Rom.html:5135.
//============================================================================

module cload_patch_rom (
	input         enable,           // smart_cload_en — gates the override entirely
	input  [13:0] rom_addr,         // bios_addr from oricatmos.vhd (= cpu_ad[13:0])
	output        patch_active,     // 1 → CPU should read patch_data instead of ROM
	output  [7:0] patch_data
);

// Range check on the 14-bit ROM offset (CPU $E85F = bios offset $285F,
// since $E85F & $3FFF = $285F). Add more ranges with `||` when payload
// grows.
wire in_cload_trampoline = (rom_addr >= 14'h285F) && (rom_addr <= 14'h2882);

assign patch_active = enable && in_cload_trampoline;

reg [7:0] data_r;
always @(*) begin
	case (rom_addr)
		// $E85F  LDA #$01
		14'h285F: data_r = 8'hA9;
		14'h2860: data_r = 8'h01;
		// $E861  STA $C000          (trigger; halts + resumes CPU)
		14'h2861: data_r = 8'h8D;
		14'h2862: data_r = 8'h00;
		14'h2863: data_r = 8'hC0;
		// $E864  PLP                (balance PHP at $E85B)
		14'h2864: data_r = 8'h28;
		// $E865  LDX $02AB
		14'h2865: data_r = 8'hAE;
		14'h2866: data_r = 8'hAB;
		14'h2867: data_r = 8'h02;
		// $E868  LDA $02AC
		14'h2868: data_r = 8'hAD;
		14'h2869: data_r = 8'hAC;
		14'h286A: data_r = 8'h02;
		// $E86B  STX $9C
		14'h286B: data_r = 8'h86;
		14'h286C: data_r = 8'h9C;
		// $E86D  STA $9D
		14'h286D: data_r = 8'h85;
		14'h286E: data_r = 8'h9D;
		// $E86F  JSR $C55F          (set up BASIC line links)
		14'h286F: data_r = 8'h20;
		14'h2870: data_r = 8'h5F;
		14'h2871: data_r = 8'hC5;
		// $E872  LDA $02AD          (autorun flag)
		14'h2872: data_r = 8'hAD;
		14'h2873: data_r = 8'hAD;
		14'h2874: data_r = 8'h02;
		// $E875  BEQ done (+$0B → $E882)
		14'h2875: data_r = 8'hF0;
		14'h2876: data_r = 8'h0B;
		// $E877  LDA $02AE          (file type)
		14'h2877: data_r = 8'hAD;
		14'h2878: data_r = 8'hAE;
		14'h2879: data_r = 8'h02;
		// $E87A  BEQ basic_ar (+$03 → $E87F)
		14'h287A: data_r = 8'hF0;
		14'h287B: data_r = 8'h03;
		// $E87C  JMP ($02A9)        (MC autorun → indirect start)
		14'h287C: data_r = 8'h6C;
		14'h287D: data_r = 8'hA9;
		14'h287E: data_r = 8'h02;
		// $E87F  JMP $C708          (basic_ar — BASIC RUN)
		14'h287F: data_r = 8'h4C;
		14'h2880: data_r = 8'h08;
		14'h2881: data_r = 8'hC7;
		// $E882  RTS                (done)
		14'h2882: data_r = 8'h60;
		default:  data_r = 8'hEA; // NOP — never reached while patch_active=0
	endcase
end
assign patch_data = data_r;

endmodule
