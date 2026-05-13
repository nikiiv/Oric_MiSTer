//
// savestate_ui.sv — keyboard + OSD savestate trigger logic.
//
// Adapted from NES_MiSTer/rtl/savestate_ui.sv. Maps F1..F4 / Alt+F1..F4
// (PS/2 set 2 scancodes) and the OSD Save/Restore options to the
// ss_save / ss_load 1-cycle pulses consumed by snap_saver / snap_loader.
//
// F1/F2/F3/F4 alone   -> ss_load with slot 0/1/2/3
// Alt + F1/F2/F3/F4   -> ss_save with slot 0/1/2/3
// OSD Save/Restore    -> ss_save / ss_load on selected slot
//
// status_slot tracks the OSD "Savestate Slot" option so that selecting
// a slot via OSD also updates the internal slot register.
//
module savestate_ui
(
	input            clk,
	input     [10:0] ps2_key,
	input            allow_ss,
	input      [1:0] status_slot,
	input      [1:0] OSD_saveload,
	output reg       ss_save,
	output reg       ss_load,
	output     [1:0] selected_slot
);

reg [1:0] ss_base = 0;
reg [1:0] lastOSDsetting = 2'b00;
// Inter-cycle state declared at module scope with explicit initial values.
// (Previously these lived inside the always block and started X, which made
// the first key edge / Alt chord behave unpredictably across cold boots.)
reg       old_state = 1'b0;
reg       alt       = 1'b0;
reg [1:0] old_st    = 2'b0;

assign selected_slot = ss_base;

always @(posedge clk) begin
	old_state <= ps2_key[10];

	ss_save <= 1'b0;
	ss_load <= 1'b0;

	lastOSDsetting <= status_slot;

	if (allow_ss) begin
		// keyboard
		if (old_state != ps2_key[10]) begin
			case (ps2_key[7:0])
				8'h11: alt <= ps2_key[9];                                              // Alt
				// F1-F4: load slot 0-3 (or save if Alt held — PS/2 chord)
				8'h05: begin ss_save <= ps2_key[9] & alt;  ss_load <= ps2_key[9] & ~alt;  ss_base <= 2'd0; end // F1
				8'h06: begin ss_save <= ps2_key[9] & alt;  ss_load <= ps2_key[9] & ~alt;  ss_base <= 2'd1; end // F2
				8'h04: begin ss_save <= ps2_key[9] & alt;  ss_load <= ps2_key[9] & ~alt;  ss_base <= 2'd2; end // F3
				8'h0C: begin ss_save <= ps2_key[9] & alt;  ss_load <= ps2_key[9] & ~alt;  ss_base <= 2'd3; end // F4
				// F5-F8: save slot 0-3 (single-key, no Alt). Lets us trigger a
				// save over the Remote HTTP API which does not support chords.
				8'h03: begin ss_save <= ps2_key[9];  ss_base <= 2'd0; end // F5
				8'h0B: begin ss_save <= ps2_key[9];  ss_base <= 2'd1; end // F6
				8'h83: begin ss_save <= ps2_key[9];  ss_base <= 2'd2; end // F7
				8'h0A: begin ss_save <= ps2_key[9];  ss_base <= 2'd3; end // F8
				default: ;
			endcase
		end

		if (lastOSDsetting != status_slot) begin
			ss_base <= status_slot;
		end

		// OSD edge-trigger
		old_st <= OSD_saveload;
		if (old_st[0] ^ OSD_saveload[0]) ss_save <= OSD_saveload[0];
		if (old_st[1] ^ OSD_saveload[1]) ss_load <= OSD_saveload[1];
	end
end

endmodule
