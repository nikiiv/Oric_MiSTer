//============================================================================
//  Multi-stage TAP segment loader (Smart CLOAD instant tape)
//
//  Triggered by a single-cycle `trigger` pulse — driven from Oric.sv as
//  (c000_we && c000_data == 1 && smart_cload_en && tape_loaded).
//
//  The patched BASIC CLOAD handler (see rtl/cload_patch_rom.v) fires the
//  trigger every time the running program calls CLOAD. On each trigger
//  this module:
//
//    1. Halts the CPU (active=1) and grabs the spram + tapecache buses.
//    2. Resumes scanning the tapecache from `next_scan_pos` (0 on the
//       first call, "byte after the previous segment's payload" on
//       later calls — so multi-segment tapes pull one segment per call,
//       letting BASIC's inter-segment code run between).
//    3. Walks the tape image looking for sync (0x16) + marker (0x24),
//       parses the 9-byte header (type@+2, end@+4/+5 BE, start@+6/+7
//       BE, autorun@+1), reads the null-terminated filename, then
//       streams the program payload into main RAM.
//    4. Writes the BASIC-state side effects the real ROM CLOAD path
//       would have left behind — start/end addresses at $02A9-$02AC,
//       autorun + type at $02AD/$02AE, TXTTAB/TXTEND at $9A-$9D for
//       BASIC programs, and clears the verify error counters at
//       $025C/$025D.
//    5. Paints a 40-char status row at $BB80 ("CLOAD: <name>"), drains
//       the spram pipeline, and releases the CPU.
//
//  Forked from rtl/dma_tap_loader.v — same cache scan / RAM stream
//  shape, with the per-segment trigger model and a new T_FX state in
//  place of the DMA loader's unconditional VARTAB/ARYTAB/STREND patch.
//
//  All BASIC-state writes are derived from the disassembly recon at
//  docs/Oric Rom.md (CLOAD entry $E85B, header parser $E4AC).
//============================================================================

module tap_segment_loader (
	input         clk_sys,
	input         reset,
	input         trigger,            // c000_we && data==1 && smart_cload_en && tape_loaded
	input         tape_load_pulse,    // 1-cycle pulse on F1 download falling edge — resets next_scan_pos
	input  [15:0] tape_end,           // last ioctl_addr seen during F1 download
	input   [7:0] tape_data,          // tapecache q (read data)

	output reg [15:0] cache_addr,     // tapecache read address (used while active)
	output reg        active,         // halts CPU + selects loader's spram-write path
	output reg [15:0] ram_addr,       // main spram address while active
	output reg  [7:0] ram_data,
	output reg        ram_we
);

localparam T_IDLE   = 4'd0,
           T_INIT   = 4'd1,
           T_SCAN   = 4'd2,
           T_WRITE  = 4'd3,
           T_FX     = 4'd4,
           T_STATUS = 4'd5,
           T_DRAIN  = 4'd6,
           T_DONE   = 4'd7;

reg  [3:0]  state;
reg  [15:0] bot_seg;
reg         eos;             // saw the 0x24 marker → past sync, parsing header
reg         name_done;
reg  [15:0] data_start;
reg  [15:0] data_end;
reg  [15:0] write_addr;
reg  [7:0]  prog_type;       // header +2
reg  [7:0]  autorun_byte;    // header +3 (the byte that lands in $02AD per ROM $E4BE loop)
reg  [7:0]  name_buf [0:11];
reg  [3:0]  name_pos;
reg  [3:0]  fx_step;
reg  [5:0]  status_idx;
reg  [1:0]  drain_cnt;

// Persistent across triggers — only cleared on reset or new tape.
reg  [15:0] next_scan_pos;

// True if this trigger ran out of tape before finding a segment.
reg         no_segment;

wire        type_is_basic = (prog_type == 8'h00);

function automatic [7:0] hex_digit(input [3:0] n);
	hex_digit = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
endfunction

always @(posedge clk_sys) begin
	if (reset) begin
		state         <= T_IDLE;
		active        <= 1'b0;
		ram_we        <= 1'b0;
		next_scan_pos <= 16'd0;
		eos           <= 1'b0;
		name_done     <= 1'b0;
		no_segment    <= 1'b0;
	end
	else begin
		ram_we <= 1'b0;

		// New F1 load → rewind to start.
		if (tape_load_pulse) next_scan_pos <= 16'd0;

		case (state)
			T_IDLE: begin
				if (trigger) begin
					state       <= T_INIT;
					active      <= 1'b1;
					cache_addr  <= next_scan_pos;
					bot_seg     <= 16'd0;
					eos         <= 1'b0;
					name_done   <= 1'b0;
					name_pos    <= 4'd0;
					no_segment  <= 1'b0;
				end
			end

			// Prime the read pipeline: cache_addr will be next_scan_pos+1
			// next cycle so tape_data corresponds to mem[next_scan_pos]
			// when T_SCAN starts running.
			T_INIT: begin
				cache_addr <= cache_addr + 16'd1;
				state      <= T_SCAN;
			end

			// Scan for sync marker, then capture header fields by offset.
			// tape_data at this cycle = mem[cache_addr - 1].
			T_SCAN: begin
				cache_addr <= cache_addr + 16'd1;
				if (cache_addr > tape_end) begin
					// Walked off the end without finding a segment.
					no_segment <= 1'b1;
					status_idx <= 6'd0;
					state      <= T_STATUS;
				end
				else if (!eos) begin
					if (tape_data == 8'h24) begin
						eos     <= 1'b1;
						bot_seg <= cache_addr; // first byte after 0x24
					end
				end
				else begin
					if (cache_addr - 16'd1 == bot_seg + 16'd3) autorun_byte         <= tape_data;
					if (cache_addr - 16'd1 == bot_seg + 16'd2) prog_type            <= tape_data;
					if (cache_addr - 16'd1 == bot_seg + 16'd4) data_end[15:8]       <= tape_data;
					if (cache_addr - 16'd1 == bot_seg + 16'd5) data_end[7:0]        <= tape_data;
					if (cache_addr - 16'd1 == bot_seg + 16'd6) data_start[15:8]     <= tape_data;
					if (cache_addr - 16'd1 == bot_seg + 16'd7) data_start[7:0]      <= tape_data;
					if (cache_addr - 16'd1 >= bot_seg + 16'd9 && !name_done) begin
						if (tape_data == 8'h00) begin
							name_done  <= 1'b1;
							write_addr <= data_start;
							state      <= T_WRITE;
						end
						else if (name_pos < 4'd12) begin
							name_buf[name_pos] <= tape_data;
							name_pos           <= name_pos + 4'd1;
						end
					end
				end
			end

			// Stream bytes from cache to main RAM.
			// On entry: next-cycle tape_data is the first program byte.
			T_WRITE: begin
				cache_addr <= cache_addr + 16'd1;
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
			// recon at $E4AC and $E89C-$E8B0).
			//
			// We write start/end + autorun + type + verify-error
			// counters here. The patched CLOAD code (cload_patch_rom.v)
			// runs its own follow-up after our trigger returns:
			//   $9C/$9D ← $02AB/$02AC (mirror of ROM at $E8E9-$E8F1),
			//   JSR $C55F (line links),
			//   then conditional autorun JMP based on $02AD/$02AE.
			// So we don't duplicate $9C/$9D here.
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
					status_idx <= 6'd0;
					state      <= T_STATUS;
				end
			end

			// Write a 40-char status line at $BB80: an INK-WHITE
			// attribute byte, then "CLOAD: <name12>" padded with spaces,
			// or "CLOAD: NO TAPE" if no segment was found.
			T_STATUS: begin
				ram_we   <= 1'b1;
				ram_addr <= 16'hBB80 + {10'd0, status_idx};
				case (status_idx)
					6'd0:  ram_data <= 8'h07;
					6'd1:  ram_data <= "C";
					6'd2:  ram_data <= "L";
					6'd3:  ram_data <= "O";
					6'd4:  ram_data <= "A";
					6'd5:  ram_data <= "D";
					6'd6:  ram_data <= ":";
					6'd7:  ram_data <= " ";
					6'd8,  6'd9,  6'd10, 6'd11, 6'd12, 6'd13,
					6'd14, 6'd15, 6'd16, 6'd17, 6'd18, 6'd19:
						if (no_segment) begin
							case (status_idx)
								6'd8:  ram_data <= "N";
								6'd9:  ram_data <= "O";
								6'd10: ram_data <= " ";
								6'd11: ram_data <= "T";
								6'd12: ram_data <= "A";
								6'd13: ram_data <= "P";
								6'd14: ram_data <= "E";
								default: ram_data <= 8'h20;
							endcase
						end
						else begin
							ram_data <= ((status_idx - 6'd8) < {2'd0, name_pos})
							            ? name_buf[status_idx - 6'd8]
							            : 8'h20;
						end
					default: ram_data <= 8'h20;
				endcase
				if (status_idx == 6'd39) begin
					drain_cnt <= 2'd0;
					state     <= T_DRAIN;
				end
				else status_idx <= status_idx + 6'd1;
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
