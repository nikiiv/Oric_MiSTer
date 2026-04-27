//============================================================================
//  Smart CLOAD patch ROM — live read-side override
//
//  Sits on the CPU read bus and substitutes patch bytes for specific
//  ROM addresses when smart_cload_en is high. Implemented as a plain
//  case statement — adding more patch ranges (or replacing the entire
//  CLOAD body with a 200-byte routine) is just adding more case rows.
//
//  Current payload (POC): 5 bytes at $E85F..$E863 that hijack the
//  Atmos CLOAD handler. Original sequence at $E85B is
//      $E85B  PHP / JSR $E7B2 / LDA $02AD / ORA $02AE / BNE $E871 / ...
//  We keep the PHP+JSR (so $E7B2 still parses the filename to $027F)
//  and overwrite from $E85F:
//      $E85F  STA $02FE     ; mailbox write — core decodes into cload_we
//      $E862  PLP           ; balance the PHP at $E85B
//      $E863  RTS           ; back to BASIC's READY>
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
wire in_cload_trampoline = (rom_addr >= 14'h285F) && (rom_addr <= 14'h2863);

assign patch_active = enable && in_cload_trampoline;

reg [7:0] data_r;
always @(*) begin
	case (rom_addr)
		14'h285F: data_r = 8'h8D; // STA abs
		14'h2860: data_r = 8'hFE; // $02FE lo
		14'h2861: data_r = 8'h02; // $02FE hi
		14'h2862: data_r = 8'h28; // PLP
		14'h2863: data_r = 8'h60; // RTS
		default:  data_r = 8'hEA; // NOP — never reached while patch_active=0
	endcase
end
assign patch_data = data_r;

endmodule
