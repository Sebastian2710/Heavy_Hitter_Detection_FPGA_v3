library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hash_table_pipeline is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic; 
        hash_in           : in  std_logic_vector(10 downto 0);
        activity_in       : in  std_logic_vector(31 downto 0);
        valid_in          : in  std_logic;
        i_tready          : in  std_logic;
        o_tready          : out std_logic;
        flush_enable      : in  std_logic;
        flush_addr        : in  std_logic_vector(10 downto 0);
        updated_count_out : out std_logic_vector(31 downto 0)
    );
end hash_table_pipeline;

architecture rtl of hash_table_pipeline is

    component dual_port_bram
        port (
            clk   : in  std_logic;
            wea   : in  std_logic;
            addra : in  std_logic_vector(10 downto 0);
            dia   : in  std_logic_vector(31 downto 0);
            addrb : in  std_logic_vector(10 downto 0);
            dob   : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Standard Pipeline Signals
    signal hash_stg2     : std_logic_vector(10 downto 0);
    signal activity_stg2 : std_logic_vector(31 downto 0);
    signal valid_stg2    : std_logic;
    
    signal hash_stg3     : std_logic_vector(10 downto 0);
    signal count_stg3    : std_logic_vector(31 downto 0);
    signal valid_stg3    : std_logic;

    -- Forwarding Logic
    signal match_at_stage1      : std_logic;
    signal use_forwarded_stg2   : std_logic;
    signal forwarded_count_stg2 : std_logic_vector(31 downto 0);
    signal safe_count_to_add    : std_logic_vector(31 downto 0);
    signal new_computed_sum     : std_logic_vector(31 downto 0);

    -- Ping-Pong Memory Signals
    signal flush_enable_prev : std_logic := '0';
    signal active_bank       : std_logic := '0'; -- 0 = Bank A, 1 = Bank B
    signal next_active_bank  : std_logic := '0';
    signal active_bank_stg2  : std_logic := '0';
    signal active_bank_stg3  : std_logic := '0';

    signal bram_dob_A   : std_logic_vector(31 downto 0);
    signal bram_wea_A   : std_logic;
    signal bram_addra_A : std_logic_vector(10 downto 0);
    signal bram_dia_A   : std_logic_vector(31 downto 0);

    signal bram_dob_B   : std_logic_vector(31 downto 0);
    signal bram_wea_B   : std_logic;
    signal bram_addra_B : std_logic_vector(10 downto 0);
    signal bram_dia_B   : std_logic_vector(31 downto 0);
    
    signal bram_dob_selected : std_logic_vector(31 downto 0);

begin

    o_tready <= i_tready;

    -- Toggle immediately on flush_enable rising edge so flush_addr = 0 is included
    next_active_bank <= not active_bank when (flush_enable = '1' and flush_enable_prev = '0') else active_bank;

    -- Bank A: active writes when next_active_bank = '0', background flush when '1'
    bram_wea_A   <= (valid_stg3 and i_tready) when (next_active_bank = '0' and active_bank_stg3 = '0') else
                    flush_enable              when (next_active_bank = '1') else '0';
    bram_addra_A <= hash_stg3                 when (next_active_bank = '0') else flush_addr;
    bram_dia_A   <= count_stg3                when (next_active_bank = '0') else (others => '0');

    -- Bank B: active writes when next_active_bank = '1', background flush when '0'
    bram_wea_B   <= (valid_stg3 and i_tready) when (next_active_bank = '1' and active_bank_stg3 = '1') else
                    flush_enable              when (next_active_bank = '0') else '0';
    bram_addra_B <= hash_stg3                 when (next_active_bank = '1') else flush_addr;
    bram_dia_B   <= count_stg3                when (next_active_bank = '1') else (others => '0');

    bram_inst_A : dual_port_bram port map (
        clk => clk, wea => bram_wea_A, addra => bram_addra_A, dia => bram_dia_A,
        addrb => hash_in, dob => bram_dob_A
    );

    bram_inst_B : dual_port_bram port map (
        clk => clk, wea => bram_wea_B, addra => bram_addra_B, dia => bram_dia_B,
        addrb => hash_in, dob => bram_dob_B
    );

    bram_dob_selected <= bram_dob_A when active_bank_stg2 = '0' else bram_dob_B;

    -- Ping-Pong Bank Controller
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                active_bank       <= '0';
                flush_enable_prev <= '0';
            else
                flush_enable_prev <= flush_enable;
                active_bank       <= next_active_bank;
            end if;
        end if;
    end process;

    -- Data Pipeline & Hazard Forwarding Logic
    match_at_stage1 <= '1' when (hash_in = hash_stg3) and (valid_stg3 = '1') else '0';

    process(hash_stg2, hash_stg3, valid_stg3, bram_dob_selected, count_stg3, use_forwarded_stg2, forwarded_count_stg2)
    begin
        if (hash_stg2 = hash_stg3) and (valid_stg3 = '1') then
            safe_count_to_add <= count_stg3;
        elsif use_forwarded_stg2 = '1' then
            safe_count_to_add <= forwarded_count_stg2;
        else
            safe_count_to_add <= bram_dob_selected;
        end if;
    end process;

    new_computed_sum  <= std_logic_vector(unsigned(safe_count_to_add) + unsigned(activity_stg2));
    updated_count_out <= new_computed_sum when valid_stg2 = '1' else (others => '0');

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                hash_stg2            <= (others => '0');
                activity_stg2        <= (others => '0');
                valid_stg2           <= '0';
                use_forwarded_stg2   <= '0';
                forwarded_count_stg2 <= (others => '0');
                
                hash_stg3            <= (others => '0');
                count_stg3           <= (others => '0');
                valid_stg3           <= '0';
                
                active_bank_stg2     <= '0';
                active_bank_stg3     <= '0';
            else
                -- Keep bank pipeline aligned even during logger backpressure
                active_bank_stg2 <= next_active_bank;
                active_bank_stg3 <= active_bank_stg2;

                if i_tready = '1' then
                    hash_stg2     <= hash_in;
                    activity_stg2 <= activity_in;
                    valid_stg2    <= valid_in;
                    
                    use_forwarded_stg2 <= match_at_stage1;
                    if match_at_stage1 = '1' then
                        forwarded_count_stg2 <= count_stg3;
                    end if;
                    
                    hash_stg3     <= hash_stg2;
                    count_stg3    <= new_computed_sum;
                    valid_stg3    <= valid_stg2;
                end if;
            end if;
        end if;
    end process;

end rtl;