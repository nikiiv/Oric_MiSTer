//
// ddram.sv — single-channel DDRAM read/write for save-state I/O.
// Adapted from NES_MiSTer/rtl/ddram.sv (Sorgelig). DDRAM region fixed
// at 0x30000000 (matches the SS conf_str declaration in Oric.sv).
//
// Protocol: client pulses ch1_req for one cycle after setting
// ch1_addr / ch1_din / ch1_be / ch1_rnw. Module pulses ch1_ready when
// the transaction completes (writes: same cycle the request is
// accepted; reads: when DDRAM_DOUT_READY).
//

module ddram
(
	input         DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input  [27:1] ch1_addr,
	output [63:0] ch1_dout,
	input  [63:0] ch1_din,
	input         ch1_req,
	input         ch1_rnw,
	input  [7:0]  ch1_be,
	output        ch1_ready
);

reg  [7:0] ram_burst;
reg [63:0] ram_q[1:1];
reg [63:0] ram_data;
reg [27:1] ram_address;
reg        ram_read = 0;
reg        ram_write = 0;
reg  [7:0] ram_be;

reg  [1:1] ready;

assign DDRAM_BURSTCNT = ram_burst;
assign DDRAM_BE       = ram_read ? 8'hFF : ram_be;
assign DDRAM_ADDR     = {4'b0011, ram_address[27:3]}; // base = 0x30000000
assign DDRAM_RD       = ram_read;
assign DDRAM_DIN      = ram_data;
assign DDRAM_WE       = ram_write;

assign ch1_dout  = ram_q[1];
assign ch1_ready = ready[1];

reg        state  = 0;
reg  [0:0] ch = 0;
reg  [1:1] ch_rq;

always @(posedge DDRAM_CLK) begin

	ch_rq <= ch_rq | {ch1_req};
	ready <= 0;

	if(!DDRAM_BUSY) begin
		ram_write <= 0;
		ram_read  <= 0;

		case(state)
			0: if(ch_rq[1] || ch1_req) begin
					ch_rq[1]         <= 0;
					ch               <= 1;
					ram_data         <= ch1_din;
					ram_be           <= ch1_be;
					ram_address      <= ch1_addr;
					ram_burst        <= 1;
					if(~ch1_rnw) begin
						ram_write     <= 1;
						ready[1]      <= 1;
					end
					else begin
						ram_read      <= 1;
						state         <= 1;
					end
				end

			1: if(DDRAM_DOUT_READY) begin
					ram_q[ch]        <= DDRAM_DOUT;
					ready[ch]        <= 1;
					state            <= 0;
				end

		endcase
	end
end

endmodule
