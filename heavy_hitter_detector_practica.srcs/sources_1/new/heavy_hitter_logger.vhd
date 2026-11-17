library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity heavy_hitter_logger is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;
        
        -- Trigger from the TX Readout Controller
        clear_log         : in  std_logic;
        
        -- Inputs from the Heavy Hitter Detector
        key_in            : in  std_logic_vector(31 downto 0);
        count_in          : in  std_logic_vector(31 downto 0);
        is_heavy_hitter   : in  std_logic;
        valid_in          : in  std_logic;
        
        -- AXI-Stream Handshake Output (Non-blocking circular buffer sink)
        o_tready          : out std_logic;
        
        -- Interface to read the logs (TX Controller)
        read_addr         : in  std_logic_vector(3 downto 0);
        read_key_out      : out std_logic_vector(31 downto 0);
        read_count_out    : out std_logic_vector(31 downto 0)
    );
end heavy_hitter_logger;

architecture rtl of heavy_hitter_logger is

    type mem_array_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal key_mem         : mem_array_t := (others => (others => '0'));
    signal count_mem       : mem_array_t := (others => (others => '0'));

    signal slot_valid      : std_logic_vector(15 downto 0) := (others => '0');
    signal slot_ptr_onehot : std_logic_vector(15 downto 0) := x"0001";

    -- Stage 1 combinational lookup signals
    signal slot_match      : std_logic_vector(15 downto 0);
    signal fwd_match       : std_logic;

    -- Stage 1 -> Stage 2 pipeline registers
    signal hh_valid_d1     : std_logic := '0';
    signal key_d1          : std_logic_vector(31 downto 0) := (others => '0');
    signal count_d1        : std_logic_vector(31 downto 0) := (others => '0');
    signal slot_match_d1   : std_logic_vector(15 downto 0) := (others => '0');
    signal fwd_match_d1    : std_logic := '0';
    signal fwd_target_d1   : std_logic_vector(15 downto 0) := (others => '0');

    -- Stage 2 combinational control signals
    signal any_match_d1      : std_logic;
    signal is_new_alloc_d1   : std_logic;
    signal stage2_target_oh  : std_logic_vector(15 downto 0);

begin

    -- Circular buffer never stalls the upstream CMS ingestion pipeline during normal operation
    o_tready <= not rst;

    -- Stage 1: Per-slot parallel key comparison against committed table
    gen_match: for i in 0 to 15 generate
        slot_match(i) <= '1' when (slot_valid(i) = '1' and key_mem(i) = key_in) else '0';
    end generate;

    -- Stage 1: Back-to-back hazard check against the entry currently in Stage 2
    fwd_match <= '1' when (hh_valid_d1 = '1' and key_d1 = key_in) else '0';

    -- Stage 2: Reduction and target slot resolution (uses registered Stage 1 flags)
    any_match_d1    <= '0' when slot_match_d1 = x"0000" else '1';
    is_new_alloc_d1 <= hh_valid_d1 and (not fwd_match_d1) and (not any_match_d1);

    stage2_target_oh <= fwd_target_d1   when fwd_match_d1 = '1' else
                        slot_match_d1   when any_match_d1 = '1' else
                        slot_ptr_onehot;

    process (clk, rst)
    begin
        if rst = '1' then
            key_mem         <= (others => (others => '0'));
            count_mem       <= (others => (others => '0'));
            slot_valid      <= (others => '0');
            slot_ptr_onehot <= x"0001";
            hh_valid_d1     <= '0';
            key_d1          <= (others => '0');
            count_d1        <= (others => '0');
            slot_match_d1   <= (others => '0');
            fwd_match_d1    <= '0';
            fwd_target_d1   <= (others => '0');

        elsif rising_edge(clk) then
            if clear_log = '1' then
                key_mem         <= (others => (others => '0'));
                count_mem       <= (others => (others => '0'));
                slot_valid      <= (others => '0');
                slot_ptr_onehot <= x"0001";
                hh_valid_d1     <= '0';
                slot_match_d1   <= (others => '0');
                fwd_match_d1    <= '0';

            else
                -- =============================================================
                -- STAGE 2: Commit previous cycle's heavy hitter to table
                -- =============================================================
                if hh_valid_d1 = '1' then
                    for i in 0 to 15 loop
                        if fwd_match_d1 = '1' then
                            if fwd_target_d1(i) = '1' then
                                count_mem(i) <= count_d1;
                            end if;
                        elsif any_match_d1 = '1' then
                            if slot_match_d1(i) = '1' then
                                count_mem(i) <= count_d1;
                            end if;
                        else
                            if slot_ptr_onehot(i) = '1' then
                                key_mem(i)    <= key_d1;
                                count_mem(i)  <= count_d1;
                                slot_valid(i) <= '1';
                            end if;
                        end if;
                    end loop;

                    -- Advance circular pointer only when allocating a new distinct slot
                    if fwd_match_d1 = '0' and any_match_d1 = '0' then
                        slot_ptr_onehot <= slot_ptr_onehot(14 downto 0) & slot_ptr_onehot(15);
                    end if;
                end if;

                -- =============================================================
                -- STAGE 1: Latch incoming packet and comparator results
                -- =============================================================
                hh_valid_d1   <= valid_in and is_heavy_hitter;
                key_d1        <= key_in;
                count_d1      <= count_in;
                fwd_match_d1  <= fwd_match;
                fwd_target_d1 <= stage2_target_oh;

                -- Mask out a slot if Stage 2 is overwriting it on this exact cycle
                for i in 0 to 15 loop
                    if is_new_alloc_d1 = '1' and slot_ptr_onehot(i) = '1' then
                        slot_match_d1(i) <= '0';
                    else
                        slot_match_d1(i) <= slot_match(i);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    read_key_out   <= key_mem(to_integer(unsigned(read_addr)));
    read_count_out <= count_mem(to_integer(unsigned(read_addr)));

end rtl;