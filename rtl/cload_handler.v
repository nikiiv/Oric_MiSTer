//============================================================================
//  Smart CLOAD POC handler
//
//  Bidirectional Oric ↔ core trap. The patched BIOS at $E85F does
//  STA $0320; oricatmos.vhd decodes that write into a single-cycle
//  cload_we strobe. On that strobe we:
//    1. Halt the CPU (active=1).
//    2. Read the null-terminated filename from $027F via the spram
//       address mux (drive ram_addr with ram_we=0, then sample ram_q
//       three cycles later — one for the Oric.sv mux register, one
//       for the spram's clocked output, one for our own state edge).
//    3. Paint a 40-char status line at $BB80 in the form
//       "CLOAD: <name>" with INK-WHITE attribute, padded with spaces.
//    4. Drain a few cycles so the last write commits, then release
//       the CPU.
//
//  Mirrors the dma_tap_loader / snap_loader halt-and-paint pattern
//  (see rtl/dma_tap_loader.v D_STATUS / D_DRAIN). The new piece is
//  step 2 — neither existing loader reads from main RAM. Reads work
//  the same as writes: while we hold active=1 the CPU is halted and
//  Oric.sv's address mux feeds spram_addr from us, so two clocks
//  after we put an address out spram_q (= ram_q) carries that byte.
//============================================================================

module cload_handler (
	input         clk_sys,
	input         reset,
	input         cload_we,         // single-cycle pulse from oricatmos when CPU writes $0320-$032F
	input  [7:0]  ram_q,            // spram readback (mirrors top-level ram_q reg)

	output reg        active,       // halts CPU + selects loader's RAM-write path
	output reg [15:0] ram_addr,
	output reg  [7:0] ram_data,
	output reg        ram_we
);

localparam S_IDLE       = 4'd0,
           S_READ_SET   = 4'd1,
           S_READ_WAIT1 = 4'd2,
           S_READ_WAIT2 = 4'd3,
           S_READ_CAP   = 4'd4,
           S_PAINT      = 4'd5,
           S_DRAIN      = 4'd6,
           S_DONE       = 4'd7;

localparam [15:0] NAME_BUF_BASE = 16'h027F; // Atmos BASIC tape filename buffer
localparam [15:0] STATUS_BASE   = 16'hBB80; // Top-row screen RAM
localparam [3:0]  NAME_MAX      = 4'd12;    // Atmos max filename length

reg [3:0]  state;
reg [3:0]  name_idx;     // 0..NAME_MAX while reading; final length after read
reg [3:0]  name_len;
reg [7:0]  name_buf [0:11];
reg [5:0]  paint_idx;    // 0..39 across the status row
reg [1:0]  drain_cnt;

// Combinational: the character to paint at column paint_idx of the
// 40-char status row. Layout:
//   0       : INK-WHITE attribute byte ($07)
//   1..6    : "CLOAD:"
//   7       : ' '
//   8..19   : filename, padded with spaces if shorter than 12 chars
//   20..39  : ' '
function automatic [7:0] paint_char(input [5:0] col);
	reg [3:0] name_col;
	begin
		name_col = col[3:0] - 4'd8;
		case (col)
			6'd0:  paint_char = 8'h07;
			6'd1:  paint_char = "C";
			6'd2:  paint_char = "L";
			6'd3:  paint_char = "O";
			6'd4:  paint_char = "A";
			6'd5:  paint_char = "D";
			6'd6:  paint_char = ":";
			default: begin
				if (col >= 6'd8 && col < 6'd20) begin
					if (name_col < name_len)
						paint_char = name_buf[name_col];
					else
						paint_char = 8'h20;
				end
				else paint_char = 8'h20;
			end
		endcase
	end
endfunction

always @(posedge clk_sys) begin
	if (reset) begin
		state    <= S_IDLE;
		active   <= 1'b0;
		ram_we   <= 1'b0;
	end
	else begin
		ram_we <= 1'b0;
		case (state)
			S_IDLE: begin
				if (cload_we) begin
					state    <= S_READ_SET;
					active   <= 1'b1;
					name_idx <= 4'd0;
					name_len <= 4'd0;
				end
			end

			// Drive the read address. spram is synchronous + the top-level
			// mux register adds one cycle, so the byte arrives on ram_q
			// two clocks later (READ_CAP).
			S_READ_SET: begin
				ram_addr <= NAME_BUF_BASE + {12'd0, name_idx};
				ram_we   <= 1'b0;
				state    <= S_READ_WAIT1;
			end

			// Two wait cycles: one for the Oric.sv address-mux register,
			// one for the spram's clocked read. ram_q is valid in S_READ_CAP.
			S_READ_WAIT1: state <= S_READ_WAIT2;
			S_READ_WAIT2: state <= S_READ_CAP;

			S_READ_CAP: begin
				if (ram_q == 8'h00 || name_idx == NAME_MAX) begin
					name_len  <= name_idx;
					paint_idx <= 6'd0;
					state     <= S_PAINT;
				end
				else begin
					name_buf[name_idx] <= ram_q;
					name_idx <= name_idx + 4'd1;
					state    <= S_READ_SET;
				end
			end

			S_PAINT: begin
				ram_we   <= 1'b1;
				ram_addr <= STATUS_BASE + {10'd0, paint_idx};
				ram_data <= paint_char(paint_idx);
				if (paint_idx == 6'd39) begin
					drain_cnt <= 2'd0;
					state     <= S_DRAIN;
				end
				else paint_idx <= paint_idx + 6'd1;
			end

			// Hold active a few cycles so the last write commits through
			// the spram pipeline before the CPU resumes.
			S_DRAIN: begin
				drain_cnt <= drain_cnt + 2'd1;
				if (drain_cnt == 2'd3) state <= S_DONE;
			end

			S_DONE: begin
				active <= 1'b0;
				state  <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
