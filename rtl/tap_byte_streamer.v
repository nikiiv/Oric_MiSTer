//============================================================================
//  Fast TAP byte streamer
//
//  Feeds Oric ROM GETTAPEBYTE one byte at a time from tapecache.
//  The patched ROM embeds byte_data as the immediate operand of
//  LDA #imm. When that operand is fetched, consume pulses and this
//  module prefetches the next TAP byte while the CPU is halted.
//============================================================================

module tap_byte_streamer (
	input         clk_sys,
	input         reset,
	input         consume,
	input         tape_load_pulse,
	input         rewind,
	input  [15:0] tape_end,
	input   [7:0] tape_data,

	output reg [15:0] cache_addr,
	output reg        active,
	output reg  [7:0] byte_data
);

localparam S_IDLE    = 2'd0,
           S_PRIME   = 2'd1,
           S_CAPTURE = 2'd2;

reg [1:0]  state;
reg [15:0] next_pos;
reg        consume_d;

wire at_eof = (next_pos > tape_end);
wire consume_pulse = consume && !consume_d;

always @(posedge clk_sys) begin
	if (reset) begin
		state       <= S_IDLE;
		active      <= 1'b0;
		cache_addr  <= 16'd0;
		next_pos    <= 16'd0;
		byte_data   <= 8'h16;
		consume_d   <= 1'b0;
	end
	else begin
		consume_d <= consume;

		if (tape_load_pulse || rewind) begin
			next_pos   <= 16'd0;
			byte_data  <= 8'h16;
			cache_addr <= 16'd0;
			active     <= 1'b1;
			consume_d  <= 1'b0;
			state      <= S_PRIME;
		end

		else begin
			case (state)
				S_IDLE: begin
					active <= 1'b0;

					if (consume_pulse) begin
						if (at_eof) begin
							byte_data <= 8'h00;
						end
						else begin
							active     <= 1'b1;
							cache_addr <= next_pos;
							state      <= S_PRIME;
						end
					end
				end

				S_PRIME: begin
					cache_addr <= cache_addr + 16'd1;
					state      <= S_CAPTURE;
				end

				S_CAPTURE: begin
					byte_data <= tape_data;
					next_pos  <= next_pos + 16'd1;
					active    <= 1'b0;
					state     <= S_IDLE;
				end

				default: begin
					active <= 1'b0;
					state  <= S_IDLE;
				end
			endcase
		end
	end
end

endmodule
