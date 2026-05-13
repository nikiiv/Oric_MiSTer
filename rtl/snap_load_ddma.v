//============================================================================
//  Snapshot LOAD DDRAM->SPRAM DMA preamble.
//
//  Triggered by ss_load. Reads the size dword from the slot header, copies
//  the .sna payload from DDRAM into the shared filecache SPRAM, then pulses
//  trigger_out so the existing snap_loader runs against the freshly-loaded
//  cache (same path as a `Load Snapshot` ioctl download).
//
//  DDRAM slot layout matches snap_saver.v: [0..3]=counter (ignored on load),
//  [4..7]=size_in_dwords (LE), [8..]=.sna payload.
//
//  This module copies a fixed PAYLOAD_QWORDS QWORDs from slot+8 to the
//  filecache starting at address 0. snap_end is reported back so the loader
//  can detect EOF at the actual end of the .sna data instead of the QWORD-
//  aligned DMA window. ula_snap_mode_we triggers the existing snap_loader
//  which fetches mem[snap_pc] before releasing the CPU.
//============================================================================

module snap_load_ddma
(
	input             clk_sys,
	input             reset,

	input             ss_load,
	input      [1:0]  ss_slot,

	// DDRAM read port (shares the ch1 bus with snap_saver; arbitrated in
	// Oric.sv by save_active vs load_active gating).
	output reg [27:1] ch1_addr,
	output reg [63:0] ch1_din,
	output reg [7:0]  ch1_be,
	output reg        ch1_rnw,
	output reg        ch1_req,
	input      [63:0] ch1_dout,
	input             ch1_ready,

	// Filecache write port (one byte per cycle).
	output reg        fc_we,
	output reg [17:0] fc_addr,
	output reg [7:0]  fc_data,

	output reg        active,           // halts CPU, gates filecache write mux
	output reg [17:0] snap_end_out,     // last valid byte address in filecache
	output reg        trigger_out       // 1-cycle pulse to snap_loader
);

// Copy 65816 bytes (= 8227 QWORDs). Covers the 65810-byte .sna plus the 6
// trailing pad/zero bytes the saver places after the VIA block. The actual
// last valid .sna byte is at filecache offset 65809; snap_end_out reports
// that so snap_loader's EOF check fires immediately after VIA finishes.
localparam [13:0] PAYLOAD_QWORDS = 14'd8227;
localparam [17:0] SNA_LAST_BYTE  = 18'd65809;

function [27:0] slot_base;
	input [1:0] s;
	begin
		case (s)
			2'd0: slot_base = 28'h0000000;
			2'd1: slot_base = 28'h0014000;
			2'd2: slot_base = 28'h0028000;
			2'd3: slot_base = 28'h003C000;
		endcase
	end
endfunction

reg [27:0] cur_slot_base;
reg [13:0] qw_idx;        // QWORD counter 0..PAYLOAD_QWORDS-1
reg [63:0] qw_buf;        // last QWORD read from DDRAM
reg [2:0]  byte_idx;      // byte within QWORD being written to filecache
reg [3:0]  load_state;

localparam S_IDLE       = 4'd0;
localparam S_READ_QW    = 4'd1;
localparam S_WAIT_QW    = 4'd2;
localparam S_WRITE_BYTE = 4'd3;
localparam S_TRIGGER    = 4'd4;
localparam S_FINISH     = 4'd5;
localparam S_DONE       = 4'd6;

always @(posedge clk_sys) begin
	if (reset) begin
		load_state  <= S_IDLE;
		active      <= 1'b0;
		ch1_req     <= 1'b0;
		fc_we       <= 1'b0;
		trigger_out <= 1'b0;
	end
	else begin
		ch1_req     <= 1'b0;
		fc_we       <= 1'b0;
		trigger_out <= 1'b0;

		case (load_state)
			S_IDLE: begin
				if (ss_load) begin
					active        <= 1'b1;
					cur_slot_base <= slot_base(ss_slot);
					qw_idx        <= 14'd0;
					load_state    <= S_READ_QW;
				end
			end

			// Issue read for QWORD at slot_base + 8 + qw_idx*8.
			S_READ_QW: begin
				ch1_addr <= ((cur_slot_base + 28'd8) + {12'd0, qw_idx, 3'd0}) >> 1;
				ch1_din  <= 64'd0;
				ch1_be   <= 8'hFF;
				ch1_rnw  <= 1'b1;
				load_state <= S_WAIT_QW;
			end

			// Hold ch1_req high until ddram acks. See snap_saver.v for why
			// (CDC across CLK_VIDEO->clk_sys with a narrow pulse).
			S_WAIT_QW: begin
				ch1_req <= 1'b1;
				if (ch1_ready) begin
					ch1_req    <= 1'b0;
					qw_buf     <= ch1_dout;
					byte_idx   <= 3'd0;
					load_state <= S_WRITE_BYTE;
				end
			end

			// Write 8 bytes (one per cycle) from qw_buf into filecache.
			S_WRITE_BYTE: begin
				fc_we   <= 1'b1;
				fc_addr <= {qw_idx, byte_idx};            // 14+3 = 17 bits, +'b0' MSB
				fc_data <= qw_buf[byte_idx*8 +: 8];
				if (byte_idx == 3'd7) begin
					qw_idx <= qw_idx + 14'd1;
					if (qw_idx + 14'd1 == PAYLOAD_QWORDS) begin
						load_state <= S_TRIGGER;
					end
					else begin
						load_state <= S_READ_QW;
					end
				end
				else byte_idx <= byte_idx + 3'd1;
			end

			// Set snap_end and pulse the snap_loader trigger.
			// snap_loader runs and sets its own `active`; we keep ours
			// asserted until it finishes (no signal back, so we time it).
			S_TRIGGER: begin
				snap_end_out <= SNA_LAST_BYTE;
				trigger_out  <= 1'b1;
				load_state   <= S_FINISH;
			end

			// Hold active for a long-ish span so snap_loader can complete
			// (its longest internal wait is S_DRAIN at 1024 cycles, plus
			// the block walk). A fixed timeout is simpler than tracking
			// snap_loader.active from the outside. ~256K cycles ~ 5 ms.
			S_FINISH: begin
				qw_idx <= qw_idx + 14'd1;     // reuse counter as timer
				if (&qw_idx[13:0]) load_state <= S_DONE;
			end

			S_DONE: begin
				active     <= 1'b0;
				load_state <= S_IDLE;
			end

			default: load_state <= S_IDLE;
		endcase
	end
end

endmodule
