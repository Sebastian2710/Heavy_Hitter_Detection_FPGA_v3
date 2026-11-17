library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity epoch_controller is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        
        -- Trigger from UART RX Handler
        flush_request : in  std_logic;
        
        -- Outputs taking control of the Memory Pipelines
        flush_enable  : out std_logic;
        flush_addr    : out std_logic_vector(10 downto 0);
        
        -- Signal to TX Controller that memory is cleared and logger is ready
        flush_done    : out std_logic
    );
end epoch_controller;

architecture rtl of epoch_controller is

    type state_type is (NORMAL_OP, FLUSHING);
    signal current_state : state_type;
    
    -- Counter for sweeping BRAM addresses
    signal addr_counter : unsigned(10 downto 0) := (others => '0');

begin

    process(clk, rst)
    begin
        if rst = '1' then
            current_state <= NORMAL_OP;
            addr_counter  <= (others => '0');
            flush_enable  <= '0';
            flush_addr    <= (others => '0');
            flush_done    <= '0';
            
        elsif rising_edge(clk) then
            
            -- Default single-cycle pulse for flush_done
            flush_done <= '0';
            
            case current_state is
            
                when NORMAL_OP =>
                    flush_enable <= '0';
                    addr_counter <= (others => '0');
                    
                    -- Wait for the external trigger from the RX wrapper
                    if flush_request = '1' then
                        current_state <= FLUSHING;
                    end if;
                    
                when FLUSHING =>
                    -- Assert the override flags
                    flush_enable <= '1';
                    flush_addr   <= std_logic_vector(addr_counter);
                    
                    -- Sweep through all 2048 addresses
                    if addr_counter = 2047 then
                        current_state <= NORMAL_OP;
                        flush_done    <= '1'; -- Wake up the TX controller
                    else
                        addr_counter  <= addr_counter + 1;
                    end if;
                    
            end case;
            
        end if;
    end process;

end rtl;