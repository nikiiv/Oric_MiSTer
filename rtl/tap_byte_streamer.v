//============================================================================
//  Fast TAP byte streamer
//
//  Feeds Oric ROM GETTAPEBYTE one byte at a time from the shared file cache.
//  The patched ROM embeds byte_data as the immediate operand of
//  LDA #imm. When that operand is fetched, consume pulses and this
//  module prefetches the next TAP byte while the CPU is halted.
//
//  The patched SYNCTAPE entry asks this module to seek to a byte-level
//  TAP leader run before returning to the ROM. Fast mode still feeds
//  raw TAP bytes; the ROM consumes the leader, finds the $24 marker,
//  and parses the header/name/data itself.
//============================================================================

module tap_byte_streamer (
	input         clk_sys,
	input         reset,
	input         consume,
	input         sync_request,
	input         named_rewind,
	input         start_rewind,
	input         tape_load_pulse,
	input         rewind,
	input  [17:0] tape_end,
	input   [7:0] tape_data,

	output reg [17:0] cache_addr,
	output reg        active,
	output reg        start_rewind_ack,
	output reg  [7:0] byte_data
);

localparam S_IDLE       = 3'd0,
           S_PRIME      = 3'd1,
           S_CAPTURE    = 3'd2,
           S_SYNC_PRIME = 3'd3,
           S_SYNC_CHECK = 3'd4;

reg [2:0]  state;
reg [17:0] next_pos;
reg [17:0] scan_pos;
reg [17:0] sync_candidate;
reg [1:0]  sync_run;
reg        consume_d;
reg        sync_d;
reg        pending_named_rewind;
reg        sync_ack_pending;

wire at_eof = (next_pos > tape_end);
wire consume_pulse = consume && !consume_d;
wire sync_pulse = sync_request && !sync_d;
wire sync_rewinds = start_rewind || pending_named_rewind || named_rewind;

always @(posedge clk_sys) begin
	if (reset) begin
		state                <= S_IDLE;
		active               <= 1'b0;
		cache_addr           <= 18'd0;
		next_pos             <= 18'd0;
		scan_pos             <= 18'd0;
		sync_candidate       <= 18'd0;
		sync_run             <= 2'd0;
		byte_data            <= 8'h16;
		consume_d            <= 1'b0;
		sync_d               <= 1'b0;
		pending_named_rewind <= 1'b0;
		sync_ack_pending     <= 1'b0;
		start_rewind_ack     <= 1'b0;
	end
	else begin
		consume_d <= consume;
		sync_d    <= sync_request;
		start_rewind_ack <= 1'b0;

		if (tape_load_pulse || rewind) begin
			// Rewind only resets the logical stream position. Do not
			// prefetch here: the next SYNCTAPE request decides whether
			// to raw-rewind before ROM byte streaming begins.
			next_pos             <= 18'd0;
			scan_pos             <= 18'd0;
			sync_candidate       <= 18'd0;
			sync_run             <= 2'd0;
			byte_data            <= 8'h16;
			cache_addr           <= 18'd0;
			active               <= 1'b0;
			consume_d            <= 1'b0;
			sync_d               <= 1'b0;
			pending_named_rewind <= 1'b0;
			sync_ack_pending     <= 1'b0;
			start_rewind_ack     <= 1'b0;
			state                <= S_IDLE;
		end
		else begin
			if (named_rewind) pending_named_rewind <= 1'b1;

			case (state)
				S_IDLE: begin
					active <= 1'b0;

					if (sync_pulse) begin
						active           <= 1'b1;
						byte_data        <= 8'h16;
						sync_run         <= 2'd0;
						sync_ack_pending <= start_rewind;

						if (sync_rewinds) begin
							scan_pos             <= 18'd0;
							cache_addr           <= 18'd0;
							sync_candidate       <= 18'd0;
							pending_named_rewind <= 1'b0;
						end
						else begin
							scan_pos       <= next_pos;
							cache_addr     <= next_pos;
							sync_candidate <= next_pos;
						end

						state <= S_SYNC_PRIME;
					end
					else if (consume_pulse) begin
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

				// One wait state for filecache read latency.
				S_SYNC_PRIME: begin
					active <= 1'b1;
					state  <= S_SYNC_CHECK;
				end

				S_SYNC_CHECK: begin
					active <= 1'b1;

					if (scan_pos > tape_end) begin
						next_pos         <= tape_end + 18'd1;
						byte_data        <= 8'h00;
						active           <= 1'b0;
						start_rewind_ack <= sync_ack_pending;
						sync_ack_pending <= 1'b0;
						state            <= S_IDLE;
					end
					else if (tape_data == 8'h24 && sync_run >= 2'd2) begin
						// Leave the ROM before the leader. The next
						// GETTAPEBYTE calls consume the leader bytes and
						// marker through the normal byte path.
						next_pos         <= sync_candidate;
						byte_data        <= 8'h16;
						cache_addr       <= sync_candidate;
						active           <= 1'b0;
						start_rewind_ack <= sync_ack_pending;
						sync_ack_pending <= 1'b0;
						state            <= S_IDLE;
					end
					else begin
						if (tape_data == 8'h16) begin
							if (sync_run == 2'd0)
								sync_candidate <= scan_pos;
							if (sync_run < 2'd2)
								sync_run <= sync_run + 2'd1;
						end
						else begin
							sync_run <= 2'd0;
						end

						scan_pos   <= scan_pos + 18'd1;
						cache_addr <= scan_pos + 18'd1;
						state      <= S_SYNC_PRIME;
					end
				end

				// One wait state for filecache read latency.
				S_PRIME: begin
					cache_addr <= cache_addr + 18'd1;
					state      <= S_CAPTURE;
				end

				S_CAPTURE: begin
					byte_data <= tape_data;
					next_pos  <= next_pos + 18'd1;
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
