library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity h3_pipeline_stage is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        
        -- Inputs from the current bit and the matrix
        current_key_bit  : in  std_logic;
        matrix_vector    : in  std_logic_vector(10 downto 0);
        
        -- The cumulative hash value passed from the previous stage
        partial_hash_in  : in  std_logic_vector(10 downto 0);
        
        -- AXI-Stream Handshake
        i_tready         : in  std_logic;
        
        -- The newly computed hash value, registered for the next stage
        partial_hash_out : out std_logic_vector(10 downto 0)
    );
end h3_pipeline_stage;

architecture rtl of h3_pipeline_stage is
    signal masked_vector : std_logic_vector(10 downto 0);
    signal xor_result    : std_logic_vector(10 downto 0);
begin
    masked_vector <= matrix_vector when (current_key_bit = '1') else (others => '0');
    xor_result <= partial_hash_in xor masked_vector;

    process(clk, rst)
    begin
        if rst = '1' then
            partial_hash_out <= (others => '0');
        elsif rising_edge(clk) then
            if i_tready = '1' then
                partial_hash_out <= xor_result;
            end if;
        end if;
    end process;
end rtl;