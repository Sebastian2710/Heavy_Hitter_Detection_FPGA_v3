library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library UNISIM;
use UNISIM.VComponents.all;
entity hft_cms_top is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        i_UART_RX : in  std_logic;
        o_UART_TX : out std_logic
        -- ==========================================
        -- SIMULATION DEBUG PORTS (Do not map in .xdc)
        -- ==========================================
--        o_DBG_valid    : out std_logic;
--        o_DBG_activity : out std_logic_vector(31 downto 0);
--        o_DBG_is_hh    : out std_logic
    );
end hft_cms_top;

architecture structural of hft_cms_top is

    -- -------------------------------------------------------------------------
    -- Configuration
    -- -------------------------------------------------------------------------
    constant THRESHOLD_CONST : std_logic_vector(31 downto 0) := x"00004E20";

    -- -------------------------------------------------------------------------
    -- Component Declarations
    -- -------------------------------------------------------------------------

    component uart_rx
        generic ( g_CLKS_PER_BIT : integer := 868 );
        port (
            i_Clk       : in  std_logic;
            i_RX_Serial : in  std_logic;
            o_RX_DV     : out std_logic;
            o_RX_Byte   : out std_logic_vector(7 downto 0)
        );
    end component;

    component uart_tx
        generic ( g_CLKS_PER_BIT : integer := 868 );
        port (
            i_Clk       : in  std_logic;
            i_TX_DV     : in  std_logic;
            i_TX_Byte   : in  std_logic_vector(7 downto 0);
            o_TX_Active : out std_logic;
            o_TX_Serial : out std_logic;
            o_TX_Done   : out std_logic
        );
    end component;

    component uart_rx_handler
        port (
            clk           : in  std_logic;
            rst           : in  std_logic;
            rx_dv         : in  std_logic;
            rx_byte       : in  std_logic_vector(7 downto 0);
            key_out       : out std_logic_vector(31 downto 0);
            activity_out  : out std_logic_vector(31 downto 0);
            valid_out     : out std_logic;
            i_tready      : in  std_logic;
            flush_request : out std_logic
        );
    end component;

    component epoch_controller
        port (
            clk           : in  std_logic;
            rst           : in  std_logic;
            flush_request : in  std_logic;
            flush_enable  : out std_logic;
            flush_addr    : out std_logic_vector(10 downto 0);
            flush_done    : out std_logic
        );
    end component;

    component cms_row
        generic ( ROW_ID : integer := 1 );
        port (
            clk               : in  std_logic;
            rst               : in  std_logic;
            key_in            : in  std_logic_vector(31 downto 0);
            activity_in       : in  std_logic_vector(31 downto 0);
            valid_in          : in  std_logic;
            flush_enable      : in  std_logic;
            flush_addr        : in  std_logic_vector(10 downto 0);
            i_tready          : in  std_logic;
            o_tready          : out std_logic;
            updated_count_out : out std_logic_vector(31 downto 0);
            valid_out         : out std_logic
        );
    end component;

    component heavy_hitter_detector
        port (
            clk             : in  std_logic;
            rst             : in  std_logic;
            key_in          : in  std_logic_vector(31 downto 0);
            count_row_1     : in  std_logic_vector(31 downto 0);
            count_row_2     : in  std_logic_vector(31 downto 0);
            count_row_3     : in  std_logic_vector(31 downto 0);
            count_row_4     : in  std_logic_vector(31 downto 0);
            count_row_5     : in  std_logic_vector(31 downto 0);
            count_row_6     : in  std_logic_vector(31 downto 0);
            count_row_7     : in  std_logic_vector(31 downto 0);
            valid_in        : in  std_logic;
            threshold       : in  std_logic_vector(31 downto 0);
            i_tready        : in  std_logic;
            o_tready        : out std_logic;
            key_out         : out std_logic_vector(31 downto 0);
            is_heavy_hitter : out std_logic;
            valid_out       : out std_logic
        );
    end component;

    component heavy_hitter_logger
        port (
            clk             : in  std_logic;
            rst             : in  std_logic;
            clear_log       : in  std_logic;
            key_in          : in  std_logic_vector(31 downto 0);
            count_in        : in  std_logic_vector(31 downto 0);
            is_heavy_hitter : in  std_logic;
            valid_in        : in  std_logic;
            o_tready        : out std_logic;
            read_addr       : in  std_logic_vector(3 downto 0);
            read_key_out    : out std_logic_vector(31 downto 0);
            read_count_out  : out std_logic_vector(31 downto 0)
        );
    end component;

    component uart_tx_controller
        port (
            clk           : in  std_logic;
            rst           : in  std_logic;
            flush_done    : in  std_logic;
            read_addr     : out std_logic_vector(3 downto 0);
            read_key_in   : in  std_logic_vector(31 downto 0);
            read_count_in : in  std_logic_vector(31 downto 0);
            clear_log     : out std_logic;
            tx_byte       : out std_logic_vector(7 downto 0);
            tx_dv         : out std_logic;
            tx_active     : in  std_logic;
            tx_done       : in  std_logic
        );
    end component;

    -- -------------------------------------------------------------------------
    -- Internal Signal Copper Wiring
    -- -------------------------------------------------------------------------
    
    signal rx_dv_sig       : std_logic;
    signal rx_byte_sig     : std_logic_vector(7 downto 0);

    signal key_bus         : std_logic_vector(31 downto 0);
    signal activity_bus    : std_logic_vector(31 downto 0);
    signal valid_bus       : std_logic;
    signal flush_req_sig   : std_logic;

    signal flush_en_sig    : std_logic;
    signal flush_addr_sig  : std_logic_vector(10 downto 0);
    signal flush_done_sig  : std_logic;

    type count_array_type is array (1 to 7) of std_logic_vector(31 downto 0);
    signal row_counts      : count_array_type;
    signal row_valids      : std_logic_vector(7 downto 1);
    
    signal row_counts_pipe : count_array_type;
    signal row_valids_pipe : std_logic_vector(7 downto 1); 
    
    -- =========================================================================
    -- FLUSH FANOUT PIPELINE SIGNALS
    -- =========================================================================
    type flush_addr_array_type is array (1 to 7) of std_logic_vector(10 downto 0);
    signal flush_en_pipe   : std_logic_vector(7 downto 1);
    signal flush_addr_pipe : flush_addr_array_type;
    
    attribute keep : string;
    attribute keep of flush_en_pipe   : signal is "true";
    attribute keep of flush_addr_pipe : signal is "true";
    
    signal hh_key_sig      : std_logic_vector(31 downto 0);
    signal is_hh_sig       : std_logic;
    signal hh_valid_sig    : std_logic;

    signal read_addr_sig   : std_logic_vector(3 downto 0);
    signal read_key_sig    : std_logic_vector(31 downto 0);
    signal read_count_sig  : std_logic_vector(31 downto 0);
    signal clear_log_sig   : std_logic;

    signal tx_byte_sig     : std_logic_vector(7 downto 0);
    signal tx_dv_sig       : std_logic;
    signal tx_active_sig   : std_logic;
    signal tx_done_sig     : std_logic;

    -- =========================================================================
    -- NEW: PIPELINE SYNCHRONIZATION CHAINS (Restored from Core V1)
    -- =========================================================================
    type key_delay_type is array (0 to 33) of std_logic_vector(31 downto 0);
    signal key_delay_chain : key_delay_type := (others => (others => '0'));
    
    type count_delay_type is array (0 to 2) of std_logic_vector(31 downto 0);
    signal count_delay_chain : count_delay_type := (others => (others => '0'));
    
    -- =========================================================================
    -- NEW: AXI-STREAM READY SIGNALS
    -- =========================================================================
    signal cms_ready_bus  : std_logic_vector(7 downto 1);
    signal rx_tready_sig  : std_logic;
    signal sys_tready_sig : std_logic;    
    -- =========================================================================
    -- EXPLICIT PHYSICAL I/O BUFFERS
    -- =========================================================================
    signal clk_ibuf     : std_logic;
    signal clk_buffered : std_logic;
    
    signal rst_buffered : std_logic;
    signal rx_buffered  : std_logic;
    signal tx_internal  : std_logic;
    
begin
-- =========================================================================
    -- HARDWARE PAD MAPPING (Forces Vivado to route physical I/O)
    -- =========================================================================
    
    -- 1. Clock Pad -> Global Clock Buffer
    ibuf_clk : IBUF port map (I => clk, O => clk_ibuf);
    bufg_clk : BUFG port map (I => clk_ibuf, O => clk_buffered);

    -- 2. Standard Input Pads
    ibuf_rst : IBUF port map (I => rst, O => rst_buffered);
    ibuf_rx  : IBUF port map (I => i_UART_RX, O => rx_buffered);

    -- 3. Standard Output Pad
    obuf_tx  : OBUF port map (I => tx_internal, O => o_UART_TX);
    
    -- =========================================================================
    -- UNIFIED PIPELINE & SHIFT REGISTER PROCESS
    -- =========================================================================
    
    rx_tready_sig <= cms_ready_bus(1) and cms_ready_bus(2) and cms_ready_bus(3) and cms_ready_bus(4) and cms_ready_bus(5) and cms_ready_bus(6) and cms_ready_bus(7);

  process(clk_buffered)
    begin
        if rising_edge(clk_buffered) then
            if rst_buffered = '1' then
                row_counts_pipe <= (others => (others => '0'));
                row_valids_pipe <= (others => '0');
                flush_en_pipe   <= (others => '0');
                flush_addr_pipe <= (others => (others => '0'));
            else
                -- High Fanout Flush Duplication (must run even when logger is full)
                for i in 1 to 7 loop
                    flush_en_pipe(i)   <= flush_en_sig;
                    flush_addr_pipe(i) <= flush_addr_sig;
                end loop;

                if sys_tready_sig = '1' then
                    row_counts_pipe <= row_counts;
                    row_valids_pipe <= row_valids;
                end if;
            end if;

            -- Synchronized Shift Chains
            if sys_tready_sig = '1' then
                key_delay_chain(0) <= key_bus;
                for i in 0 to 32 loop
                    key_delay_chain(i+1) <= key_delay_chain(i);
                end loop;

                count_delay_chain(0) <= row_counts(1);
                count_delay_chain(1) <= count_delay_chain(0);
                count_delay_chain(2) <= count_delay_chain(1);
            end if;
        end if;
    end process;
    -- -------------------------------------------------------------------------
    -- Module Instantiations
    -- -------------------------------------------------------------------------

    u_uart_rx: uart_rx
        generic map ( g_CLKS_PER_BIT => 10 ) -- TEMPORARY: Change from 868 to 10
        port map (
            i_Clk       => clk_buffered,
            i_RX_Serial => rx_buffered,
            o_RX_DV     => rx_dv_sig,
            o_RX_Byte   => rx_byte_sig
        );

    u_rx_handler: uart_rx_handler
        port map (
            clk           => clk_buffered,
            rst           => rst_buffered,
            rx_dv         => rx_dv_sig,
            rx_byte       => rx_byte_sig,
            key_out       => key_bus,
            activity_out  => activity_bus,
            valid_out     => valid_bus,
            i_tready      => rx_tready_sig,
            flush_request => flush_req_sig
        );

    u_epoch_controller: epoch_controller
        port map (
            clk           => clk_buffered,
            rst           => rst_buffered,
            flush_request => flush_req_sig,
            flush_enable  => flush_en_sig,
            flush_addr    => flush_addr_sig,
            flush_done    => flush_done_sig
        );

    gen_cms_rows: for i in 1 to 7 generate
        u_cms_row: cms_row
            generic map ( ROW_ID => i )
            port map (
                clk               => clk_buffered,
                rst               => rst_buffered,
                key_in            => key_bus,
                activity_in       => activity_bus,
                valid_in          => valid_bus,
                flush_enable      => flush_en_pipe(i),
                flush_addr        => flush_addr_pipe(i),
                i_tready          => sys_tready_sig,
                o_tready          => cms_ready_bus(i),
                updated_count_out => row_counts(i),
                valid_out         => row_valids(i)
            );
    end generate;
    
    u_hh_detector: heavy_hitter_detector
        port map (
            clk             => clk_buffered,
            rst             => rst_buffered,
            key_in          => key_delay_chain(33),
            count_row_1     => row_counts_pipe(1),
            count_row_2     => row_counts_pipe(2),
            count_row_3     => row_counts_pipe(3),
            count_row_4     => row_counts_pipe(4),
            count_row_5     => row_counts_pipe(5),
            count_row_6     => row_counts_pipe(6),
            count_row_7     => row_counts_pipe(7),
            valid_in        => row_valids_pipe(1),
            threshold       => THRESHOLD_CONST,
            i_tready        => sys_tready_sig,
            o_tready        => open, -- Driven globally by the logger to avoid long combinational loops
            key_out         => hh_key_sig,
            is_heavy_hitter => is_hh_sig,
            valid_out       => hh_valid_sig
        );

    u_hh_logger: heavy_hitter_logger
        port map (
            clk             => clk_buffered,
            rst             => rst_buffered,
            clear_log       => clear_log_sig,
            key_in          => hh_key_sig,
            count_in        => count_delay_chain(2), 
            is_heavy_hitter => is_hh_sig,
            valid_in        => hh_valid_sig, 
            o_tready        => sys_tready_sig, -- THE ANCHOR: This drives the entire backpressure chain
            read_addr       => read_addr_sig,
            read_key_out    => read_key_sig,
            read_count_out  => read_count_sig
        );

    u_tx_controller: uart_tx_controller
        port map (
            clk           => clk_buffered,
            rst           => rst_buffered,
            flush_done    => flush_done_sig,
            read_addr     => read_addr_sig,
            read_key_in   => read_key_sig,
            read_count_in => read_count_sig,
            clear_log     => clear_log_sig,
            tx_byte       => tx_byte_sig,
            tx_dv         => tx_dv_sig,
            tx_active     => tx_active_sig,
            tx_done       => tx_done_sig
        );

    u_uart_tx: uart_tx
        generic map ( g_CLKS_PER_BIT => 10 ) -- TEMPORARY: Change from 868 to 10
        port map (
            i_Clk       => clk_buffered,
            i_TX_DV     => tx_dv_sig,
            i_TX_Byte   => tx_byte_sig,
            o_TX_Active => tx_active_sig,
            o_TX_Serial => tx_internal,
            o_TX_Done   => tx_done_sig
        );
        
        
--    -- Route internal signals to debug ports
--    o_DBG_valid    <= valid_bus; 
--    o_DBG_activity <= activity_bus;
--    o_DBG_is_hh    <= is_hh_sig;
end structural;