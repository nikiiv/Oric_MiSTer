//============================================================================
// ORIC TAP format loader
//============================================================================


/*

ORIC tap file format

	Synchronization bytes - each $16 - minimum of 3, usually 3 in TAP files
	
	Post sync
	byte cnt
	00		1			$16											sync
	01		1			$16											sync		
	02		1			$16											sync		
	03		1			$24 											end of sync
	04		1			$00											unused
	05		1			$00											unused	
	06		1			$00/$80										program type - $00 basic, $80 - asm
	07		1			$00/$c7/$80 								autorun ($00 - off, $c7 - bas on, $80 asm on)
	08		2			$XXXX											End address (high/low) ex $3c,$00 which is $3c00
	0A		2			$XXXX											Start address (high/low) ex $05,$01 which is $0501 (typically basic)
	0c		1			$xx											Unused
	0D		1..15						File name (max 15 characters) - zero terminated. Can be zero length.. go figure
	-		-				-			Data
	$BB80 - first byte of the statys line.. Nice to print something there

*/




module tap_loader
(
	input          clk_sys,

	
	
	input          ioctl_download,
	input   [24:0] ioctl_addr,
	input    [7:0] ioctl_data,
	input          ioctl_wr,
	output         ioctl_wait,
	
	input          ram_ready,



	output  [15:0] addr,
	output   [7:0] dout,
	output         wr,

   output         reset,
   output         hwset,
   output   [4:0] hw,
   input    [4:0] hw_ack,
	output			cpu_enabled
  
);






assign dout = tap_data;
assign wr = tap_wr;
assign reset = tap_reset;
assign hwset = tap_hwset;
assign hw = tap_hw;
assign ioctl_wait = tap_wait;

assign cpu_enabled = tap_cpu_enabled;

reg			tap_cpu_enabled = 1;

reg 			tap_REG_program_type = 0; 
reg			tap_REG_autorun = 0;
reg [15:0]	tap_REG_end_address;
reg [15:0]	tap_REG_start_address;	
reg         tap_REGSet;

reg [1:0]    tap_REG; //cumulative of the above 0 - program type (0-basic, 1-asm), 1 - autorun (0-off, 1 -on)


wire [15:0] tap_addr;
reg   [7:0] tap_data;

reg   [4:0] tap_hw;
reg         tap_hwset;
reg         tap_wr;
reg         tap_reset;
reg			tap_wait = 0;

reg			has_data = 0;

reg [24:0] addr_pre;


	//if we have data lets write it
always_ff @(posedge ram_ready) begin
	if (has_data && ioctl_wait) begin
		addr <= tap_addr;
		dout <= tap_data;
		tap_wr <= 1;
		has_data <= 0;
		ioctl_wait <= 0;
	end
end	
	
always_ff @(posedge clk_sys) begin

	reg       old_download;
	reg [1:0] 	hold = 0;
	reg [1:0] 	in_sync = 0; // 0 - before sync, 1 - in sync, 2 - out of sync
	reg [2:0] 	wait_for_header = 2'd2; // 2 - first unused byte, 1- second unused byte, 0 - ready
	reg [15:0]	address_for_header;
	reg [15:0]  header_byte;
	reg 			flag_name_download = 0;
	reg			flag_actual_data_download = 0;
	reg [15:0]  screen_char_address = 16'hBB80;
	

	tap_wr <= 0;
	old_download <= ioctl_download;

	
	//prepare to download the data
	if(~old_download && ioctl_download) begin
		//tap_hdrlen <= 30;
		tap_reset <= 1;
		tap_hw <= 0;
		in_sync <= 0;
		tap_cpu_enabled <= 0;
	end
	
	//finish tap loading
	if(old_download && ~ioctl_download) begin
		tap_cpu_enabled <= 1;
		if(tap_hw) begin
			//tap_REGSet <= 1; //this is a signal that the header has been set
			tap_hwset <= 1;
			hold <= '1;
		end
		else tap_reset <= 0; // unsupported tap loaded - just exit from reset. (NIKI: Do I need this one here?)
	end
	
	//wait for confirmation from HPS
	if(tap_hwset && (tap_hw == hw_ack)) begin
		tap_hwset <= 0;
		tap_reset <= 0;
	end

	//hold tap_REGSet for several clocks after reset
	if(~tap_reset) begin
		if(hold) hold <= hold - 1'd1;
		else tap_REGSet <= 0;
	end
	
	//this is where we do the actual stuff
	if((ioctl_download & ioctl_wr) && ~ioctl_wait) begin
		if (ioctl_addr == 'h0 && ioctl_data == 'h16 ) begin
			in_sync <= 1;
		end
		
		if (in_sync == 1 && ioctl_data == 8'h24) begin
			//end of sync
			address_for_header <= ioctl_addr+3;
		end
		
		if (ioctl_addr >= address_for_header) begin
			header_byte = ioctl_addr[15:0] - address_for_header;
			case (header_byte[2:0])
				0: if (~ioctl_data) tap_REG_program_type <= '1; // program type
				1: if (~ioctl_data) tap_REG_autorun <= '1; // program type
				2: tap_REG_end_address[15:8] <= ioctl_data; // end address high
				3: tap_REG_end_address[7:0] <= ioctl_data; // end address low
				4: tap_REG_start_address[15:8] <= ioctl_data; // start address high
				5: tap_REG_start_address[7:0] <= ioctl_data; //start address low
				6: flag_name_download <= '1;
			endcase
		end
		
		if (~flag_actual_data_download && flag_name_download) begin
			if (~ioctl_data) begin
				//put to ram screen_char_address - ioct_data
				tap_data = ioctl_data;
				has_data <= 1;
				ioctl_wait <= 1;
				tap_addr <= screen_char_address;
				screen_char_address <= screen_char_address + 'h1;
			end
			else begin
				flag_actual_data_download <= 1;
				tap_addr = tap_REG_start_address-1;
			end	
		end
		
		while (tap_addr < tap_REG_end_address && flag_actual_data_download) begin
				tap_addr <= tap_addr + 'h1;
				tap_data = ioctl_data;
				has_data <= 1;
				ioctl_wait <= 1;
			end
	end
end
	
endmodule