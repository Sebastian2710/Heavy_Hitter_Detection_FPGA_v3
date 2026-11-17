library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_hft_cms_top_physical is
-- Top-level testbenches have no ports
end tb_hft_cms_top_physical;

architecture sim of tb_hft_cms_top_physical is

    -- 1. The Merged Top-Level DUT
    component hft_cms_top
        port (
            clk       : in  std_logic;
            rst       : in  std_logic;
            i_UART_RX : in  std_logic;
            o_UART_TX : out std_logic;
            -- Debug ports
            o_DBG_valid    : out std_logic;
            o_DBG_activity : out std_logic_vector(31 downto 0);
            o_DBG_is_hh    : out std_logic
        );
    end component;

    -- 2. Host PC's UART Receiver (to catch the FPGA's output)
    -- We instantiate Nandland's RX block in the testbench to deserialize 
    -- the data streaming out of the FPGA's TX pin.
    component uart_rx
        generic ( g_CLKS_PER_BIT : integer := 868 );
        port (
            i_Clk       : in  std_logic;
            i_RX_Serial : in  std_logic;
            o_RX_DV     : out std_logic;
            o_RX_Byte   : out std_logic_vector(7 downto 0)
        );
    end component;

    -- Timing Constants
    constant CLK_PERIOD : time := 10 ns;
    --   constant BIT_PERIOD : time := 8680 ns; -- 115200 baud at 100MHz -> 10^9/115200
    constant BIT_PERIOD : time := 100 ns ; --10 clock cycles per bit (Fast Sim Mode)


    -- Signals
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '0';
    signal tb_rx_serial : std_logic := '1'; -- Driven by TB, read by DUT
    signal tb_tx_serial : std_logic;        -- Driven by DUT, read by TB
    
    -- Signals to catch the debug ports
    signal dbg_valid    : std_logic;
    signal dbg_activity : std_logic_vector(31 downto 0);
    signal dbg_is_hh    : std_logic;

    -- PC Receiver Signals
    signal pc_rx_dv     : std_logic;
    signal pc_rx_byte   : std_logic_vector(7 downto 0);

    -- File I/O setup
    file input_file  : text open read_mode is "market_stream.txt";
    file output_file : text open write_mode is "hardware_heavy_hitters.txt";

    -- =========================================================================
    -- UART Bit-Banging Procedure (Simulates PC transmitting to FPGA)
    -- =========================================================================
    procedure UART_WRITE_BYTE (
        i_data_in       : in  std_logic_vector(7 downto 0);
        signal o_serial : out std_logic) is
    begin
        -- Start Bit
        o_serial <= '0';
        wait for BIT_PERIOD;
        -- Data Bits (LSB first for standard UART)
        for i in 0 to 7 loop
            o_serial <= i_data_in(i);
            wait for BIT_PERIOD;
        end loop;
        -- Stop Bit
        o_serial <= '1';
        wait for BIT_PERIOD;
    end procedure;

begin

    -- Instantiate the fully merged Hardware Pipeline
    uut: hft_cms_top
        port map (
            clk            => clk,
            rst            => rst,
            i_UART_RX      => tb_rx_serial,
            o_UART_TX      => tb_tx_serial,
            o_DBG_valid    => dbg_valid,
            o_DBG_activity => dbg_activity,
            o_DBG_is_hh    => dbg_is_hh
        );

    -- Instantiate Nandland RX to act as the Host PC listening to the FPGA
    host_pc_rx: uart_rx
        generic map ( g_CLKS_PER_BIT => 10 ) -- NEW: Fast Sim Mode
        port map (
            i_Clk       => clk,
            i_RX_Serial => tb_tx_serial,
            o_RX_DV     => pc_rx_dv,
            o_RX_Byte   => pc_rx_byte
        );

    -- Clock Generation
    clk_process : process
    begin
        clk <= '0';
        wait for CLK_PERIOD/2;
        clk <= '1';
        wait for CLK_PERIOD/2;
    end process;

    -- =========================================================================
    -- Main Host PC Control Process (Data Injection & Flush Trigger)
    -- =========================================================================
    host_stim_proc: process
        variable v_iline   : line;
        variable v_key_hex : std_logic_vector(31 downto 0);
        variable v_vol_hex : std_logic_vector(31 downto 0);
        variable v_space   : character;
        -- NEW: Benchmark Variables
        variable v_start_time : time;
        variable v_end_time   : time;
        variable v_total_time : time;
    begin
        -- Hardware Reset
        rst <= '1';
        wait for CLK_PERIOD * 10;
        rst <= '0';
        wait for CLK_PERIOD * 10;

        report "Host PC: Starting ITCH data stream injection over UART...";

        -- START STOPWATCH
        v_start_time := now;
        
       -- Stream Data Packet by Packet
        while not endfile(input_file) loop
            readline(input_file, v_iline);
            
            -- FIX: Skip empty trailing lines to prevent Simulator 45-1 Fatal Error
            if v_iline'length = 0 then
                next; 
            end if;

            hread(v_iline, v_key_hex);
            read(v_iline, v_space); 
            hread(v_iline, v_vol_hex);

            -- Transmit Opcode 0x01 (Data Packet)
            UART_WRITE_BYTE(x"01", tb_rx_serial);
            
            -- Transmit Key (Big-Endian sequence)
            UART_WRITE_BYTE(v_key_hex(31 downto 24), tb_rx_serial);
            UART_WRITE_BYTE(v_key_hex(23 downto 16), tb_rx_serial);
            UART_WRITE_BYTE(v_key_hex(15 downto 8), tb_rx_serial);
            UART_WRITE_BYTE(v_key_hex(7 downto 0), tb_rx_serial);
            
            -- Transmit Volume (Big-Endian sequence)
            UART_WRITE_BYTE(v_vol_hex(31 downto 24), tb_rx_serial);
            UART_WRITE_BYTE(v_vol_hex(23 downto 16), tb_rx_serial);
            UART_WRITE_BYTE(v_vol_hex(15 downto 8), tb_rx_serial);
            UART_WRITE_BYTE(v_vol_hex(7 downto 0), tb_rx_serial);
        end loop;
        
        -- STOP STOPWATCH
        v_end_time := now;
        v_total_time := v_end_time - v_start_time;

        report "==================================================";
        report "BENCHMARK: Total Stream Ingestion Time = " & time'image(v_total_time);
        report "==================================================";
        
        report "Host PC: Data injection complete. Waiting for CMS pipeline latency...";
        wait for CLK_PERIOD * 100;

        report "Host PC: Triggering Epoch Flush over UART...";
        -- Transmit Opcode 0x02 (Flush Request)
        UART_WRITE_BYTE(x"02", tb_rx_serial);
        -- Send 8 dummy bytes to complete the 9-byte frame expected by your handler
        for i in 1 to 8 loop
            UART_WRITE_BYTE(x"00", tb_rx_serial);
        end loop;

        -- The testbench will now idle while the FPGA sweeps the BRAM.
        -- Once finished, the FPGA will begin pushing the 16 slots back to us.
        -- Give the FPGA enough time to transmit 128 bytes at 115200 baud:
        -- 128 bytes * 10 bits/byte * 8.68 us = ~11.1 milliseconds
        wait for 15 ms;

        report "Host PC: Simulation Complete. Check hardware_heavy_hitters.txt";
        std.env.stop;
        wait;
    end process;

    -- =========================================================================
    -- Host PC Listening Process (Data Extraction from FPGA)
    -- =========================================================================
    host_listen_proc: process(clk)
        variable byte_idx : integer range 0 to 7 := 0;
        variable rec_key  : std_logic_vector(31 downto 0);
        variable rec_vol  : std_logic_vector(31 downto 0);
        variable v_oline  : line;
    begin
        if rising_edge(clk) then
            if pc_rx_dv = '1' then
                -- Reconstruct the 64-bit record from the incoming 8-bit stream
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
                        
                        -- If the slot isn't completely empty, log it to the text file
                        if unsigned(rec_key) /= 0 then
                            hwrite(v_oline, rec_key);
                            write(v_oline, string'(" "));
                            hwrite(v_oline, rec_vol);
                            writeline(output_file, v_oline);
                        end if;
                    when others => null;
                end case;

                -- Advance byte index to track reconstruction
                if byte_idx = 7 then
                    byte_idx := 0;
                else
                    byte_idx := byte_idx + 1;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Benchmark Process: Core Pipeline Latency
    -- =========================================================================
    latency_benchmark_proc: process
        variable v_ingest_time : time;
        variable v_detect_time : time;
    begin
        wait until (dbg_valid = '1' and unsigned(dbg_activity) > 1000);
        v_ingest_time := now;
        
        wait until dbg_is_hh = '1';
        v_detect_time := now;
        
        report "==================================================";
        report "BENCHMARK: Core Latency = " & time'image(v_detect_time - v_ingest_time);
        report "==================================================";
        
        -- Suspend the process forever once we measure it once
        wait; 
    end process;

end sim;