//============================================================================
// TAP autorun keyboard injector
//
// When a TAP finishes downloading, this FSM can request a normal Oric reset,
// wait for BASIC to reach READY, then inject CLOAD"" + Return as PS/2 events.
// It deliberately drives the existing keyboard path instead of poking BASIC
// internals so all Tape Load modes work.
//============================================================================

module tap_autorun_keys #(
	parameter integer STARTUP_DELAY = 72000000, // ~3 s at 24 MHz
	parameter integer KEY_DELAY     = 1200000   // ~50 ms at 24 MHz
) (
	input             clk_sys,
	input             hard_reset,
	input             start,
	input             oric_reset,

	output reg        reset_req,
	output reg        active,
	output reg [10:0] ps2_key
);

localparam A_IDLE              = 4'd0,
           A_WAIT_RESET_ASSERT = 4'd1,
           A_WAIT_RESET_RELEASE= 4'd2,
           A_WAIT_STARTUP      = 4'd3,
           A_EVENT             = 4'd4,
           A_GAP               = 4'd5,
           A_DONE              = 4'd6;

localparam [7:0] SC_C      = 8'h21,
                 SC_L      = 8'h4B,
                 SC_O      = 8'h44,
                 SC_A      = 8'h1C,
                 SC_D      = 8'h23,
                 SC_SHIFT  = 8'h12,
                 SC_QUOTE  = 8'h52,
                 SC_RETURN = 8'h5A;

reg [3:0]  state;
reg [4:0]  event_idx;
reg [31:0] wait_cnt;

reg        event_pressed;
reg [7:0]  event_code;

always @(*) begin
	event_pressed = 1'b0;
	event_code    = 8'h00;
	case (event_idx)
		5'd0:  begin event_pressed = 1'b1; event_code = SC_C;      end
		5'd1:  begin event_pressed = 1'b0; event_code = SC_C;      end
		5'd2:  begin event_pressed = 1'b1; event_code = SC_L;      end
		5'd3:  begin event_pressed = 1'b0; event_code = SC_L;      end
		5'd4:  begin event_pressed = 1'b1; event_code = SC_O;      end
		5'd5:  begin event_pressed = 1'b0; event_code = SC_O;      end
		5'd6:  begin event_pressed = 1'b1; event_code = SC_A;      end
		5'd7:  begin event_pressed = 1'b0; event_code = SC_A;      end
		5'd8:  begin event_pressed = 1'b1; event_code = SC_D;      end
		5'd9:  begin event_pressed = 1'b0; event_code = SC_D;      end
		5'd10: begin event_pressed = 1'b1; event_code = SC_SHIFT;  end
		5'd11: begin event_pressed = 1'b1; event_code = SC_QUOTE;  end
		5'd12: begin event_pressed = 1'b0; event_code = SC_QUOTE;  end
		5'd13: begin event_pressed = 1'b1; event_code = SC_QUOTE;  end
		5'd14: begin event_pressed = 1'b0; event_code = SC_QUOTE;  end
		5'd15: begin event_pressed = 1'b0; event_code = SC_SHIFT;  end
		5'd16: begin event_pressed = 1'b1; event_code = SC_RETURN; end
		5'd17: begin event_pressed = 1'b0; event_code = SC_RETURN; end
		default: ;
	endcase
end

always @(posedge clk_sys) begin
	if (hard_reset) begin
		state     <= A_IDLE;
		event_idx <= 5'd0;
		wait_cnt  <= 32'd0;
		reset_req <= 1'b0;
		active    <= 1'b0;
		ps2_key   <= 11'd0;
	end
	else begin
		if (start) begin
			state     <= A_WAIT_RESET_ASSERT;
			event_idx <= 5'd0;
			wait_cnt  <= 32'd0;
			reset_req <= 1'b1;
			active    <= 1'b1;
		end
		else begin
			case (state)
				A_IDLE: begin
					reset_req <= 1'b0;
					active    <= 1'b0;
				end

				A_WAIT_RESET_ASSERT: begin
					reset_req <= 1'b1;
					active    <= 1'b1;
					if (oric_reset) begin
						reset_req <= 1'b0;
						state     <= A_WAIT_RESET_RELEASE;
					end
				end

				A_WAIT_RESET_RELEASE: begin
					reset_req <= 1'b0;
					active    <= 1'b1;
					if (!oric_reset) begin
						wait_cnt <= 32'd0;
						state    <= A_WAIT_STARTUP;
					end
				end

				A_WAIT_STARTUP: begin
					active <= 1'b1;
					if (wait_cnt == STARTUP_DELAY - 1) begin
						wait_cnt <= 32'd0;
						state    <= A_EVENT;
					end
					else wait_cnt <= wait_cnt + 32'd1;
				end

				A_EVENT: begin
					active  <= 1'b1;
					ps2_key <= {~ps2_key[10], event_pressed, 1'b0, event_code};
					state   <= A_GAP;
				end

				A_GAP: begin
					active <= 1'b1;
					if (wait_cnt == KEY_DELAY - 1) begin
						wait_cnt <= 32'd0;
						if (event_idx == 5'd17) state <= A_DONE;
						else begin
							event_idx <= event_idx + 5'd1;
							state     <= A_EVENT;
						end
					end
					else wait_cnt <= wait_cnt + 32'd1;
				end

				A_DONE: begin
					reset_req <= 1'b0;
					active    <= 1'b0;
					state     <= A_IDLE;
				end

				default: state <= A_IDLE;
			endcase
		end
	end
end

endmodule
