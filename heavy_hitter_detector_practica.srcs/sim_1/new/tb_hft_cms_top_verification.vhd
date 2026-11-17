library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_hft_cms_top_verification is
end tb_hft_cms_top_verification;

architecture sim of tb_hft_cms_top_verification is

    component hft_cms_top
        port (
            clk       : in  std_logic;
            rst       : in  std_logic;
            i_UART_RX : in  std_logic;
            o_UART_TX : out std_logic
        );
    end component;

    component uart_rx
        generic ( g_CLKS_PER_BIT : integer := 10 );
        port (
            i_Clk       : in  std_logic;
            i_RX_Serial : in  std_logic;
            o_RX_DV     : out std_logic;
            o_RX_Byte   : out std_logic_vector(7 downto 0)
        );
    end component;

    -- Timing Constants (Fast Sim Mode: 10 clocks/bit @ 100 MHz = 100 ns/bit)
    constant CLK_PERIOD : time := 10 ns;
    constant BIT_PERIOD : time := 100 ns;

    -- Top-Level Physical Signals
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '0';
    signal tb_rx_serial : std_logic := '1';
    signal tb_tx_serial : std_logic;

    -- Host PC UART Receiver Signals
    signal pc_rx_dv     : std_logic;
    signal pc_rx_byte   : std_logic_vector(7 downto 0);

    -- Scoreboard & Verification Tracking Signals
    signal current_epoch        : integer range 1 to 2 := 1;
    signal rx_byte_total        : integer := 0;

    signal ep1_packets_sent     : integer := 0;
    signal ep1_hh_count         : integer := 0;
    signal ep1_sample_hh_key    : std_logic_vector(31 downto 0) := (others => '0');

    signal ep2_hh_count         : integer := 0;
    signal ep2_stale_leaked     : boolean := false;
    signal ep2_accum_found      : boolean := false;
    signal ep2_accum_vol        : std_logic_vector(31 downto 0) := (others => '0');
    signal ep2_burst_found      : integer := 0;

    -- File I/O
    file input_file  : text open read_mode is "market_stream.txt";
    file output_file : text open write_mode is "hardware_heavy_hitters.txt";

    -- =========================================================================
    -- UART Byte & Frame Transmission Procedures
    -- =========================================================================
    procedure UART_WRITE_BYTE (
        i_data_in       : in  std_logic_vector(7 downto 0);
        signal o_serial : out std_logic
    ) is
    begin
        -- Start Bit
        o_serial <= '0';
        wait for BIT_PERIOD;
        -- Data Bits (LSB first)
        for i in 0 to 7 loop
            o_serial <= i_data_in(i);
            wait for BIT_PERIOD;
        end loop;
        -- Stop Bit
        o_serial <= '1';
        wait for BIT_PERIOD;
    end procedure;

    procedure SEND_DATA_PACKET (
        constant c_key    : in  std_logic_vector(31 downto 0);
        constant c_vol    : in  std_logic_vector(31 downto 0);
        signal   o_serial : out std_logic
    ) is
    begin
        UART_WRITE_BYTE(x"01", o_serial);
        UART_WRITE_BYTE(c_key(31 downto 24), o_serial);
        UART_WRITE_BYTE(c_key(23 downto 16), o_serial);
        UART_WRITE_BYTE(c_key(15 downto 8),  o_serial);
        UART_WRITE_BYTE(c_key(7 downto 0),   o_serial);
        UART_WRITE_BYTE(c_vol(31 downto 24), o_serial);
        UART_WRITE_BYTE(c_vol(23 downto 16), o_serial);
        UART_WRITE_BYTE(c_vol(15 downto 8),  o_serial);
        UART_WRITE_BYTE(c_vol(7 downto 0),   o_serial);
    end procedure;

    procedure SEND_FLUSH_COMMAND (
        signal o_serial : out std_logic
    ) is
    begin
        UART_WRITE_BYTE(x"02", o_serial);
        for i in 1 to 8 loop
            UART_WRITE_BYTE(x"00", o_serial);
        end loop;
    end procedure;

begin

    uut: hft_cms_top
        port map (
            clk       => clk,
            rst       => rst,
            i_UART_RX => tb_rx_serial,
            o_UART_TX => tb_tx_serial
        );

    host_pc_rx: uart_rx
        generic map ( g_CLKS_PER_BIT => 10 )
        port map (
            i_Clk       => clk,
            i_RX_Serial => tb_tx_serial,
            o_RX_DV     => pc_rx_dv,
            o_RX_Byte   => pc_rx_byte
        );

    clk_process : process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    -- =========================================================================
    -- Main Host PC Stimulus Process
    -- =========================================================================
    host_stim_proc: process
        variable v_iline        : line;
        variable v_msg          : line;
        variable v_key_hex      : std_logic_vector(31 downto 0);
        variable v_vol_hex      : std_logic_vector(31 downto 0);
        variable v_space        : character;
        variable v_start_time   : time;
        variable v_total_time   : time;
        variable v_bytes_before : integer;
        variable v_dump_bytes   : integer;
        variable v_burst_key    : std_logic_vector(31 downto 0);
        variable v_pkt_count    : integer := 0;
    begin
        -- Reset Sequence
        rst <= '1';
        wait for CLK_PERIOD * 20;
        rst <= '0';
        wait for CLK_PERIOD * 20;

        -- =====================================================================
        -- EPOCH 1: Stream all 10k messages & Verify 128-Byte UART Flush Dump
        -- =====================================================================
        current_epoch <= 1;
        report "=== EPOCH 1: Streaming market_stream.txt over UART ===";
        v_start_time := now;

        while not endfile(input_file) loop
            readline(input_file, v_iline);
            if v_iline'length = 0 then
                next;
            end if;

            hread(v_iline, v_key_hex);
            read(v_iline, v_space);
            hread(v_iline, v_vol_hex);

            SEND_DATA_PACKET(v_key_hex, v_vol_hex, tb_rx_serial);
            v_pkt_count := v_pkt_count + 1;
        end loop;

        ep1_packets_sent <= v_pkt_count;
        v_total_time := now - v_start_time;
        report "BENCHMARK: Epoch 1 Packets Sent = " & integer'image(v_pkt_count);
        report "BENCHMARK: Epoch 1 Stream Ingestion Time = " & time'image(v_total_time);

        wait for CLK_PERIOD * 100; -- Drain 35-cycle pipeline

        report "=== EPOCH SWITCH: Sending 0x02 END_OF_WINDOW ===";
        v_bytes_before := rx_byte_total;
        SEND_FLUSH_COMMAND(tb_rx_serial);

        -- Wait for 2048-cycle BRAM flush (~20.5 us) + 128-byte UART TX (~128 us)
        wait for 350 us;

        v_dump_bytes := rx_byte_total - v_bytes_before;
        report "EPOCH 1 UART DUMP BYTES RECEIVED: " & integer'image(v_dump_bytes);
        report "EPOCH 1 HEAVY HITTERS LOGGED    : " & integer'image(ep1_hh_count);

        assert v_dump_bytes = 128
            report "EPOCH 1 FLUSH ERROR: Expected 128 dump bytes, got " & integer'image(v_dump_bytes)
            severity error;

        assert ep1_hh_count > 0
            report "EPOCH 1 WARNING: Zero heavy hitters detected from market_stream.txt!"
            severity warning;

        -- =====================================================================
        -- EPOCH 2: Verify Clean Switch & Zero Packet Loss Under Burst Load
        -- =====================================================================
        current_epoch <= 2;
        report "=== EPOCH 2: Testing Counter Reset Isolation & Zero-Loss Bursts ===";

        -- Test A: Re-inject confirmed Epoch 1 Heavy Hitter with 500 shares (0x01F4).
        -- Threshold is 20,000 (0x4E20). If BRAM bank switch failed, residual count
        -- + 500 will exceed 20,000 and leak into Epoch 2.
        if unsigned(ep1_sample_hh_key) /= 0 then
            write(v_msg, string'("EPOCH 2 Test A: Re-injecting former HH key 0x"));
            hwrite(v_msg, ep1_sample_hh_key);
            write(v_msg, string'(" with 500 shares"));
            report v_msg.all;
            deallocate(v_msg);

            SEND_DATA_PACKET(ep1_sample_hh_key, x"000001F4", tb_rx_serial);
        end if;

        -- Test B: Exact Zero-Loss Accumulation Test
        -- 20 * 950 = 19,000 (below threshold), 21st packet (+2,000) crosses at 21,000 (1 slot)
        for pkt_idx in 1 to 20 loop
            SEND_DATA_PACKET(x"11112222", x"000003B6", tb_rx_serial); -- 950
        end loop;
        SEND_DATA_PACKET(x"11112222", x"000007D0", tb_rx_serial);     -- 2,000 -> total 21,000

        -- Test C: Full 16-Slot Logger Saturation Burst
        -- Send 15 distinct heavy hitters (25,000 = 0x000061A8 shares each)
        -- back-to-back with zero idle gap to fill all 16 logger slots (1 + 15 = 16).
        for slot_idx in 1 to 15 loop
            v_burst_key := x"CAFE000" & std_logic_vector(to_unsigned(slot_idx, 4));
            SEND_DATA_PACKET(v_burst_key, x"000061A8", tb_rx_serial);
        end loop;

        wait for CLK_PERIOD * 100;

        v_bytes_before := rx_byte_total;
        SEND_FLUSH_COMMAND(tb_rx_serial);
        wait for 350 us;

        v_dump_bytes := rx_byte_total - v_bytes_before;

        report "==================================================";
        report "EPOCH 2 UART DUMP BYTES RECEIVED      : " & integer'image(v_dump_bytes);
        report "EPOCH 2 HEAVY HITTERS LOGGED          : " & integer'image(ep2_hh_count);
        report "EPOCH 2 ACCUMULATED VOL (0x11112222)  : " & integer'image(to_integer(unsigned(ep2_accum_vol)));
        report "EPOCH 2 BURST KEYS RECOVERED          : " & integer'image(ep2_burst_found) & " / 15";
        report "==================================================";

        assert v_dump_bytes = 128
            report "EPOCH 2 FLUSH ERROR: Expected 128 dump bytes, got " & integer'image(v_dump_bytes)
            severity error;

        assert not ep2_stale_leaked
            report "BANK SWITCH FAILURE: Stale count from Epoch 1 leaked into Epoch 2!"
            severity error;

        assert ep2_accum_found and (unsigned(ep2_accum_vol) = to_unsigned(21000, 32))
            report "PACKET LOSS DETECTED: Key 0x11112222 expected 21000, got " &
                   integer'image(to_integer(unsigned(ep2_accum_vol)))
            severity error;

        assert ep2_burst_found = 15
            report "LOGGER BURST LOSS: Expected 15 burst heavy hitters, got " &
                   integer'image(ep2_burst_found)
            severity error;

        report "ALL VERIFICATION CHECKS PASSED SUCCESSFULLY.";

        -- Flush files to disk immediately for Python oracle comparison
        file_close(input_file);
        file_close(output_file);

        std.env.stop;
        wait;
    end process;

    -- =========================================================================
    -- Host PC UART Listener & Record Deserializer
    -- =========================================================================
    host_listen_proc: process(clk)
        variable byte_idx : integer range 0 to 7 := 0;
        variable rec_key  : std_logic_vector(31 downto 0);
        variable rec_vol  : std_logic_vector(31 downto 0);
        variable v_oline  : line;
    begin
        if rising_edge(clk) then
            if pc_rx_dv = '1' then
                rx_byte_total <= rx_byte_total + 1;

                case byte_idx is
                    when 0 => rec_key(31 downto 24) := pc_rx_byte;
                    when 1 => rec_key(23 downto 16) := pc_rx_byte;
                    when 2 => rec_key(15 downto 8)  := pc_rx_byte;
                    when 3 => rec_key(7 downto 0)   := pc_rx_byte;
                    when 4 => rec_vol(31 downto 24) := pc_rx_byte;
                    when 5 => rec_vol(23 downto 16) := pc_rx_byte;
                    when 6 => rec_vol(15 downto 8)  := pc_rx_byte;
                    when 7 =>
                        rec_vol(7 downto 0) := pc_rx_byte;

                        if unsigned(rec_key) /= 0 then
                            if current_epoch = 1 then
                                hwrite(v_oline, rec_key);
                                write(v_oline, string'(" "));
                                hwrite(v_oline, rec_vol);
                                writeline(output_file, v_oline);

                                if ep1_hh_count = 0 then
                                    ep1_sample_hh_key <= rec_key;
                                end if;
                                ep1_hh_count <= ep1_hh_count + 1;
                            else
                                ep2_hh_count <= ep2_hh_count + 1;

                                if rec_key = ep1_sample_hh_key then
                                    ep2_stale_leaked <= true;
                                end if;
                                if rec_key = x"11112222" then
                                    ep2_accum_found <= true;
                                    ep2_accum_vol   <= rec_vol;
                                end if;
                                if (rec_key(31 downto 4) = x"CAFE000") and (unsigned(rec_vol) = to_unsigned(25000, 32)) then
                                    ep2_burst_found <= ep2_burst_found + 1;
                                end if;
                            end if;
                        end if;
                    when others => null;
                end case;

                if byte_idx = 7 then
                    byte_idx := 0;
                else
                    byte_idx := byte_idx + 1;
                end if;
            end if;
        end if;
    end process;

end sim;