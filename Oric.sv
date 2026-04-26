//============================================================================
//  Oric-1 and Oric Atmos
//  Copyright (C) rampa
//
//  Port to MiSTer by Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0; 
 
assign LED_USER    = ioctl_download | fdd_busy | tape_adc_act;
assign LED_DISK    = led_disk;
assign LED_POWER   = 0;
assign BUTTONS     = 0; 
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 0;
assign AUDIO_MIX = 0;

wire [1:0] ar = status[122:121];
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[16:15])
);

`include "build_id.v"
localparam CONF_STR = {
	"Oric;;",
	"F1,TAP,Load TAP file;",
	"F3,TAP,Load TAP via DMA;",
	"F4,SNA,Load Snapshot;",
	"h0T[53],Rewind Tape;",
	"-;",
	"T[60],Halt CPU;",
	"T[61],Resume CPU;",
	"-;",
	"S0,DSK,Mount Drive A:;",
	"S1,DSK,Mount Drive B:;",
	"S2,DSK,Mount Drive C:;",
	"S3,DSK,Mount Drive D:;",
	"H2O[17],Drive A Write Protect,Off,On;",
	"h2-,Drive A is Write Protected;",
	"H3O[18],Drive B Write Protect,Off,On;",
	"h3-,Drive B is Write Protected;",
	"H4O[19],Drive C Write Protect,Off,On;",
	"h4-,Drive C is Write Protected;",
	"H5O[20],Drive D Write Protect,Off,On;",
	"h5-,Drive D is Write Protected;",
	"-;",
	"P1,Settings;",
	"P1O[6:5],FDD Controller,Auto,Off,On;",
	"P1FC2,ROM,Load Alternative Bios;",
	"P1-;",
	"P1O[51:50],Tape Audio,Mute,Low,High;",
	"P1O[52],Tape Input,File,ADC;",
	"P1-;",
	"P1O[55:54],Joystick Adapter,None,PASE,IJK;",
	"P1-;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[12:10],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"P1O[16:15],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O[9:8],Audio,Stereo,ABC (West Europe),ACB (East Europe);",
	"H1O[4:3],ROM,Oric Atmos,Oric 1;",
	"h1O[4:3],ROM,Oric Atmos,Oric 1,Loadable Bios;",
	
	"-;",
	"R0,Reset & Apply;",
	"J,Fire;",
	"V,v",`BUILD_DATE
};

wire [1:0] tapeVolume  = status[51:50];
wire       tapeUseADC = status[52];
wire       tapeRewind = status[53];
wire [1:0] joystick_adapter = status[55:54];

reg cpu_halt = 0;
reg halt_btn_d, resume_btn_d;
always @(posedge clk_sys) begin
	halt_btn_d   <= status[60];
	resume_btn_d <= status[61];
	if (reset) cpu_halt <= 0;
	else begin
		if (status[60] ^ halt_btn_d)   cpu_halt <= 1;
		if (status[61] ^ resume_btn_d) cpu_halt <= 0;
	end
end

///////////////////////////////////////////////////

wire locked;
wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(CLK_VIDEO),
	.locked(locked)
);

reg        reset = 0;
reg [16:0] clr_addr = 0;
always @(posedge clk_sys) begin

	if(~&clr_addr) clr_addr <= clr_addr + 1'd1;
	else reset <= 0;

	if(RESET | status[0] | buttons[1]) begin
		clr_addr <= 0;
		reset <= 1;
	end
	
end

wire tape_clk;
always @(posedge clk_sys) begin
	if (reset)
    	tape_clk <= 1'b0;
	else
    	tape_clk <= ~tape_clk;	
end

///////////////////////////////////////////////////

wire  [10:0] ps2_key;

wire  [15:0] joystick_0;
wire  [15:0] joystick_1;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire [127:0] status;
wire         freeze_sync;

wire  [31:0] sd_lba[4];
wire   [3:0] sd_rd;
wire   [3:0] sd_wr;
wire   [3:0] sd_ack;
wire   [8:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[4];
wire         sd_buff_wr;

wire   [3:0] img_mounted;
wire  [31:0] img_size;
wire         img_readonly;

wire         ioctl_wr;
wire  [24:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_download;
wire   [7:0] ioctl_index;

wire         status_set;
wire  [31:0] status_out;

wire  [21:0] gamma_bus;
wire  [15:0] status_mask = {10'd0, img_wp, bios_loaded, tape_loaded & ~tapeUseADC & ~cas_relay};

hps_io #(.CONF_STR(CONF_STR), .VDNUM(4)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.ps2_key(ps2_key),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.status(status),
	.status_menumask(status_mask),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly),

	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),

	.gamma_bus(gamma_bus)
);


///////////////////////////////////////////////////

reg    [3:0] img_mountedD;
reg    [3:0] img_wp;

always @(posedge clk_sys)
begin
	img_mountedD <= img_mounted;
	if(~|img_mountedD && |img_mounted) begin
		if(img_mounted[0]) img_wp[0] <= img_readonly & |img_size;
		else if(img_mounted[1]) img_wp[1] <= img_readonly & |img_size;
		else if(img_mounted[2]) img_wp[2] <= img_readonly & |img_size;
		else if(img_mounted[3]) img_wp[3] <= img_readonly & |img_size;
	end
end
///////////////////////////////////////////////////

wire key_strobe = old_keystb ^ ps2_key[10];
reg old_keystb = 0;
always @(posedge clk_sys) old_keystb <= ps2_key[10];


wire  [11:0] psg_a;
wire  [11:0] psg_b;
wire  [11:0] psg_c;
wire  [13:0] psg_out;

wire  [1:0] stereo = status [9:8];

wire        r, g, b; 
wire        hs, vs, HBlank, VBlank;
wire        clk_pix;
wire        tape_in, tape_out;

wire [15:0] ram_ad;
wire [15:0] spram_addr;
wire  [7:0] ram_d;
wire  [7:0] spram_d;
wire        ram_we;
wire        spram_we;
reg   [7:0] ram_q;

always @(posedge clk_sys) begin
	if(reset) begin
		spram_d <= 1;
		spram_addr <= clr_addr[15:0];
		spram_we <= 1'b1;
	end
	else if (dma_active) begin
		spram_d <= dma_data;
		spram_addr <= dma_addr;
		spram_we <= dma_we;
	end
	else if (snap_active) begin
		spram_d <= snap_ram_data;
		spram_addr <= snap_ram_addr;
		spram_we <= snap_ram_we;
	end
	else begin
		spram_d <= ram_d;
		spram_addr <= ram_ad;
		spram_we <= ram_we;
	end
end

spram #(.address_width(16)) ram (
  .clock(clk_sys),

  .address(spram_addr),
  .data(spram_d),
  .wren(spram_we),
  .q(ram_q)
);

wire        led_disk;
reg         fdd_busy;

oricatmos oricatmos
(
	.clk_in           (clk_sys),
	.RESET            (reset),
	.key_pressed      (ps2_key[9]),
	.key_code         (ps2_key[7:0]),
	.key_extended     (ps2_key[8]),
	.key_strobe       (key_strobe),
	.PSG_OUT_A        (psg_a),
	.PSG_OUT_B        (psg_b),
	.PSG_OUT_C        (psg_c),
	.PSG_OUT          (psg_out),
	.VIDEO_CLK			(clk_pix),
	.VIDEO_R				(r),
	.VIDEO_G				(g),
	.VIDEO_B				(b),
	.VIDEO_HSYNC		(hs),
	.VIDEO_VSYNC		(vs),
	.VIDEO_HBLANK		(HBlank),
	.VIDEO_VBLANK		(VBlank),
	.K7_TAPEIN			(tape_in),
	.K7_TAPEOUT			(tape_out),
	.K7_REMOTE			(cas_relay),
	.ram_ad           (ram_ad),
	.ram_d            (ram_d),
	.ram_q            (ram_q),
	.ram_oe           (),
	.ram_we           (ram_we),
	.joystick_adapter (joystick_adapter),
	.joystick_0       (joystick_0),
	.joystick_1       (joystick_1),
	.fd_led           (led_disk),
	.fdd_ready        (fdd_ready),
	.fdd_busy         (fdd_busy),
	.fdd_reset        (0),
	.fdd_layout       (0),
	.phi2             (),
	.pll_locked       (locked),
	.disk_enable      ((!status[6:5]) ? ~fdd_ready : status[5]),
	.rom              ({rom[1] & bios_loaded, rom[0]}),
	.bios_addr        (bios_addr),
	.bios_din         (bios_din),

	.img_mounted      (img_mounted),
	.img_size         (img_size),

	.img_wp           (status[20:17] | img_wp),
	.sd_lba_fd0       (sd_lba[0]),
	.sd_lba_fd1       (sd_lba[1]),
	.sd_lba_fd2       (sd_lba[2]),
	.sd_lba_fd3       (sd_lba[3]),
	.sd_rd            (sd_rd),
	.sd_wr            (sd_wr),
	.sd_ack           (sd_ack),
	.sd_buff_addr     (sd_buff_addr),
	.sd_dout          (sd_buff_dout),
	.sd_din_fd0       (sd_buff_din[0]),
	.sd_din_fd1       (sd_buff_din[1]),
	.sd_din_fd2       (sd_buff_din[2]),
	.sd_din_fd3       (sd_buff_din[3]),
	.sd_dout_strobe   (sd_buff_wr),
	.sd_din_strobe    (0),
	.cpu_halt         (cpu_halt | dma_active | snap_active),
	.cpu_regs_set     (cpu_regs_set),
	.cpu_regs_set_we  (cpu_regs_set_we),
	.via_snap_we      (via_snap_we),
	.via_snap_addr    (via_snap_addr),
	.via_snap_data    (via_snap_data),
	.ay_snap_we       (ay_snap_we),
	.ay_snap_addr     (ay_snap_addr),
	.ay_snap_data     (ay_snap_data),
	.ay_snap_creg_we  (ay_snap_creg_we),
	.ay_snap_creg     (ay_snap_creg)
);



reg [1:0] rom = 0;
always @(posedge clk_sys) if(reset) rom <= status[4:3];

reg fdd_ready = 0;
always @(posedge clk_sys) if(img_mounted) fdd_ready <= |img_size;

///////////////////////////////////////////////////

reg clk_pix2;
always @(posedge clk_sys) clk_pix2 <= clk_pix;

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	reg old_clk;
	
	old_clk <= clk_pix2;
	ce_pix <= ~old_clk & clk_pix2;
end

reg HSync, VSync;
always @(posedge CLK_VIDEO) begin
	if(ce_pix) begin
		HSync <= ~hs;
		if(~HSync & ~hs) VSync <= ~vs;
	end
end

wire [2:0] scale = status[12:10];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
wire       scandoubler = scale || forced_scandoubler;

assign VGA_F1 = 0;
assign VGA_SL = sl[1:0];

video_mixer #(.LINE_LENGTH(250), .HALF_DEPTH(1), .GAMMA(1)) video_mixer
(
	.*,
	.R({4{r}}),
	.G({4{g}}),
	.B({4{b}}),
	.hq2x(scale==1)
);

///////////////////////////////////////////////////
wire        load_alt_bios = ioctl_index==2;
reg         bios_loaded = 1'b0;

wire [15:0] bios_addr;
wire [7:0]  bios_din;

spram #(.address_width(14)) altbios (
  .clock(clk_sys),

  .address((load_alt_bios && ioctl_download) ? ioctl_addr: bios_addr),
  .data(ioctl_dout),
  .wren(ioctl_wr && load_alt_bios),
  .q(bios_din)
);

///////////////////////////////////////////////////

wire [10:0] tapeAudio;
assign tapeAudio = {|tapeVolume ? (tapeVolume == 2'd1 ? {1'b0,tape_in} : {tape_in,1'b0} ) : 2'b00,9'b00};

wire [15:0] psg_ab = {2'b0,psg_a+psg_b+tapeAudio,1'b0};
wire [15:0] psg_ac = {2'b0,psg_a+psg_c+tapeAudio,1'b0};
wire [15:0] psg_bc = {2'b0,psg_b+psg_c+tapeAudio,1'b0};

assign AUDIO_L = (stereo == 2'b00) ? {1'b0,psg_out+tapeAudio,1'b0} : (stereo == 2'b01) ? psg_ab: psg_ac;
assign AUDIO_R = (stereo == 2'b00) ? {1'b0,psg_out+tapeAudio,1'b0} : (stereo == 2'b01) ? psg_bc: psg_bc;



wire casdout;
wire cas_relay;

wire        load_tape     = ioctl_index==1;
wire        load_tape_dma = ioctl_index==3;
wire        load_sna      = ioctl_index==4;
wire        any_tape_load = load_tape | load_tape_dma;
reg  [15:0] tape_end;
reg         tape_loaded = 1'b0;
reg         ioctl_downlD;

wire [15:0] tape_addr;
wire [7:0]  tape_data;

reg  [15:0] dma_cache_addr;
reg         dma_active;
reg  [15:0] dma_addr;
reg  [7:0]  dma_data;
reg         dma_we;

spram #(.address_width(16)) tapecache (
  .clock(clk_sys),

  .address((ioctl_download && any_tape_load) ? ioctl_addr :
           dma_active                        ? dma_cache_addr :
                                               tape_addr),
  .data(ioctl_dout),
  .wren(ioctl_wr && any_tape_load),
  .q(tape_data)
);


always @(posedge clk_sys) begin
 if (any_tape_load) tape_end <= ioctl_addr[15:0];
end

always @(posedge clk_sys) begin
	ioctl_downlD <= ioctl_download;
	if(ioctl_downlD && ~ioctl_download && load_tape) tape_loaded <= 1'b1;
	if(ioctl_downlD && ~ioctl_download && load_alt_bios) bios_loaded <= 1'b1;
end

cassette cassette (
  .clk(clk_sys),
  .reset(reset),
  .rewind(tapeRewind | (any_tape_load && ioctl_download)),
  .en(cas_relay && tape_loaded && ~tapeUseADC),
  .tape_addr(tape_addr),
  .tape_data(tape_data),

  .tape_end(tape_end),
  .data(casdout)
);

// ---- DMA TAP loader ----
// Triggered on falling edge of ioctl_download with ioctl_index==3.
// Parses TAP header in the tapecache (sync 0x16 + marker 0x24, then 9-byte
// header: type@+2, end@+4/+5 big-endian, start@+6/+7 big-endian, +8 sep,
// then null-terminated filename), then copies the program data into main
// RAM via the spram mux. Patches VARTAB/ARYTAB/STREND so LIST/RUN/edit
// behave like a real load, and writes a status line at $BB80 with the
// program name, type and start address.

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
wire        dma_trigger    = ioctl_downlD && ~ioctl_download && load_tape_dma;

function automatic [7:0] hex_digit(input [3:0] n);
	hex_digit = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
endfunction

always @(posedge clk_sys) begin
	if (reset) begin
		dma_state      <= D_IDLE;
		dma_active     <= 1'b0;
		dma_we         <= 1'b0;
		dma_eos        <= 1'b0;
		dma_name_done  <= 1'b0;
	end
	else begin
		dma_we <= 1'b0;
		case (dma_state)
			D_IDLE: begin
				if (dma_trigger) begin
					dma_state      <= D_INIT;
					dma_active     <= 1'b1;
					dma_cache_addr <= 16'd0;
					dma_bot_seg    <= 16'd0;
					dma_eos        <= 1'b0;
					dma_name_done  <= 1'b0;
					dma_name_pos   <= 4'd0;
					dma_first_seg  <= 1'b1;
					dma_seg_count  <= 4'd1;
				end
			end

			// Prime the read pipeline: cache_rd_addr will be 1 next cycle so
			// tape_data corresponds to mem[0] when D_SCAN starts running.
			D_INIT: begin
				dma_cache_addr <= dma_cache_addr + 16'd1;
				dma_state      <= D_SCAN;
			end

			// Scan for sync marker, then capture header fields by offset.
			// tape_data at this cycle = mem[dma_cache_addr - 1].
			D_SCAN: begin
				dma_cache_addr <= dma_cache_addr + 16'd1;
				if (dma_cache_addr > tape_end) begin
					dma_patch_step <= 3'd0;
					dma_state      <= D_PATCH;
				end
				else if (!dma_eos) begin
					if (tape_data == 8'h24) begin
						dma_eos     <= 1'b1;
						dma_bot_seg <= dma_cache_addr; // first byte after 0x24
					end
				end
				else begin
					if (dma_cache_addr - 16'd1 == dma_bot_seg + 16'd2) dma_prog_type        <= tape_data;
					if (dma_cache_addr - 16'd1 == dma_bot_seg + 16'd4) dma_data_end[15:8]   <= tape_data;
					if (dma_cache_addr - 16'd1 == dma_bot_seg + 16'd5) dma_data_end[7:0]    <= tape_data;
					if (dma_cache_addr - 16'd1 == dma_bot_seg + 16'd6) dma_data_start[15:8] <= tape_data;
					if (dma_cache_addr - 16'd1 == dma_bot_seg + 16'd7) dma_data_start[7:0]  <= tape_data;
					if (dma_cache_addr - 16'd1 >= dma_bot_seg + 16'd9 && !dma_name_done) begin
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
				dma_cache_addr <= dma_cache_addr + 16'd1;
				dma_we         <= 1'b1;
				dma_addr       <= dma_write_addr;
				dma_data       <= tape_data;
				dma_write_addr <= dma_write_addr + 16'd1;
				if (dma_write_addr == dma_data_end || dma_cache_addr > tape_end) begin
					dma_state <= D_NEXT;
				end
			end

			// End of one segment. If more bytes remain in the tape image,
			// reset segment-local state and re-enter D_SCAN to parse the
			// next header. Acts as the read-pipeline prime cycle (mirrors
			// D_INIT) so D_SCAN sees mem[dma_cache_addr - 1] as expected.
			D_NEXT: begin
				dma_cache_addr <= dma_cache_addr + 16'd1;
				if (dma_cache_addr > tape_end) begin
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
				dma_we <= 1'b1;
				case (dma_patch_step)
					3'd0: begin dma_addr <= 16'h009C; dma_data <= dma_end_plus_1[7:0];  end
					3'd1: begin dma_addr <= 16'h009D; dma_data <= dma_end_plus_1[15:8]; end
					3'd2: begin dma_addr <= 16'h009E; dma_data <= dma_end_plus_1[7:0];  end
					3'd3: begin dma_addr <= 16'h009F; dma_data <= dma_end_plus_1[15:8]; end
					3'd4: begin dma_addr <= 16'h00A0; dma_data <= dma_end_plus_1[7:0];  end
					3'd5: begin dma_addr <= 16'h00A1; dma_data <= dma_end_plus_1[15:8]; end
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
				dma_we   <= 1'b1;
				dma_addr <= 16'hBB80 + {10'd0, dma_status_idx};
				case (dma_status_idx)
					6'd0:  dma_data <= 8'h07;
					6'd1:  dma_data <= "D";
					6'd2:  dma_data <= "M";
					6'd3:  dma_data <= "A";
					6'd4:  dma_data <= " ";
					6'd5,  6'd6,  6'd7,  6'd8,  6'd9,  6'd10,
					6'd11, 6'd12, 6'd13, 6'd14, 6'd15, 6'd16:
						dma_data <= ((dma_status_idx - 6'd5) < {2'd0, dma_name_pos})
						            ? dma_name_buf[dma_status_idx - 6'd5]
						            : 8'h20;
					6'd17: dma_data <= " ";
					6'd18: dma_data <= "T";
					6'd19: dma_data <= ":";
					6'd20: dma_data <= (dma_disp_type == 8'h00) ? "B"
					                 : (dma_disp_type == 8'h80) ? "M" : "?";
					6'd21: dma_data <= " ";
					6'd22: dma_data <= "@";
					6'd23: dma_data <= "$";
					6'd24: dma_data <= hex_digit(dma_disp_start[15:12]);
					6'd25: dma_data <= hex_digit(dma_disp_start[11:8]);
					6'd26: dma_data <= hex_digit(dma_disp_start[7:4]);
					6'd27: dma_data <= hex_digit(dma_disp_start[3:0]);
					6'd29: dma_data <= "x";
					6'd30: dma_data <= hex_digit(dma_seg_count);
					default: dma_data <= " ";
				endcase
				if (dma_status_idx == 6'd39) begin
					dma_drain_cnt <= 2'd0;
					dma_state     <= D_DRAIN;
				end
				else dma_status_idx <= dma_status_idx + 6'd1;
			end

			// Hold dma_active for a few cycles so the last write commits
			// through the spram_addr mux + spram register pipeline before
			// the CPU comes off halt.
			D_DRAIN: begin
				dma_drain_cnt <= dma_drain_cnt + 2'd1;
				if (dma_drain_cnt == 2'd3) dma_state <= D_DONE;
			end

			D_DONE: begin
				dma_active <= 1'b0;
				dma_state  <= D_IDLE;
			end

			default: dma_state <= D_IDLE;
		endcase
	end
end

// ---- Snapshot LOAD (.sna) ----
// Triggered on falling edge of ioctl_download with ioctl_index==4. Buffers
// the file in a 128 KiB snapcache, then walks the Oricutron block container
// (per docs/sna_support.md): OSN+DATA gives main RAM (lower 64 KiB), CPU
// gives 6502 register file. v1 ignores AY, VIA, TAP, PCH, SYR — those are
// either deferred to v2 or not relevant to LOAD.

reg  [16:0] snap_cache_addr;
wire [7:0]  snap_cache_q;

spram #(.address_width(17)) snapcache (
  .clock(clk_sys),
  .address((ioctl_download && load_sna) ? ioctl_addr[16:0] : snap_cache_addr),
  .data(ioctl_dout),
  .wren(ioctl_wr && load_sna),
  .q(snap_cache_q)
);

reg  [16:0] snap_end;
always @(posedge clk_sys) if (load_sna && ioctl_download) snap_end <= ioctl_addr[16:0];

wire snap_trigger = ioctl_downlD && ~ioctl_download && load_sna;

localparam S_IDLE         = 4'd0,
           S_INIT         = 4'd1,
           S_HDR_TAG      = 4'd2,
           S_HDR_SIZE     = 4'd3,
           S_BLK_DATA_RAM = 4'd4,
           S_BLK_CPU      = 4'd5,
           S_BLK_AY       = 4'd6,
           S_BLK_VIA      = 4'd7,
           S_SKIP         = 4'd8,
           S_APPLY_VIA    = 4'd9,
           S_APPLY_AY     = 4'd10,
           S_APPLY_CPU    = 4'd11,
           S_DRAIN        = 4'd12,
           S_DONE         = 4'd13,
           S_DEBUG_PAINT  = 4'd14;

reg  [3:0]  snap_state;
reg         snap_active;
reg  [1:0]  hdr_byte_cnt;
reg  [31:0] blk_tag;
reg  [31:0] blk_size;
reg  [31:0] prev_tag;
reg  [16:0] blk_offset;

reg  [15:0] snap_pc;
reg  [7:0]  snap_a, snap_x, snap_y, snap_s, snap_p;

reg  [15:0] snap_ram_addr;
reg  [7:0]  snap_ram_data;
reg         snap_ram_we;

reg  [63:0] cpu_regs_set;
reg         cpu_regs_set_we;

// AY register file (15 regs) + currently-selected register
reg  [7:0]  snap_ay_regs [0:14];
reg  [3:0]  snap_ay_creg;
reg         ay_snap_we;
reg  [3:0]  ay_snap_addr;
reg  [7:0]  ay_snap_data;
reg         ay_snap_creg_we;

// VIA register file (12 we restore — see Oric.sv comment in S_BLK_VIA)
reg  [7:0]  snap_via_regs [0:11];
reg         via_snap_we;
reg  [3:0]  via_snap_addr;
reg  [7:0]  via_snap_data;

reg  [3:0]  snap_apply_cnt;
reg  [9:0]  snap_drain_cnt;

`ifdef SNAP_DEBUG
reg  [5:0]  snap_paint_idx;
function automatic [7:0] snap_hex_digit(input [3:0] n);
    snap_hex_digit = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
endfunction
`endif

// Use explicit hex literals — Verilog string-escape semantics don't
// handle "\x00" the way SystemVerilog does, so building tag constants
// from string literals containing NUL was matching nothing.
localparam [31:0] TAG_OSN  = 32'h4F534E00; // "OSN\0"
localparam [31:0] TAG_DATA = 32'h44415441; // "DATA"
localparam [31:0] TAG_CPU  = 32'h43505500; // "CPU\0"
localparam [31:0] TAG_AY   = 32'h41590000; // "AY\0\0"
localparam [31:0] TAG_VIA  = 32'h56494100; // "VIA\0"

always @(posedge clk_sys) begin
	if (reset) begin
		snap_state      <= S_IDLE;
		snap_active     <= 1'b0;
		snap_ram_we     <= 1'b0;
		cpu_regs_set_we <= 1'b0;
		via_snap_we     <= 1'b0;
		ay_snap_we      <= 1'b0;
		ay_snap_creg_we <= 1'b0;
	end
	else begin
		snap_ram_we     <= 1'b0;
		cpu_regs_set_we <= 1'b0;
		via_snap_we     <= 1'b0;
		ay_snap_we      <= 1'b0;
		ay_snap_creg_we <= 1'b0;

		case (snap_state)
			S_IDLE: begin
				if (snap_trigger) begin
					snap_active     <= 1'b1;
					snap_cache_addr <= 17'd0;
					hdr_byte_cnt    <= 2'd0;
					blk_offset      <= 17'd0;
					prev_tag        <= 32'd0;
					// Defaults if a CPU block isn't found
					snap_pc <= 16'h0000;
					snap_a  <= 8'h00;
					snap_x  <= 8'h00;
					snap_y  <= 8'h00;
					snap_s  <= 8'hFF;
					snap_p  <= 8'h24; // I=1, undefined-bit-5=1, others 0
					snap_state <= S_INIT;
				end
			end

			// Prime snapcache read pipeline so snap_cache_q corresponds
			// to mem[0] when S_HDR_TAG starts. Same shape as DMA loader's D_INIT.
			S_INIT: begin
				snap_cache_addr <= 17'd1;
				snap_state      <= S_HDR_TAG;
			end

			// Read 4 tag bytes. End-of-file detected when we'd read past snap_end.
			S_HDR_TAG: begin
				if ({1'b0, snap_cache_addr} > {1'b0, snap_end} + 1'b1) begin
`ifdef SNAP_DEBUG
					snap_paint_idx <= 6'd0;
					snap_state     <= S_DEBUG_PAINT;
`else
					snap_apply_cnt <= 4'd0;
					snap_state     <= S_APPLY_VIA;
`endif
				end
				else begin
					case (hdr_byte_cnt)
						2'd0: blk_tag[31:24] <= snap_cache_q;
						2'd1: blk_tag[23:16] <= snap_cache_q;
						2'd2: blk_tag[15:8]  <= snap_cache_q;
						2'd3: blk_tag[7:0]   <= snap_cache_q;
					endcase
					snap_cache_addr <= snap_cache_addr + 17'd1;
					if (hdr_byte_cnt == 2'd3) begin
						hdr_byte_cnt <= 2'd0;
						snap_state   <= S_HDR_SIZE;
					end
					else hdr_byte_cnt <= hdr_byte_cnt + 2'd1;
				end
			end

			// Read 4 size bytes (BE), then dispatch on blk_tag.
			S_HDR_SIZE: begin
				case (hdr_byte_cnt)
					2'd0: blk_size[31:24] <= snap_cache_q;
					2'd1: blk_size[23:16] <= snap_cache_q;
					2'd2: blk_size[15:8]  <= snap_cache_q;
					2'd3: blk_size[7:0]   <= snap_cache_q;
				endcase
				snap_cache_addr <= snap_cache_addr + 17'd1;
				if (hdr_byte_cnt == 2'd3) begin
					hdr_byte_cnt <= 2'd0;
					blk_offset   <= 17'd0;
					case (blk_tag)
						TAG_CPU:  snap_state <= S_BLK_CPU;
						TAG_AY:   snap_state <= S_BLK_AY;
						TAG_VIA:  snap_state <= S_BLK_VIA;
						TAG_DATA: snap_state <= (prev_tag == TAG_OSN) ? S_BLK_DATA_RAM : S_SKIP;
						default:  snap_state <= S_SKIP;
					endcase
					if (blk_tag != TAG_DATA) prev_tag <= blk_tag;
				end
				else hdr_byte_cnt <= hdr_byte_cnt + 2'd1;
			end

			// DATA payload following OSN: stream first 64 KiB into main RAM.
			S_BLK_DATA_RAM: begin
				if (blk_offset < 17'h10000) begin
					snap_ram_addr <= blk_offset[15:0];
					snap_ram_data <= snap_cache_q;
					snap_ram_we   <= 1'b1;
				end
				snap_cache_addr <= snap_cache_addr + 17'd1;
				blk_offset      <= blk_offset + 17'd1;
				if (blk_offset == blk_size[16:0] - 17'd1) begin
					blk_offset   <= 17'd0;
					hdr_byte_cnt <= 2'd0;
					snap_state   <= S_HDR_TAG;
				end
			end

			// CPU block: capture only the fields we use (PC at 4-5, A/X/Y/S/P at 13-17).
			S_BLK_CPU: begin
				case (blk_offset[7:0])
					8'd4:  snap_pc[15:8] <= snap_cache_q;
					8'd5:  snap_pc[7:0]  <= snap_cache_q;
					8'd13: snap_a <= snap_cache_q;
					8'd14: snap_x <= snap_cache_q;
					8'd15: snap_y <= snap_cache_q;
					8'd16: snap_s <= snap_cache_q;
					8'd17: snap_p <= snap_cache_q;
					default: ;
				endcase
				snap_cache_addr <= snap_cache_addr + 17'd1;
				blk_offset      <= blk_offset + 17'd1;
				if (blk_offset == blk_size[16:0] - 17'd1) begin
					blk_offset   <= 17'd0;
					hdr_byte_cnt <= 2'd0;
					snap_state   <= S_HDR_TAG;
				end
			end

			// AY block: capture creg (offset 1) + 15-byte register file (2..16).
			// Other Oricutron AY fields (keystates, derived counters etc.) skipped
			// for v2 — register file is enough to make audio resume.
			S_BLK_AY: begin
				case (blk_offset[7:0])
					8'd1:  snap_ay_creg     <= snap_cache_q[3:0];
					8'd2:  snap_ay_regs[0]  <= snap_cache_q;
					8'd3:  snap_ay_regs[1]  <= snap_cache_q;
					8'd4:  snap_ay_regs[2]  <= snap_cache_q;
					8'd5:  snap_ay_regs[3]  <= snap_cache_q;
					8'd6:  snap_ay_regs[4]  <= snap_cache_q;
					8'd7:  snap_ay_regs[5]  <= snap_cache_q;
					8'd8:  snap_ay_regs[6]  <= snap_cache_q;
					8'd9:  snap_ay_regs[7]  <= snap_cache_q;
					8'd10: snap_ay_regs[8]  <= snap_cache_q;
					8'd11: snap_ay_regs[9]  <= snap_cache_q;
					8'd12: snap_ay_regs[10] <= snap_cache_q;
					8'd13: snap_ay_regs[11] <= snap_cache_q;
					8'd14: snap_ay_regs[12] <= snap_cache_q;
					8'd15: snap_ay_regs[13] <= snap_cache_q;
					8'd16: snap_ay_regs[14] <= snap_cache_q;
					default: ;
				endcase
				snap_cache_addr <= snap_cache_addr + 17'd1;
				blk_offset      <= blk_offset + 17'd1;
				if (blk_offset == blk_size[16:0] - 17'd1) begin
					blk_offset   <= 17'd0;
					hdr_byte_cnt <= 2'd0;
					snap_state   <= S_HDR_TAG;
				end
			end

			// VIA block: capture the 12 registers we restore. Skipped fields:
			// IFR (computed from source IRQ flags, can't be set directly),
			// IRB/IRBL/IRA/IRAL (input shadows), T1C/T2C (counters not in v2
			// scope), various derived bits (CA/CB line states, irqbit, etc.).
			S_BLK_VIA: begin
				case (blk_offset[7:0])
					8'd2:  snap_via_regs[0]  <= snap_cache_q; // ORB
					8'd5:  snap_via_regs[1]  <= snap_cache_q; // ORA
					8'd7:  snap_via_regs[2]  <= snap_cache_q; // DDRA
					8'd8:  snap_via_regs[3]  <= snap_cache_q; // DDRB
					8'd9:  snap_via_regs[4]  <= snap_cache_q; // T1L_L
					8'd10: snap_via_regs[5]  <= snap_cache_q; // T1L_H
					8'd13: snap_via_regs[6]  <= snap_cache_q; // T2L_L
					8'd14: snap_via_regs[7]  <= snap_cache_q; // T2L_H
					8'd17: snap_via_regs[8]  <= snap_cache_q; // SR
					8'd18: snap_via_regs[9]  <= snap_cache_q; // ACR
					8'd19: snap_via_regs[10] <= snap_cache_q; // PCR
					8'd20: snap_via_regs[11] <= snap_cache_q; // IER
					default: ;
				endcase
				snap_cache_addr <= snap_cache_addr + 17'd1;
				blk_offset      <= blk_offset + 17'd1;
				if (blk_offset == blk_size[16:0] - 17'd1) begin
					blk_offset   <= 17'd0;
					hdr_byte_cnt <= 2'd0;
					snap_state   <= S_HDR_TAG;
				end
			end

			// Unknown / not-yet-handled block: advance past the payload.
			S_SKIP: begin
				snap_cache_addr <= snap_cache_addr + 17'd1;
				blk_offset      <= blk_offset + 17'd1;
				if (blk_offset == blk_size[16:0] - 17'd1) begin
					blk_offset   <= 17'd0;
					hdr_byte_cnt <= 2'd0;
					snap_state   <= S_HDR_TAG;
				end
			end

`ifdef SNAP_DEBUG
			// Debug-only: paint captured CPU regs to row 10 of the text
			// screen so we can verify the snapshot decode survived even
			// if the CPU misbehaves on resume. Compile in via the
			// SNAP_DEBUG Verilog macro (`oric-build --snap-debug`).
			S_DEBUG_PAINT: begin
				snap_ram_we   <= 1'b1;
				// Row 10: $BB80 + 10*40 = $BD10
				snap_ram_addr <= 16'hBD10 + {10'd0, snap_paint_idx};
				case (snap_paint_idx)
					6'd0:  snap_ram_data <= 8'h07;
					6'd1:  snap_ram_data <= "S";
					6'd2:  snap_ram_data <= "N";
					6'd3:  snap_ram_data <= "A";
					6'd4:  snap_ram_data <= "P";
					6'd5:  snap_ram_data <= " ";
					6'd6:  snap_ram_data <= "P";
					6'd7:  snap_ram_data <= "C";
					6'd8:  snap_ram_data <= "=";
					6'd9:  snap_ram_data <= "$";
					6'd10: snap_ram_data <= snap_hex_digit(snap_pc[15:12]);
					6'd11: snap_ram_data <= snap_hex_digit(snap_pc[11:8]);
					6'd12: snap_ram_data <= snap_hex_digit(snap_pc[7:4]);
					6'd13: snap_ram_data <= snap_hex_digit(snap_pc[3:0]);
					6'd14: snap_ram_data <= " ";
					6'd15: snap_ram_data <= "A";
					6'd16: snap_ram_data <= "=";
					6'd17: snap_ram_data <= "$";
					6'd18: snap_ram_data <= snap_hex_digit(snap_a[7:4]);
					6'd19: snap_ram_data <= snap_hex_digit(snap_a[3:0]);
					6'd20: snap_ram_data <= " ";
					6'd21: snap_ram_data <= "X";
					6'd22: snap_ram_data <= "=";
					6'd23: snap_ram_data <= "$";
					6'd24: snap_ram_data <= snap_hex_digit(snap_x[7:4]);
					6'd25: snap_ram_data <= snap_hex_digit(snap_x[3:0]);
					6'd26: snap_ram_data <= " ";
					6'd27: snap_ram_data <= "Y";
					6'd28: snap_ram_data <= "=";
					6'd29: snap_ram_data <= "$";
					6'd30: snap_ram_data <= snap_hex_digit(snap_y[7:4]);
					6'd31: snap_ram_data <= snap_hex_digit(snap_y[3:0]);
					6'd32: snap_ram_data <= " ";
					6'd33: snap_ram_data <= "S";
					6'd34: snap_ram_data <= "=";
					6'd35: snap_ram_data <= "$";
					6'd36: snap_ram_data <= snap_hex_digit(snap_s[7:4]);
					6'd37: snap_ram_data <= snap_hex_digit(snap_s[3:0]);
					default: snap_ram_data <= " ";
				endcase
				if (snap_paint_idx == 6'd39) begin
					snap_apply_cnt <= 4'd0;
					snap_state     <= S_APPLY_VIA;
				end
				else snap_paint_idx <= snap_paint_idx + 6'd1;
			end
`endif

			// Walk through 12 captured VIA registers and pulse via_snap_we for
			// each — the chip's snap branch writes the register file directly,
			// bypassing the chip-select / phi2 protocol. snap_apply_cnt selects.
			S_APPLY_VIA: begin
				via_snap_we <= 1'b1;
				case (snap_apply_cnt)
					4'd0:  begin via_snap_addr <= 4'h0; via_snap_data <= snap_via_regs[0];  end // ORB
					4'd1:  begin via_snap_addr <= 4'h1; via_snap_data <= snap_via_regs[1];  end // ORA
					4'd2:  begin via_snap_addr <= 4'h3; via_snap_data <= snap_via_regs[2];  end // DDRA
					4'd3:  begin via_snap_addr <= 4'h2; via_snap_data <= snap_via_regs[3];  end // DDRB
					4'd4:  begin via_snap_addr <= 4'h4; via_snap_data <= snap_via_regs[4];  end // T1L_L
					4'd5:  begin via_snap_addr <= 4'h5; via_snap_data <= snap_via_regs[5];  end // T1L_H
					4'd6:  begin via_snap_addr <= 4'h8; via_snap_data <= snap_via_regs[6];  end // T2L_L
					4'd7:  begin via_snap_addr <= 4'h9; via_snap_data <= snap_via_regs[7];  end // T2L_H
					4'd8:  begin via_snap_addr <= 4'hA; via_snap_data <= snap_via_regs[8];  end // SR
					4'd9:  begin via_snap_addr <= 4'hB; via_snap_data <= snap_via_regs[9];  end // ACR
					4'd10: begin via_snap_addr <= 4'hC; via_snap_data <= snap_via_regs[10]; end // PCR
					4'd11: begin via_snap_addr <= 4'hE; via_snap_data <= snap_via_regs[11]; end // IER
					default: via_snap_we <= 1'b0;
				endcase
				snap_apply_cnt <= snap_apply_cnt + 4'd1;
				if (snap_apply_cnt == 4'd11) begin
					snap_apply_cnt <= 4'd0;
					snap_state     <= S_APPLY_AY;
				end
			end

			// Walk through 15 captured AY registers, then write the captured
			// current-register-select. Each pulse is one clk_sys cycle.
			S_APPLY_AY: begin
				if (snap_apply_cnt < 4'd15) begin
					ay_snap_we   <= 1'b1;
					ay_snap_addr <= snap_apply_cnt;
					ay_snap_data <= snap_ay_regs[snap_apply_cnt];
				end
				else begin
					ay_snap_creg_we <= 1'b1;
					ay_snap_creg    <= snap_ay_creg;
				end
				snap_apply_cnt <= snap_apply_cnt + 4'd1;
				if (snap_apply_cnt == 4'd15) begin
					snap_apply_cnt <= 4'd0;
					snap_state     <= S_APPLY_CPU;
				end
			end

			// Drive Regs_set + we to T65 for a handful of cycles so the
			// register-load process latches cleanly.
			S_APPLY_CPU: begin
				cpu_regs_set    <= {snap_pc, 8'h00, snap_s, snap_p, snap_y, snap_x, snap_a};
				cpu_regs_set_we <= 1'b1;
				snap_apply_cnt  <= snap_apply_cnt + 4'd1;
				if (snap_apply_cnt == 4'd15) begin
					snap_drain_cnt <= 10'd0;
					snap_state     <= S_DRAIN;
				end
			end

			// Hold snap_active long enough to span at least one full phi2
			// cycle (24 clk_sys cycles per phi2 half) so cpu_di settles to
			// mem[loaded_PC] before we let T65 fetch its first opcode.
			S_DRAIN: begin
				snap_drain_cnt <= snap_drain_cnt + 10'd1;
				if (snap_drain_cnt == 10'd1023) snap_state <= S_DONE;
			end

			S_DONE: begin
				snap_active <= 1'b0;
				snap_state  <= S_IDLE;
			end

			default: snap_state <= S_IDLE;
		endcase
	end
end

///////////////////////////////////////////////////
wire tape_adc, tape_adc_act;
ltc2308_tape ltc2308_tape
(
	.clk(CLK_50M),
	.ADC_BUS(ADC_BUS),
	.dout(tape_adc),
	.active(tape_adc_act)
);

assign tape_in = tapeUseADC ? tape_adc : casdout;

endmodule
