//============================================================================
//  Oric snapshot SAVE (.sna).
//
//  Mirror of rtl/snap_loader.v. Reads CPU/VIA/AY/ULA state combinationally
//  from oricatmos and main RAM byte-by-byte from the halted SPRAM, and
//  emits an Oricutron-format .sna byte stream directly into a DDRAM slot
//  declared by the SS conf_str token (see Oric.sv).
//
//  Slot layout (matches Main_MiSTer's SS protocol, user_io.cpp:1890):
//    [0..3]   = 32-bit counter (LE). Incremented to signal save complete.
//    [4..7]   = 32-bit size in dwords (LE). ARM persists (size+2)*4 bytes.
//    [8..]    = payload (Oricutron .sna typed-block container).
//
//  .sna content (65810 bytes):
//    OSN  block: 4-byte tag + 4-byte BE size (21)  + 21-byte body
//    DATA block: 4-byte tag + 4-byte BE size (64K) + 65536-byte body (main RAM)
//    CPU  block: 4-byte tag + 4-byte BE size (21)  + 21-byte body
//    AY   block: 4-byte tag + 4-byte BE size (153) + 153-byte body
//    VIA  block: 4-byte tag + 4-byte BE size (39)  + 39-byte body
//
//  Byte mapping per block matches snap_loader's parser. Fields we do not
//  populate are emitted as zero; the loader skips them.
//
//  DATA block is 64 KiB (the Oric core's main RAM size); Oricutron desktop
//  emits 80 KiB. MiSTer<->MiSTer interchange works; for desktop
//  compatibility, extend with zero pad (TBD).
//============================================================================

module snap_saver
(
	input             clk_sys,
	input             reset,

	input             ss_save,        // 1-cycle pulse to start save
	input      [1:0]  ss_slot,        // 0..3 — selects DDRAM slot

	// Chip state inputs (latched once at save start). cpu_regs_in packs
	// T65's {PC[15:0], S[15:0], P[7:0], Y[7:0], X[7:0], A[7:0]}.
	input      [63:0] cpu_regs_in,
	input      [7:0]  via_orb_in, via_ora_in,
	input      [7:0]  via_ddrb_in, via_ddra_in,
	input      [7:0]  via_t1l_l_in, via_t1l_h_in,
	input      [7:0]  via_t2l_l_in, via_t2l_h_in,
	input      [7:0]  via_sr_in, via_acr_in, via_pcr_in,
	input      [7:0]  via_ier_in, via_ifr_in,
	input      [15:0] via_t1c_in, via_t2c_in,
	input             via_t1_active_in, via_t2_active_in,
	input      [119:0] ay_regs_in,
	input      [3:0]  ay_creg_in,
	input      [2:0]  ula_mode_in,

	// RAM read interface (Oric.sv routes spram_addr from us during active).
	output reg [15:0] ram_addr,
	input      [7:0]  ram_q,

	output reg        active,         // halts CPU + selects saver's RAM path

	// DDRAM write port (1-cycle ch1_req pulse per byte).
	output reg [27:1] ch1_addr,
	output reg [63:0] ch1_din,
	output reg [7:0]  ch1_be,
	output reg        ch1_rnw,
	output reg        ch1_req,
	input             ch1_ready
);

// .sna byte layout. Total 65810 bytes.
localparam [16:0] OSN_TAG_BEG   = 17'd0;        // 4 bytes  "OSN\0"
localparam [16:0] OSN_SIZE_BEG  = 17'd4;        // 4 bytes  BE 21
localparam [16:0] OSN_BODY_BEG  = 17'd8;        // 21 bytes
localparam [16:0] OSN_END       = 17'd28;
localparam [16:0] DATA_TAG_BEG  = 17'd29;       // 4 bytes  "DATA"
localparam [16:0] DATA_SIZE_BEG = 17'd33;       // 4 bytes  BE 65536
localparam [16:0] DATA_BODY_BEG = 17'd37;       // 65536 bytes
localparam [16:0] DATA_END      = 17'd65572;
localparam [16:0] CPU_TAG_BEG   = 17'd65573;    // 4 bytes  "CPU\0"
localparam [16:0] CPU_SIZE_BEG  = 17'd65577;    // 4 bytes  BE 21
localparam [16:0] CPU_BODY_BEG  = 17'd65581;    // 21 bytes
localparam [16:0] CPU_END       = 17'd65601;
localparam [16:0] AY_TAG_BEG    = 17'd65602;    // 4 bytes  "AY\0\0"
localparam [16:0] AY_SIZE_BEG   = 17'd65606;    // 4 bytes  BE 153
localparam [16:0] AY_BODY_BEG   = 17'd65610;    // 153 bytes
localparam [16:0] AY_END        = 17'd65762;
localparam [16:0] VIA_TAG_BEG   = 17'd65763;    // 4 bytes  "VIA\0"
localparam [16:0] VIA_SIZE_BEG  = 17'd65767;    // 4 bytes  BE 39
localparam [16:0] VIA_BODY_BEG  = 17'd65771;    // 39 bytes
localparam [16:0] VIA_END       = 17'd65809;
localparam [16:0] SNA_BYTES     = 17'd65810;
// Pad up to multiple of 4 bytes so ARM size-in-dwords math is exact.
// Total disk bytes = 8 (header) + 65812 (payload) = 65820, divisible by 4.
// size_in_dwords stored in slot[4..7] satisfies (n+2)*4 = 65820 => n = 16453.
localparam [16:0] PAD_END       = 17'd65811;    // last byte offset within payload (inclusive)
localparam [16:0] PAD_BYTES     = 17'd65812;    // payload bytes incl. 2 trailing zero pad
localparam [31:0] SIZE_IN_DWORDS = 32'd16453;   // (n+2)*4 = 65820 disk bytes

// Slot base byte address (within the DDRAM region declared by SS).
// ss_size in CONF_STR = 0x14000 (80 KiB) per slot. .sna fits comfortably.
wire [27:0] slot_base_bytes = {ss_slot, 26'd0} >> 2;  // unused, see below
// Use explicit per-slot byte base. Slot N at N * 0x14000.
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

// Latched chip state (captured on entry to S_LATCH).
reg [15:0] pc_lat;
reg [7:0]  a_lat, x_lat, y_lat, s_lat, p_lat;
reg [7:0]  orb_lat, ora_lat, ddrb_lat, ddra_lat;
reg [7:0]  t1l_l_lat, t1l_h_lat, t2l_l_lat, t2l_h_lat;
reg [7:0]  sr_lat, acr_lat, pcr_lat, ier_lat, ifr_lat;
reg [15:0] t1c_lat, t2c_lat;
reg        t1_active_lat, t2_active_lat;
reg [119:0] ay_regs_lat;
reg [3:0]  ay_creg_lat;
reg [2:0]  ula_mode_lat;

reg [16:0] save_offset;   // 0..PAD_END
reg [27:0] cur_slot_base; // latched at LATCH time
reg [31:0] cur_counter;   // counter value to write (read at LATCH+1)
reg [3:0]  save_state;

// Per-byte static-value combinational lookup. Bytes that come from RAM
// (DATA body) are not produced here — they come from ram_q.
reg [7:0] static_byte;
wire is_data_body = (save_offset >= DATA_BODY_BEG) && (save_offset <= DATA_END);
wire is_ay_body_reg = (save_offset >= (AY_BODY_BEG + 17'd2)) && (save_offset <= (AY_BODY_BEG + 17'd16));
wire [16:0] ay_reg_off = save_offset - (AY_BODY_BEG + 17'd2); // 0..14
wire [9:0]  ay_bit_off = {ay_reg_off[6:0], 3'd0};             // 0..112

always @(*) begin
	static_byte = 8'h00;
	case (save_offset)
		// ---- OSN ----
		17'd0:  static_byte = "O";
		17'd1:  static_byte = "S";
		17'd2:  static_byte = "N";
		17'd3:  static_byte = 8'h00;
		17'd4:  static_byte = 8'h00; // size BE [31:24]
		17'd5:  static_byte = 8'h00;
		17'd6:  static_byte = 8'h00;
		17'd7:  static_byte = 8'd21;
		// OSN body offset 0..20 at file offset 8..28; byte 16 (=file 24) = ULA mode.
		17'd24: static_byte = {5'd0, ula_mode_lat};
		// ---- DATA header ----
		17'd29: static_byte = "D";
		17'd30: static_byte = "A";
		17'd31: static_byte = "T";
		17'd32: static_byte = "A";
		17'd33: static_byte = 8'h00; // size BE [31:24] = 0x00010000
		17'd34: static_byte = 8'h01;
		17'd35: static_byte = 8'h00;
		17'd36: static_byte = 8'h00;
		// DATA body 37..65572 -> read from RAM (handled below via ram_q)
		// ---- CPU ----
		17'd65573: static_byte = "C";
		17'd65574: static_byte = "P";
		17'd65575: static_byte = "U";
		17'd65576: static_byte = 8'h00;
		17'd65577: static_byte = 8'h00; // size BE
		17'd65578: static_byte = 8'h00;
		17'd65579: static_byte = 8'h00;
		17'd65580: static_byte = 8'd21;
		// CPU body offset 0..20 at file 65581..65601.
		// body offset 4=PC hi, 5=PC lo, 13=A, 14=X, 15=Y, 16=S, 17=P
		17'd65585: static_byte = pc_lat[15:8];
		17'd65586: static_byte = pc_lat[7:0];
		17'd65594: static_byte = a_lat;
		17'd65595: static_byte = x_lat;
		17'd65596: static_byte = y_lat;
		17'd65597: static_byte = s_lat;
		17'd65598: static_byte = p_lat;
		// ---- AY ----
		17'd65602: static_byte = "A";
		17'd65603: static_byte = "Y";
		17'd65604: static_byte = 8'h00;
		17'd65605: static_byte = 8'h00;
		17'd65606: static_byte = 8'h00; // size BE = 153
		17'd65607: static_byte = 8'h00;
		17'd65608: static_byte = 8'h00;
		17'd65609: static_byte = 8'd153;
		// AY body: offset 0 = bmode (0), offset 1 = creg
		17'd65611: static_byte = {4'd0, ay_creg_lat};
		// AY regs at body offset 2..16 (file 65612..65626) handled below
		// ---- VIA ----
		17'd65763: static_byte = "V";
		17'd65764: static_byte = "I";
		17'd65765: static_byte = "A";
		17'd65766: static_byte = 8'h00;
		17'd65767: static_byte = 8'h00;
		17'd65768: static_byte = 8'h00;
		17'd65769: static_byte = 8'h00;
		17'd65770: static_byte = 8'd39;
		// VIA body offset 0=IFR, 2=ORB, 5=ORA, 7=DDRA, 8=DDRB,
		// 9=T1L_L, 10=T1L_H, 11/12=T1C BE, 13=T2L_L, 14=T2L_H,
		// 15/16=T2C BE, 17=SR, 18=ACR, 19=PCR, 20=IER, 30=T1run, 31=T2run.
		17'd65771: static_byte = ifr_lat;
		17'd65773: static_byte = orb_lat;
		17'd65776: static_byte = ora_lat;
		17'd65778: static_byte = ddra_lat;
		17'd65779: static_byte = ddrb_lat;
		17'd65780: static_byte = t1l_l_lat;
		17'd65781: static_byte = t1l_h_lat;
		17'd65782: static_byte = t1c_lat[15:8];
		17'd65783: static_byte = t1c_lat[7:0];
		17'd65784: static_byte = t2l_l_lat;
		17'd65785: static_byte = t2l_h_lat;
		17'd65786: static_byte = t2c_lat[15:8];
		17'd65787: static_byte = t2c_lat[7:0];
		17'd65788: static_byte = sr_lat;
		17'd65789: static_byte = acr_lat;
		17'd65790: static_byte = pcr_lat;
		17'd65791: static_byte = ier_lat;
		17'd65801: static_byte = {7'd0, t1_active_lat};
		17'd65802: static_byte = {7'd0, t2_active_lat};
		default: static_byte = 8'h00;
	endcase
	if (is_ay_body_reg) static_byte = ay_regs_lat[ay_bit_off +: 8];
end

// Pick byte to write: from RAM for DATA body, else from static_byte.
wire [7:0] byte_to_write = is_data_body ? ram_q : static_byte;

// Compute DDRAM byte address for current save_offset.
// Bytes start at slot_base + 8 (payload offset within slot).
wire [27:0] cur_byte_addr = cur_slot_base + 28'd8 + {11'd0, save_offset};
wire [2:0]  byte_lane     = cur_byte_addr[2:0];
wire [27:1] cur_qword_addr = cur_byte_addr[27:1];

// FSM states
localparam S_IDLE      = 4'd0;
localparam S_LATCH     = 4'd1;
localparam S_PREFETCH  = 4'd2; // start RAM read (for next DATA byte)
localparam S_WAIT_RAM  = 4'd3; // wait 1: ram_addr_reg -> Oric.sv spram_addr_reg
localparam S_WAIT_RAM2 = 4'd9; // wait 2: spram_addr_reg -> SPRAM q_reg
localparam S_DDR_REQ   = 4'd4; // present byte + pulse ch1_req
localparam S_DDR_WAIT  = 4'd5; // wait for ch1_ready
localparam S_HDR_REQ   = 4'd6; // emit slot[0..7] (counter+size) as one QWORD
localparam S_HDR_WAIT  = 4'd7;
localparam S_DONE      = 4'd8;

always @(posedge clk_sys) begin
	if (reset) begin
		save_state  <= S_IDLE;
		active      <= 1'b0;
		ch1_req     <= 1'b0;
		ch1_rnw     <= 1'b0;
		cur_counter <= 32'd0;
	end
	else begin
		ch1_req <= 1'b0;

		case (save_state)
			S_IDLE: begin
				if (ss_save) begin
					save_state    <= S_LATCH;
					active        <= 1'b1;
					save_offset   <= 17'd0;
					cur_slot_base <= slot_base(ss_slot);
				end
			end

			S_LATCH: begin
				// One-shot capture of chip state. cpu_regs_in is
				// T65's combinational {PC, S, P, Y, X, A}. S[15:8]
				// is junk for 6502; we keep only the low byte.
				pc_lat <= cpu_regs_in[63:48];
				s_lat  <= cpu_regs_in[39:32];
				p_lat  <= cpu_regs_in[31:24];
				y_lat  <= cpu_regs_in[23:16];
				x_lat  <= cpu_regs_in[15:8];
				a_lat  <= cpu_regs_in[7:0];

				orb_lat      <= via_orb_in;
				ora_lat      <= via_ora_in;
				ddrb_lat     <= via_ddrb_in;
				ddra_lat     <= via_ddra_in;
				t1l_l_lat    <= via_t1l_l_in;
				t1l_h_lat    <= via_t1l_h_in;
				t2l_l_lat    <= via_t2l_l_in;
				t2l_h_lat    <= via_t2l_h_in;
				sr_lat       <= via_sr_in;
				acr_lat      <= via_acr_in;
				pcr_lat      <= via_pcr_in;
				ier_lat      <= via_ier_in;
				ifr_lat      <= via_ifr_in;
				t1c_lat      <= via_t1c_in;
				t2c_lat      <= via_t2c_in;
				t1_active_lat <= via_t1_active_in;
				t2_active_lat <= via_t2_active_in;

				ay_regs_lat <= ay_regs_in;
				ay_creg_lat <= ay_creg_in;

				ula_mode_lat <= ula_mode_in;

				save_state <= S_PREFETCH;
			end

			// Set spram_addr to the RAM address that corresponds to
			// the current save_offset (only meaningful inside DATA body).
			// Non-RAM bytes pass through the same path; ram_q is ignored.
			S_PREFETCH: begin
				if (is_data_body) begin
					// 17-bit subtraction avoids the bit-16 underflow that
					// (save_offset[15:0] - DATA_BODY_BEG[15:0]) would produce
					// when save_offset crosses 0x10000.
					ram_addr <= (save_offset - DATA_BODY_BEG);
				end
				save_state <= S_WAIT_RAM;
			end

			// 2-cycle wait for SPRAM read. ram_addr reg -> spram_addr
			// reg (mux in Oric.sv) takes one cycle; spram_addr -> q reg
			// inside the SPRAM takes another. Without both, ram_q is stale.
			S_WAIT_RAM: begin
				save_state <= S_WAIT_RAM2;
			end
			S_WAIT_RAM2: begin
				save_state <= S_DDR_REQ;
			end

			S_DDR_REQ: begin
				ch1_addr <= cur_qword_addr;
				ch1_din  <= {8{byte_to_write}};
				ch1_be   <= 8'h01 << byte_lane;
				ch1_rnw  <= 1'b0;
				save_state <= S_DDR_WAIT;
			end

			// Hold ch1_req high until we see ch1_ready. ddram lives in
			// CLK_VIDEO so its ready pulse is too narrow (21 ns) for
			// clk_sys (24 MHz, 42 ns) to catch every time. With ch1_req
			// held, ddram re-issues idempotent transactions until clk_sys
			// finally samples ready on an aligned edge.
			S_DDR_WAIT: begin
				ch1_req <= 1'b1;
				if (ch1_ready) begin
					ch1_req <= 1'b0;
					if (save_offset >= PAD_END) begin
						save_state <= S_HDR_REQ;
					end
					else begin
						save_offset <= save_offset + 17'd1;
						save_state  <= S_PREFETCH;
					end
				end
			end

			S_HDR_REQ: begin
				// Counter at slot_base + 0..3; size at slot_base + 4..7.
				// Both in one QWORD-aligned write.
				ch1_addr <= cur_slot_base[27:1];
				ch1_din  <= {SIZE_IN_DWORDS, cur_counter + 32'd1};
				ch1_be   <= 8'hFF;
				ch1_rnw  <= 1'b0;
				save_state <= S_HDR_WAIT;
			end

			S_HDR_WAIT: begin
				ch1_req <= 1'b1;
				if (ch1_ready) begin
					ch1_req <= 1'b0;
					cur_counter <= cur_counter + 32'd1;
					save_state  <= S_DONE;
				end
			end

			S_DONE: begin
				active     <= 1'b0;
				save_state <= S_IDLE;
			end

			default: save_state <= S_IDLE;
		endcase
	end
end

endmodule
