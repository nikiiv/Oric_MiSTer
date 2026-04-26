//============================================================================
//  Oric DMA TAP loader
//
//  Streams a buffered Oric .tap file into main RAM via the spram address
//  mux while the CPU is halted. Triggered on the falling edge of
//  ioctl_download with ioctl_index==3 (the F3 menu entry).
//
//  Walks the tape image looking for sync (0x16) + marker (0x24), parses
//  the 9-byte header (type@+2, end@+4/+5 BE, start@+6/+7 BE, +8 sep),
//  reads the null-terminated filename, then copies the program payload
//  into main RAM. Multi-segment tapes loop back to scan the next header.
//
//  After all payload is written it patches the BASIC zero-page pointers
//  VARTAB ($9C/$9D), ARYTAB ($9E/$9F), STREND ($A0/$A1) to end+1 of the
//  first segment so LIST / RUN / line editing behave like a real CLOAD.
//
//  Finally paints a 40-char status line at $BB80 with the program name,
//  type marker (B = BASIC, M = machine code, ? = unknown), start address
//  in hex, and a "xN" segment count.
//
//  Reads the tape image from a 64 KiB tapecache spram owned by the
//  parent — when active=1, the parent muxes cache_addr onto the
//  tapecache address bus and routes the q output back here as tape_data.
//============================================================================

module dma_tap_loader (
	input         clk_sys,
	input         reset,
	input         trigger,            // ioctl_downlD && ~ioctl_download && load_tape_dma
	input  [15:0] tape_end,           // last ioctl_addr seen during download
	input   [7:0] tape_data,          // tapecache q (read data)

	output reg [15:0] cache_addr,     // tapecache read address (used while active)
	output reg        active,         // halts CPU + selects loader's RAM-write path
	output reg [15:0] ram_addr,       // main spram address while active
	output reg  [7:0] ram_data,
	output reg        ram_we
);

localparam D_IDLE   = 4'd0,
           D_INIT   = 4'd1,
           D_SCAN   = 4'd2,
           D_WRITE  = 4'd3,
           D_NEXT   = 4'd4,
           D_PATCH  = 4'd5,
           D_STATUS = 4'd6,
           D_DRAIN  = 4'd7,
           D_DONE   = 4'd8;

reg  [3:0]  dma_state;
reg  [15:0] dma_bot_seg;
reg         dma_eos;
reg         dma_name_done;
reg  [15:0] dma_data_start;
reg  [15:0] dma_data_end;
reg  [15:0] dma_write_addr;
reg  [2:0]  dma_patch_step;
reg  [1:0]  dma_drain_cnt;
reg  [7:0]  dma_prog_type;
reg  [7:0]  dma_name_buf [0:11];
reg  [3:0]  dma_name_pos;
reg  [5:0]  dma_status_idx;
reg         dma_first_seg;
reg  [3:0]  dma_seg_count;
reg  [15:0] dma_patch_end;
reg  [15:0] dma_disp_start;
reg  [7:0]  dma_disp_type;

wire [15:0] dma_end_plus_1 = dma_patch_end + 16'd1;

function automatic [7:0] hex_digit(input [3:0] n);
	hex_digit = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
endfunction

always @(posedge clk_sys) begin
	if (reset) begin
		dma_state     <= D_IDLE;
		active        <= 1'b0;
		ram_we        <= 1'b0;
		dma_eos       <= 1'b0;
		dma_name_done <= 1'b0;
	end
	else begin
		ram_we <= 1'b0;
		case (dma_state)
			D_IDLE: begin
				if (trigger) begin
					dma_state     <= D_INIT;
					active        <= 1'b1;
					cache_addr    <= 16'd0;
					dma_bot_seg   <= 16'd0;
					dma_eos       <= 1'b0;
					dma_name_done <= 1'b0;
					dma_name_pos  <= 4'd0;
					dma_first_seg <= 1'b1;
					dma_seg_count <= 4'd1;
				end
			end

			// Prime the read pipeline: cache_addr will be 1 next cycle so
			// tape_data corresponds to mem[0] when D_SCAN starts running.
			D_INIT: begin
				cache_addr <= cache_addr + 16'd1;
				dma_state  <= D_SCAN;
			end

			// Scan for sync marker, then capture header fields by offset.
			// tape_data at this cycle = mem[cache_addr - 1].
			D_SCAN: begin
				cache_addr <= cache_addr + 16'd1;
				if (cache_addr > tape_end) begin
					dma_patch_step <= 3'd0;
					dma_state      <= D_PATCH;
				end
				else if (!dma_eos) begin
					if (tape_data == 8'h24) begin
						dma_eos     <= 1'b1;
						dma_bot_seg <= cache_addr; // first byte after 0x24
					end
				end
				else begin
					if (cache_addr - 16'd1 == dma_bot_seg + 16'd2) dma_prog_type        <= tape_data;
					if (cache_addr - 16'd1 == dma_bot_seg + 16'd4) dma_data_end[15:8]   <= tape_data;
					if (cache_addr - 16'd1 == dma_bot_seg + 16'd5) dma_data_end[7:0]    <= tape_data;
					if (cache_addr - 16'd1 == dma_bot_seg + 16'd6) dma_data_start[15:8] <= tape_data;
					if (cache_addr - 16'd1 == dma_bot_seg + 16'd7) dma_data_start[7:0]  <= tape_data;
					if (cache_addr - 16'd1 >= dma_bot_seg + 16'd9 && !dma_name_done) begin
						if (tape_data == 8'h00) begin
							dma_name_done  <= 1'b1;
							dma_write_addr <= dma_data_start;
							dma_state      <= D_WRITE;
							if (dma_first_seg) begin
								dma_patch_end  <= dma_data_end;
								dma_disp_start <= dma_data_start;
								dma_disp_type  <= dma_prog_type;
							end
						end
						else if (dma_first_seg && dma_name_pos < 4'd12) begin
							dma_name_buf[dma_name_pos] <= tape_data;
							dma_name_pos               <= dma_name_pos + 4'd1;
						end
					end
				end
			end

			// Stream bytes from cache to main RAM.
			// On entry: next-cycle tape_data is the first program byte.
			D_WRITE: begin
				cache_addr     <= cache_addr + 16'd1;
				ram_we         <= 1'b1;
				ram_addr       <= dma_write_addr;
				ram_data       <= tape_data;
				dma_write_addr <= dma_write_addr + 16'd1;
				if (dma_write_addr == dma_data_end || cache_addr > tape_end) begin
					dma_state <= D_NEXT;
				end
			end

			// End of one segment. If more bytes remain in the tape image,
			// reset segment-local state and re-enter D_SCAN to parse the
			// next header. Acts as the read-pipeline prime cycle (mirrors
			// D_INIT) so D_SCAN sees mem[cache_addr - 1] as expected.
			D_NEXT: begin
				cache_addr <= cache_addr + 16'd1;
				if (cache_addr > tape_end) begin
					dma_patch_step <= 3'd0;
					dma_state      <= D_PATCH;
				end
				else begin
					dma_eos       <= 1'b0;
					dma_bot_seg   <= 16'd0;
					dma_name_done <= 1'b0;
					dma_first_seg <= 1'b0;
					if (dma_seg_count != 4'hF) dma_seg_count <= dma_seg_count + 4'd1;
					dma_state     <= D_SCAN;
				end
			end

			// BASIC: write end+1 to VARTAB($9C/$9D), ARYTAB($9E/$9F),
			// STREND($A0/$A1). Discovered empirically: on a fresh Atmos boot
			// all three hold 1283 ($0503) and advance together as the user
			// types lines, so collapsing them all to end+1 mirrors real load.
			D_PATCH: begin
				ram_we <= 1'b1;
				case (dma_patch_step)
					3'd0: begin ram_addr <= 16'h009C; ram_data <= dma_end_plus_1[7:0];  end
					3'd1: begin ram_addr <= 16'h009D; ram_data <= dma_end_plus_1[15:8]; end
					3'd2: begin ram_addr <= 16'h009E; ram_data <= dma_end_plus_1[7:0];  end
					3'd3: begin ram_addr <= 16'h009F; ram_data <= dma_end_plus_1[15:8]; end
					3'd4: begin ram_addr <= 16'h00A0; ram_data <= dma_end_plus_1[7:0];  end
					3'd5: begin ram_addr <= 16'h00A1; ram_data <= dma_end_plus_1[15:8]; end
					default: ;
				endcase
				dma_patch_step <= dma_patch_step + 3'd1;
				if (dma_patch_step == 3'd5) begin
					dma_status_idx <= 6'd0;
					dma_state      <= D_STATUS;
				end
			end

			// Write a 40-char status line at $BB80 (top row): an INK-WHITE
			// attribute byte, then "DMA <name12> T:<B/M/?> @$XXXX xN"
			// padded with spaces. Name/type/start are the FIRST segment's;
			// xN is the total number of segments parsed (hex 1..F).
			D_STATUS: begin
				ram_we   <= 1'b1;
				ram_addr <= 16'hBB80 + {10'd0, dma_status_idx};
				case (dma_status_idx)
					6'd0:  ram_data <= 8'h07;
					6'd1:  ram_data <= "D";
					6'd2:  ram_data <= "M";
					6'd3:  ram_data <= "A";
					6'd4:  ram_data <= " ";
					6'd5,  6'd6,  6'd7,  6'd8,  6'd9,  6'd10,
					6'd11, 6'd12, 6'd13, 6'd14, 6'd15, 6'd16:
						ram_data <= ((dma_status_idx - 6'd5) < {2'd0, dma_name_pos})
						            ? dma_name_buf[dma_status_idx - 6'd5]
						            : 8'h20;
					6'd17: ram_data <= " ";
					6'd18: ram_data <= "T";
					6'd19: ram_data <= ":";
					6'd20: ram_data <= (dma_disp_type == 8'h00) ? "B"
					                 : (dma_disp_type == 8'h80) ? "M" : "?";
					6'd21: ram_data <= " ";
					6'd22: ram_data <= "@";
					6'd23: ram_data <= "$";
					6'd24: ram_data <= hex_digit(dma_disp_start[15:12]);
					6'd25: ram_data <= hex_digit(dma_disp_start[11:8]);
					6'd26: ram_data <= hex_digit(dma_disp_start[7:4]);
					6'd27: ram_data <= hex_digit(dma_disp_start[3:0]);
					6'd29: ram_data <= "x";
					6'd30: ram_data <= hex_digit(dma_seg_count);
					default: ram_data <= " ";
				endcase
				if (dma_status_idx == 6'd39) begin
					dma_drain_cnt <= 2'd0;
					dma_state     <= D_DRAIN;
				end
				else dma_status_idx <= dma_status_idx + 6'd1;
			end

			// Hold active for a few cycles so the last write commits
			// through the spram_addr mux + spram register pipeline before
			// the CPU comes off halt.
			D_DRAIN: begin
				dma_drain_cnt <= dma_drain_cnt + 2'd1;
				if (dma_drain_cnt == 2'd3) dma_state <= D_DONE;
			end

			D_DONE: begin
				active    <= 1'b0;
				dma_state <= D_IDLE;
			end

			default: dma_state <= D_IDLE;
		endcase
	end
end

endmodule
