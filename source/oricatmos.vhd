--
-- ORIC ATMOS top level module
--
-- (c) 2012 d18c7db(a)hotmail
--
-- This program is free software; you can redistribute it and/or modify it under
-- the terms of the GNU General Public License version 3 or, at your option,
-- any later version as published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
--
-- For full details, see the GNU General Public License at www.gnu.org/licenses

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.std_logic_arith.all;
   use ieee.std_logic_unsigned.all;

--library unisim;
-- use unisim.vcomponents.all;

entity ORIC is
port (
   clk6                 : in     std_logic;
   clk12                : in     std_logic;
   clk24                : in     std_logic;
   I_RESET              : in    std_logic;

   -- Keyboard
   ps2_key              : in    std_logic_vector(10 downto 0);
   PS2DAT1              : in    std_logic;

   -- Audio out
   PSG_OUT              : out   std_logic_vector(7 downto 0);

   -- VGA out
   O_VIDEO_R           : out   std_logic_vector(3 downto 0);
   O_VIDEO_G           : out   std_logic_vector(3 downto 0);
   O_VIDEO_B           : out   std_logic_vector(3 downto 0);
   O_HSYNC             : out   std_logic;
   O_VSYNC             : out   std_logic;
   O_HBLANK            : out   std_logic;
   O_VBLANK            : out   std_logic;

	mister_status       : in    std_logic_vector (10 downto 0);

   -- HDMI video output
-- TMDS_P      : out   std_logic_vector(3 downto 0);
-- TMDS_N      : out   std_logic_vector(3 downto 0);


   -- K7 connector
   K7_TAPEIN         : in    std_logic;
   K7_TAPEOUT        : out   std_logic

-- K7_REMOTE         : out   std_logic;
-- K7_AUDIOOUT       : out   std_logic;

   -- PRINTER
-- PRT_DATA          : inout std_logic_vector(7 downto 0);
-- PRT_STR           : out   std_logic;  -- strobe
-- PRT_ACK           : in    std_logic;  -- ack

-- MAPn              : in    std_logic;
-- ROMDISn           : in    std_logic;
-- IRQn              : in    std_logic;
   ---
-- CLK_EXT           : out   std_logic;  -- 1 MHZ
-- RW                : out   std_logic;
-- IO                : out   std_logic;
-- IOCONTROL         : in    std_logic;


);
end;

architecture RTL of ORIC is

   -- Resets
   signal loc_reset_n        : std_logic; --active low

   -- Internal clocks

   signal clk_aud            : std_logic := '0';
   signal clkout0            : std_logic := '0';
   signal clkout1            : std_logic := '0';
   signal clkout2            : std_logic := '0';
   signal clkout3            : std_logic := '0';
   signal clkout4            : std_logic := '0';
   signal clkout5            : std_logic := '0';
   signal pll_locked         : std_logic := '0';

   -- cpu
   signal CPU_ADDR           : std_logic_vector(23 downto 0);
   signal CPU_DI             : std_logic_vector( 7 downto 0);
   signal CPU_DO             : std_logic_vector( 7 downto 0);
   signal cpu_rw             : std_logic;
   signal cpu_irq            : std_logic;
   signal ad                 : std_logic_vector(15 downto 0);

   -- VIA
   signal via_pa_out_oe      : std_logic_vector( 7 downto 0);
   signal via_pa_in          : std_logic_vector( 7 downto 0);
   signal via_pa_out         : std_logic_vector( 7 downto 0);
-- signal via_ca2_out        : std_logic;
-- signal via_ca2_oe_l       : std_logic;
-- signal via_cb1_in         : std_logic;
   signal via_cb1_out        : std_logic;
   signal via_cb1_oe_l       : std_logic;
   signal via_cb2_out        : std_logic;
   signal via_cb2_oe_l       : std_logic;
   signal via_in             : std_logic_vector( 7 downto 0);
   signal via_out            : std_logic_vector( 7 downto 0);
   signal via_oe_l           : std_logic_vector( 7 downto 0);
   signal VIA_DO             : std_logic_vector( 7 downto 0);

   -- Keyboard
   signal KEY_ROW            : std_logic_vector( 7 downto 0);

   -- PSG
   signal psg_bdir           : std_logic; -- PSG read/write
-- signal PSG_OUT            : std_logic_vector( 7 downto 0);

   -- ULA
   signal ula_phi2           : std_logic;
   signal ula_CSIOn          : std_logic;
   signal ula_CSIO           : std_logic;
   signal ula_CSROMn         : std_logic;
-- signal ula_CSRAMn         : std_logic;
   signal SRAM_DO            : std_logic_vector( 7 downto 0);
   signal ula_AD_SRAM        : std_logic_vector(15 downto 0);
   signal ula_CE_SRAM        : std_logic;
   signal ula_OE_SRAM        : std_logic;
   signal ula_WE_SRAM        : std_logic;
   signal ula_LE_SRAM        : std_logic;
   signal ula_CLK_4          : std_logic;
   signal ula_IOCONTROL      : std_logic;
   signal ula_VIDEO_R        : std_logic;
   signal ula_VIDEO_G        : std_logic;
   signal ula_VIDEO_B        : std_logic;
   signal ula_SYNC           : std_logic;

   signal ROM_DO             : std_logic_vector( 7 downto 0);

   -- VIDEO
   signal HSync              : std_logic;
   signal VSync              : std_logic;
   signal hs_int             : std_logic;
   signal vs_int             : std_logic;
   signal dummy              : std_logic_vector( 3 downto 0) := (others => '0');
   signal s_cmpblk_n_out     : std_logic;

   signal VideoR             : std_logic_vector(3 downto 0);
   signal VideoG             : std_logic_vector(3 downto 0);
   signal VideoB             : std_logic_vector(3 downto 0);
   signal hblank             : std_logic;
   signal vblank             : std_logic;

   signal red_s              : std_logic;
   signal grn_s              : std_logic;
   signal blu_s              : std_logic;

   signal clk_dvi_p          : std_logic;
   signal clk_dvi_n          : std_logic;
   signal clk_dvi_pixel      : std_logic;
   signal clk_s              : std_logic;
   signal s_blank            : std_logic;
   
   signal break              : std_logic;
   signal cpu_enabled        : std_logic := '1';


component keyboard port (
      clk_24   : in  std_logic;
      clk      : in  std_logic;
      reset : in  std_logic;

      ps2_key  : in std_logic_vector(10 downto 0);
      row   : in std_logic_vector(7 downto 0);

      col      : in std_logic_vector(2 downto 0);
      ROWbit   : out std_logic_vector(7 downto 0);
      swrst    : out std_logic
   );
end component;

begin
   ------------------------------------------------
   

-- CLK_EXT <= ula_phi2;

   -- Reset
   loc_reset_n <= I_RESET;
   
    
   cpu_enabledment_process : process(clk24) begin
		 if rising_edge(clk24) then
				if mister_status(4)='1' then cpu_enabled <= '0'; end if;
				if mister_status(5)='1' then cpu_enabled <= '1'; end if;
			end if;	
		end process;
--------------------------------------------------
   O_VIDEO_R  <= VideoR;
   O_VIDEO_G  <= VideoG;
   O_VIDEO_B  <= VideoB;
   O_HSYNC    <= HSync;
   O_VSYNC    <= VSync;
   O_HBLANK   <= hblank;
   O_VBLANK   <= vblank;

   ------------------------------------------------------------
   -- CPU 6502
   ------------------------------------------------------------
   inst_cpu : entity work.T65
   port map (
      Mode    => "00",
      Res_n   => loc_reset_n,
--    Enable  => '1',
      Enable  => cpu_enabled,
      Clk     => ula_phi2,
      Rdy     => '1',
      Abort_n => '1',
      IRQ_n   => cpu_irq,
      NMI_n   => not break,
      SO_n    => '1',
      R_W_n   => cpu_rw,
      Sync    => open,
      EF      => open,
      MF      => open,
      XF      => open,
      ML_n    => open,
      VP_n    => open,
      VDA     => open,
      VPA     => open,
      A       => CPU_ADDR,
      DI      => CPU_DI,
      DO      => CPU_DO,
      Regs     => open,
      DEBUG    => open
   );

   inst_rom : entity work.rom_oa
   port map (
      clk  => clk24,
      ADDR => CPU_ADDR(13 downto 0),
      DATA => ROM_DO
   );

   ------------------------------------------------------------
   -- STATIC RAM
   ------------------------------------------------------------
   ad(15 downto 0)  <= ula_AD_SRAM when ula_phi2 = '0' else CPU_ADDR(15 downto 0);
-- ad(17 downto 16) <= "00";

   inst_ram : entity work.ram48k
   port map(
      clock  => clk24,
--    cs   => ula_CE_SRAM,
      rden   => ula_OE_SRAM,
      wren   => ula_WE_SRAM,
      address => ad,
      data   => CPU_DO,
      q   => SRAM_DO
   );

   ------------------------------------------------------------
   -- ULA
   ------------------------------------------------------------
   inst_ula : entity work.ULA
   port map (
      RESETn     => loc_reset_n,
      CLK        => clk24,
      CLK_4      => ula_CLK_4,

      RW         => cpu_rw,
      ADDR       => CPU_ADDR(15 downto 0),
--    MAPn       => MAPn,
      MAPn       => '1',
      DB         => SRAM_DO,

      -- DRAM
--    AD_RAM     => open,
--    RASn       => open,
--    CASn       => open,
--    MUX        => open,
--    RW_RAM     => open,

      -- Address decoding
--    CSRAMn     => ula_CSRAMn,
      CSROMn     => ula_CSROMn,
      CSIOn      => ula_CSIOn,

      -- RAM
      SRAM_AD    => ula_AD_SRAM,
      SRAM_OE    => ula_OE_SRAM,
      SRAM_CE    => ula_CE_SRAM,
      SRAM_WE    => ula_WE_SRAM,
      LATCH_SRAM => ula_LE_SRAM,

      -- CPU Clock
      PHI2       => ula_PHI2,

      -- Video
      R          => ULA_VIDEO_R,
      G          => ULA_VIDEO_G,
      B          => ULA_VIDEO_B,
      SYNC       => ULA_SYNC,
      HSYNC      => hs_int,
      VSYNC      => vs_int
   );

-- VIDEO_SYNC  <= ULA_SYNC;

   -----------------------------------------------------------------
   -- video scan converter required to display video on VGA hardware
   -----------------------------------------------------------------
   -- total resolution 354x312, active resolution 240x224, H 15625 Hz, V 50.08 Hz
   -- take note: the values below are relative to the CLK period not standard VGA clock period
   inst_scan_conv : entity work.VGA_SCANCONV
   generic map (
      -- mark active area of input video
      cstart      =>  65,  -- composite sync start
      clength     => 240,  -- composite sync length

      -- output video timing
      hA          =>  10,  -- h front porch
      hB          =>  46,  -- h sync
      hC          =>  24,  -- h back porch
      hD          => 240,  -- visible video

--    vA          =>  34,  -- v front porch (not used)
      vB          =>   2,  -- v sync
      vC          =>  20,  -- v back porch
      vD          => 224,  -- visible video

      hpad        =>  32,  -- H black border
      vpad        =>  32   -- V black border
   )
   port map (
      I_VIDEO(15 downto 12) => "0000",

      -- only 3 bit color
      I_VIDEO(11)           => ULA_VIDEO_R,
      I_VIDEO(10)           => ULA_VIDEO_R,
      I_VIDEO(9)            => ULA_VIDEO_R,
      I_VIDEO(8)            => ULA_VIDEO_R,

      I_VIDEO(7)            => ULA_VIDEO_G,
      I_VIDEO(6)            => ULA_VIDEO_G,
      I_VIDEO(5)            => ULA_VIDEO_G,
      I_VIDEO(4)            => ULA_VIDEO_G,

      I_VIDEO(3)            => ULA_VIDEO_B,
      I_VIDEO(2)            => ULA_VIDEO_B,
      I_VIDEO(1)            => ULA_VIDEO_B,
      I_VIDEO(0)            => ULA_VIDEO_B,
      I_HSYNC               => hs_int,
      I_VSYNC               => vs_int,

      -- for VGA output, feed these signals to VGA monitor
      O_VIDEO(15 downto 12)=> dummy,
      O_VIDEO(11 downto 8) => VideoR,
      O_VIDEO( 7 downto 4) => VideoG,
      O_VIDEO( 3 downto 0) => VideoB,
      O_HSYNC              => HSync,
      O_VSYNC              => VSync,
      O_HBLANK             => hblank,
      O_VBLANK             => vblank,

      --
      CLK                   => clk6,
      CLK_x2                => clk12
   );


   ------------------------------------------------------------
   -- VIA
   ------------------------------------------------------------
   ula_CSIO <= not ula_CSIOn;

   inst_via : entity work.M6522
   port map (
      I_RS          => CPU_ADDR(3 downto 0),
      I_DATA        => CPU_DO(7 downto 0),
      O_DATA        => VIA_DO,
      O_DATA_OE_L   => open,

      I_RW_L        => cpu_rw,
      I_CS1         => ula_CSIO,
      I_CS2_L       => ula_IOCONTROL,

      O_IRQ_L       => cpu_irq,   -- note, not open drain

      -- PORT A
      I_CA1         => '1',       -- PRT_ACK
      I_CA2         => '1',       -- psg_bdir
      O_CA2         => psg_bdir,  -- via_ca2_out
      O_CA2_OE_L    => open,

      I_PA          => via_pa_in,
      O_PA          => via_pa_out,
      O_PA_OE_L     => via_pa_out_oe,

      -- PORT B
      I_CB1         => K7_TAPEIN,
--    I_CB1         => '0',
      O_CB1         => via_cb1_out,
      O_CB1_OE_L    => via_cb1_oe_l,

      I_CB2         => '1',
      O_CB2         => via_cb2_out,
      O_CB2_OE_L    => via_cb2_oe_l,

      I_PB          => via_in,
      O_PB          => via_out,
      O_PB_OE_L     => via_oe_l,

      --
      RESET_L       => loc_reset_n,
      I_P2_H        => ula_phi2,
      ENA_4         => '1',
      CLK           => ula_CLK_4
   );

   ------------------------------------------------------------
   -- KEYBOARD
   ------------------------------------------------------------
   inst_key : keyboard
   port map(
      clk_24   => clk24,
      clk      => ula_phi2,
      reset => not loc_reset_n, -- active high reset

      ps2_key  => ps2_key,
      row   => via_pa_out,

      col      => via_out(2 downto 0),
      ROWbit   => KEY_ROW,
      swrst    => break
   );

   -- Keyboard
   via_in <= x"F7" when (KEY_ROW or via_pa_out) = x"FF" else x"FF";

   ------------------------------------------------------------
   -- PSG AY-3-8192
   ------------------------------------------------------------
   inst_psg : entity work.YM2149
   port map (
      I_DA       => via_pa_out,
      O_DA       => via_pa_in,
      O_DA_OE_L  => open,
      -- control
      I_A9_L     => '0',
      I_A8       => '1',
      I_BDIR     => via_cb2_out,
      I_BC2      => '1',
      I_BC1      => psg_bdir,
      I_SEL_L    => '1',

      O_AUDIO    => PSG_OUT,
      -- port a
--    I_IOA      => x"00",
--    O_IOA      => open,
--    O_IOA_OE_L => open,
      -- port b
--    I_IOB      => x"00",
--    O_IOB      => open,
--    O_IOB_OE_L => open,

      RESET_L    => loc_reset_n,
      ENA        => '1',
      CLK        => ula_PHI2
   );

   ------------------------------------------------------------
   -- Sigma Delta DAC
   ------------------------------------------------------------
-- inst_dac : entity work.DAC
-- port map (
--    clk_i  => clk24,
--    resetn => loc_reset_n,
--    dac_i  => PSG_OUT,
--    dac_o  => AUDIO_OUT
-- );

   ------------------------------------------------------------
   -- Multiplex CPU , RAM/VIA , ROM
   ------------------------------------------------------------
   ula_IOCONTROL <= '0';

   process
   begin
      wait until rising_edge(clk24);

      -- expansion port
      if    cpu_rw = '1' and ula_IOCONTROL = '1' and ula_CSIOn  = '0'  then CPU_DI <= SRAM_DO;
      -- Via
      elsif cpu_rw = '1' and ula_IOCONTROL = '0' and ula_CSIOn  = '0' and ula_LE_SRAM = '0' then CPU_DI <= VIA_DO;
      -- ROM
      elsif cpu_rw = '1' and ula_IOCONTROL = '0' and ula_CSROMn = '0'                       then CPU_DI <= ROM_DO;
      -- Read data
      elsif cpu_rw = '1' and ula_IOCONTROL = '0' and ula_phi2   = '1' and ula_LE_SRAM = '0' then cpu_di <= SRAM_DO;
      end if;
   end process;

   ------------------------------------------------------------
   -- K7 PORT
   ------------------------------------------------------------
   K7_TAPEOUT  <= via_out(7);
-- K7_REMOTE   <= via_out(6);
-- K7_AUDIOOUT <= AUDIO_OUT;

   ------------------------------------------------------------
   -- PRINTER PORT
   ------------------------------------------------------------
-- PRT_DATA    <= via_pa_out;
-- PRT_STR     <= via_out(4);
end RTL;
