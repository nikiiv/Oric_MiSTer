//============================================================================
//  Multi-stage TAP segment loader (Tape Load = Ultra)
//
//  Triggered by a single-cycle `trigger` pulse — driven from Oric.sv as
//  (c000_we && c000_data == 1 && tape_mode_ultra && tape_loaded).
//
//  The patched BASIC CLOAD handler (see rtl/cload_patch_rom.v) fires the
//  trigger every time the running program calls CLOAD. On each trigger
//  this module:
//
//    1. Halts the CPU (active=1) and grabs the spram + filecache buses.
//    2. Resumes scanning the filecache from `next_scan_pos` (0 on the
//       first call, "byte after the previous segment's payload" on
//       later calls — so multi-segment tapes pull one segment per call,
//       letting BASIC's inter-segment code run between).
//    3. Walks the tape image looking for sync (0x16) + marker (0x24),
//       parses the 9-byte header (autorun@+3, type@+2, end@+4/+5 BE,
//       start@+6/+7 BE), skips the null-terminated filename, then
//       streams the program payload into main RAM.
//    4. Writes the BASIC-state side effects the real ROM CLOAD path
//       would have left behind — start/end addresses at $02A9-$02AC,
//       autorun + type at $02AD/$02AE, TXTTAB at $9A/$9B for BASIC
//       programs, and clears the verify error counters at $025C/$025D.
//    5. Drains the spram pipeline, releases the CPU.
//
//  We deliberately do NOT paint a status row at $BB80. The ROM at
//  $E8D3 (JSR $E651) prints filename info to that address natively,
//  so any extra paint here would be redundant — and harmful for
//  HIRES programs that use the $BB80-$BFE7 area as their own data,
//  not a text screen. Stock CLOAD already disturbs that region; we
//  don't add to it.
//
//  All BASIC-state writes are derived from the disassembly recon at
//  docs/Oric Rom.md (CLOAD entry $E85B, header parser $E4AC).
//============================================================================

module tap_segment_loader (
	input         clk_sys,
	input         reset,
	input         trigger,            // c000_we && data==1 && tape_mode_ultra && tape_loaded
	input         tape_load_pulse,    // 1-cycle pulse on F1 download falling edge — resets next_scan_pos
	input  [17:0] tape_end,           // last cached byte address from F1 download
	input   [7:0] tape_data,          // shared filecache q (read data)

	output reg [17:0] cache_addr,     // filecache read address (used while active)
	output reg        active,         // halts CPU + selects loader's spram-write path
	output reg [15:0] ram_addr,       // main spram address while active
	output reg  [7:0] ram_data,
	output reg        ram_we
);

localparam T_IDLE   = 3'd0,
           T_INIT   = 3'd1,
           T_SCAN   = 3'd2,
           T_WRITE  = 3'd3,
           T_FX     = 3'd4,
           T_DRAIN  = 3'd5,
           T_DONE   = 3'd6;

reg  [2:0]  state;
reg  [17:0] bot_seg;
reg         eos;             // saw the 0x24 marker → past sync, parsing header
reg         name_done;
reg  [15:0] data_start;
reg  [15:0] data_end;
reg  [15:0] write_addr;
reg  [7:0]  prog_type;       // header +2
reg  [7:0]  autorun_byte;    // header +3 (the byte that lands in $02AD per ROM $E4BE loop)
reg  [3:0]  fx_step;
reg  [1:0]  drain_cnt;

// Persistent across triggers — only cleared on reset or new tape.
reg  [17:0] next_scan_pos;

wire        type_is_basic = (prog_type == 8'h00);

always @(posedge clk_sys) begin
	if (reset) begin
		state         <= T_IDLE;
		active        <= 1'b0;
		ram_we        <= 1'b0;
		next_scan_pos <= 18'd0;
		eos           <= 1'b0;
		name_done     <= 1'b0;
	end
	else begin
		ram_we <= 1'b0;

		// New F1 load → rewind to start.
		if (tape_load_pulse) next_scan_pos <= 18'd0;

		case (state)
			T_IDLE: begin
				if (trigger) begin
					state       <= T_INIT;
					active      <= 1'b1;
					cache_addr  <= next_scan_pos;
					bot_seg     <= 18'd0;
					eos         <= 1'b0;
					name_done   <= 1'b0;
				end
			end

			// Prime the read pipeline: cache_addr will be next_scan_pos+1
			// next cycle so tape_data corresponds to mem[next_scan_pos]
			// when T_SCAN starts running.
			T_INIT: begin
				cache_addr <= cache_addr + 18'd1;
				state      <= T_SCAN;
			end

			// Scan for sync marker, then capture header fields by offset.
			// tape_data at this cycle = mem[cache_addr - 1].
			T_SCAN: begin
				cache_addr <= cache_addr + 18'd1;
				if (cache_addr > tape_end) begin
					// Walked off the end without finding a segment — exit
					// quietly. ROM's autorun path will see whatever stale
					// $02xx values were last set; usually a no-op.
					drain_cnt <= 2'd0;
					state     <= T_DRAIN;
				end
				else if (!eos) begin
					if (tape_data == 8'h24) begin
						eos     <= 1'b1;
						bot_seg <= cache_addr; // first byte after 0x24
					end
				end
				else begin
					if (cache_addr - 18'd1 == bot_seg + 18'd2) prog_type            <= tape_data;
					if (cache_addr - 18'd1 == bot_seg + 18'd3) autorun_byte         <= tape_data;
					if (cache_addr - 18'd1 == bot_seg + 18'd4) data_end[15:8]       <= tape_data;
					if (cache_addr - 18'd1 == bot_seg + 18'd5) data_end[7:0]        <= tape_data;
					if (cache_addr - 18'd1 == bot_seg + 18'd6) data_start[15:8]     <= tape_data;
					if (cache_addr - 18'd1 == bot_seg + 18'd7) data_start[7:0]      <= tape_data;
					// Skip filename (null-terminated) — we don't need it
					// since the ROM's $E651 print uses $027F directly.
					if (cache_addr - 18'd1 >= bot_seg + 18'd9 && !name_done) begin
						if (tape_data == 8'h00) begin
							name_done  <= 1'b1;
							write_addr <= data_start;
							state      <= T_WRITE;
						end
					end
				end
			end

			// Stream bytes from cache to main RAM.
			// On entry: next-cycle tape_data is the first program byte.
			T_WRITE: begin
				cache_addr <= cache_addr + 18'd1;
				ram_we     <= 1'b1;
				ram_addr   <= write_addr;
				ram_data   <= tape_data;
				write_addr <= write_addr + 16'd1;
				if (write_addr == data_end || cache_addr > tape_end) begin
					next_scan_pos <= cache_addr; // resume position for next trigger
					fx_step       <= 4'd0;
					state         <= T_FX;
				end
			end

			// BASIC-state side effects — what the real ROM CLOAD path
			// leaves behind in $02xx and zero-page (per docs/Oric Rom.md
			// recon at $E4AC and $E89C-$E8B0). The unpatched ROM at
			// $E8BC+ reads these to drive the autorun decision and to
			// copy $02AB/$02AC into $9C/$9D for BASIC programs.
			//
			// Steps 0..7 always run. Steps 8..9 ($9A/$9B = TXTTAB) only
			// run for BASIC-type files.
			T_FX: begin
				ram_we <= 1'b1;
				case (fx_step)
					4'd0: begin ram_addr <= 16'h02A9; ram_data <= data_start[7:0];  end
					4'd1: begin ram_addr <= 16'h02AA; ram_data <= data_start[15:8]; end
					4'd2: begin ram_addr <= 16'h02AB; ram_data <= data_end[7:0];    end
					4'd3: begin ram_addr <= 16'h02AC; ram_data <= data_end[15:8];   end
					4'd4: begin ram_addr <= 16'h02AD; ram_data <= autorun_byte;     end
					4'd5: begin ram_addr <= 16'h02AE; ram_data <= prog_type;        end
					4'd6: begin ram_addr <= 16'h025C; ram_data <= 8'h00;            end
					4'd7: begin ram_addr <= 16'h025D; ram_data <= 8'h00;            end
					4'd8: begin ram_addr <= 16'h009A; ram_data <= data_start[7:0];  end
					4'd9: begin ram_addr <= 16'h009B; ram_data <= data_start[15:8]; end
					default: ;
				endcase
				fx_step <= fx_step + 4'd1;
				if ((fx_step == 4'd7 && !type_is_basic) || fx_step == 4'd9) begin
					drain_cnt <= 2'd0;
					state     <= T_DRAIN;
				end
			end

			// Hold active for a few cycles so the last write commits
			// through the spram_addr mux + spram register pipeline before
			// the CPU comes off halt.
			T_DRAIN: begin
				drain_cnt <= drain_cnt + 2'd1;
				if (drain_cnt == 2'd3) state <= T_DONE;
			end

			T_DONE: begin
				active <= 1'b0;
				state  <= T_IDLE;
			end

			default: state <= T_IDLE;
		endcase
	end
end

endmodule
