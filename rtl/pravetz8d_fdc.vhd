library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity PRAVETZ8D_FDC_CTRL is
	port (
		clk_sys : in std_logic;
		reset : in std_logic;
		phi2 : in std_logic;
		A : in std_logic_vector(15 downto 0);
		DI : in std_logic_vector(7 downto 0);
		DO : out std_logic_vector(7 downto 0);
		fdc_select : out std_logic;

		img_mounted : in std_logic_vector(3 downto 0);
		img_wp : in std_logic_vector(3 downto 0);
		img_size : in std_logic_vector(31 downto 0);

		sd_lba_fd0 : out std_logic_vector(31 downto 0);
		sd_lba_fd1 : out std_logic_vector(31 downto 0);
		sd_rd : out std_logic_vector(1 downto 0);
		sd_wr : out std_logic_vector(1 downto 0);
		sd_ack : in std_logic_vector(1 downto 0);
		sd_buff_addr : in std_logic_vector(8 downto 0);
		sd_dout : in std_logic_vector(7 downto 0);
		sd_din_fd0 : out std_logic_vector(7 downto 0);
		sd_din_fd1 : out std_logic_vector(7 downto 0);
		sd_dout_strobe : in std_logic;

		fdd_busy : out std_logic;
		fd_led : out std_logic
	);
end PRAVETZ8D_FDC_CTRL;

architecture rtl of PRAVETZ8D_FDC_CTRL is
	component floppy_track
		port (
			clk : in std_logic;
			reset : in std_logic;

			sd_lba : out std_logic_vector(31 downto 0);
			sd_rd : out std_logic;
			sd_wr : out std_logic;
			sd_ack : in std_logic;

			sd_buff_addr : in std_logic_vector(8 downto 0);
			sd_buff_dout : in std_logic_vector(7 downto 0);
			sd_buff_din : out std_logic_vector(7 downto 0);
			sd_buff_wr : in std_logic;

			change : in std_logic;
			mount : in std_logic;
			track : in std_logic_vector(5 downto 0);
			ready : out std_logic;
			active : in std_logic;

			ram_addr : in std_logic_vector(12 downto 0);
			ram_do : out std_logic_vector(7 downto 0);
			ram_di : in std_logic_vector(7 downto 0);
			ram_we : in std_logic;
			busy : out std_logic
		);
	end component;

	signal clk_2m : std_logic := '0';
	signal clk_2m_div : unsigned(2 downto 0) := (others => '0');

	signal device_select : std_logic;
	signal disk_addr : unsigned(15 downto 0);
	signal disk_do : unsigned(7 downto 0);
	signal disk_ready : std_logic_vector(1 downto 0);
	signal d1_active : std_logic;
	signal d2_active : std_logic;

	signal track1 : unsigned(5 downto 0);
	signal track1_addr : unsigned(12 downto 0);
	signal track1_di : unsigned(7 downto 0);
	signal track1_do : std_logic_vector(7 downto 0);
	signal track1_we : std_logic;
	signal track1_busy : std_logic;

	signal track2 : unsigned(5 downto 0);
	signal track2_addr : unsigned(12 downto 0);
	signal track2_di : unsigned(7 downto 0);
	signal track2_do : std_logic_vector(7 downto 0);
	signal track2_we : std_logic;
	signal track2_busy : std_logic;

	signal disk_change : std_logic_vector(1 downto 0) := (others => '0');
	signal disk_mount : std_logic_vector(1 downto 0) := (others => '0');
	signal img_mounted_d : std_logic_vector(1 downto 0) := (others => '0');
begin
	device_select <= '1' when phi2 = '1' and A(15 downto 4) = X"031" else '0';
	fdc_select <= device_select;
	disk_addr <= unsigned(X"C08" & A(3 downto 0));
	DO <= std_logic_vector(disk_do);

	process (clk_sys)
	begin
		if rising_edge(clk_sys) then
			if reset = '1' then
				clk_2m <= '0';
				clk_2m_div <= (others => '0');
			elsif clk_2m_div = 5 then
				clk_2m_div <= (others => '0');
				clk_2m <= not clk_2m;
			else
				clk_2m_div <= clk_2m_div + 1;
			end if;
		end if;
	end process;

	process (clk_sys)
	begin
		if rising_edge(clk_sys) then
			if reset = '1' then
				disk_change <= (others => '0');
				disk_mount <= (others => '0');
				img_mounted_d <= (others => '0');
			else
				img_mounted_d <= img_mounted(1 downto 0);
				for i in 0 to 1 loop
					if img_mounted(i) = '1' and img_mounted_d(i) = '0' then
						if img_size /= X"00000000" then
							disk_mount(i) <= '1';
						else
							disk_mount(i) <= '0';
						end if;
						disk_change(i) <= not disk_change(i);
					end if;
				end loop;
			end if;
		end if;
	end process;

	disk : entity work.disk_ii
		port map (
			CLK_14M => clk_sys,
			CLK_2M => clk_2m,
			PHASE_ZERO => phi2,
			IO_SELECT => '0',
			DEVICE_SELECT => device_select,
			RESET => reset,
			DISK_READY => disk_ready,
			A => disk_addr,
			D_IN => unsigned(DI),
			D_OUT => disk_do,
			D1_ACTIVE => d1_active,
			D2_ACTIVE => d2_active,
			D1_WP => img_wp(0),
			D2_WP => img_wp(1),
			TRACK1 => track1,
			TRACK1_ADDR => track1_addr,
			TRACK1_DI => track1_di,
			TRACK1_DO => unsigned(track1_do),
			TRACK1_WE => track1_we,
			TRACK1_BUSY => track1_busy,
			TRACK2 => track2,
			TRACK2_ADDR => track2_addr,
			TRACK2_DI => track2_di,
			TRACK2_DO => unsigned(track2_do),
			TRACK2_WE => track2_we,
			TRACK2_BUSY => track2_busy
		);

	track_a : floppy_track
		port map (
			clk => clk_sys,
			reset => reset,
			sd_lba => sd_lba_fd0,
			sd_rd => sd_rd(0),
			sd_wr => sd_wr(0),
			sd_ack => sd_ack(0),
			sd_buff_addr => sd_buff_addr,
			sd_buff_dout => sd_dout,
			sd_buff_din => sd_din_fd0,
			sd_buff_wr => sd_dout_strobe,
			change => disk_change(0),
			mount => disk_mount(0),
			track => std_logic_vector(track1),
			ready => disk_ready(0),
			active => d1_active,
			ram_addr => std_logic_vector(track1_addr),
			ram_do => track1_do,
			ram_di => std_logic_vector(track1_di),
			ram_we => track1_we,
			busy => track1_busy
		);

	track_b : floppy_track
		port map (
			clk => clk_sys,
			reset => reset,
			sd_lba => sd_lba_fd1,
			sd_rd => sd_rd(1),
			sd_wr => sd_wr(1),
			sd_ack => sd_ack(1),
			sd_buff_addr => sd_buff_addr,
			sd_buff_dout => sd_dout,
			sd_buff_din => sd_din_fd1,
			sd_buff_wr => sd_dout_strobe,
			change => disk_change(1),
			mount => disk_mount(1),
			track => std_logic_vector(track2),
			ready => disk_ready(1),
			active => d2_active,
			ram_addr => std_logic_vector(track2_addr),
			ram_do => track2_do,
			ram_di => std_logic_vector(track2_di),
			ram_we => track2_we,
			busy => track2_busy
		);

	fdd_busy <= track1_busy or track2_busy;
	fd_led <= d1_active or d2_active or track1_busy or track2_busy;
end rtl;
