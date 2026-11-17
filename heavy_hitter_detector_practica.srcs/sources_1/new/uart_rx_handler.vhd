library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx_handler is
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
end uart_rx_handler;

architecture rtl of uart_rx_handler is

    signal byte_counter : integer range 0 to 8 := 0;
    signal emit_flag    : std_logic := '0';

    signal opcode_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal key_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal act_reg      : std_logic_vector(31 downto 0) := (others => '0');

begin

    key_out      <= key_reg;
    activity_out <= act_reg;

    process(clk, rst)
    begin
        if rst = '1' then
            byte_counter  <= 0;
            emit_flag     <= '0';
            opcode_reg    <= (others => '0');
            key_reg       <= (others => '0');
            act_reg       <= (others => '0');
            valid_out     <= '0';
            flush_request <= '0';

        elsif rising_edge(clk) then
            -- Default single-cycle control pulse
            flush_request <= '0';

            if emit_flag = '1' then
                if opcode_reg = x"01" then
                    valid_out <= '1';
                    -- Data packet: hold valid until CMS pipeline accepts
                    if i_tready = '1' then
                        emit_flag <= '0';
                    end if;
                elsif opcode_reg = x"02" then
                    -- Control command: 1-cycle pulse regardless of logger full status
                    flush_request <= '1';
                    valid_out     <= '0';
                    emit_flag     <= '0';
                else
                    valid_out <= '0';
                    emit_flag <= '0';
                end if;
            else
                valid_out <= '0';
            end if;

            if rx_dv = '1' then
                case byte_counter is
                    when 0 => opcode_reg <= rx_byte;
                    when 1 => key_reg(31 downto 24) <= rx_byte;
                    when 2 => key_reg(23 downto 16) <= rx_byte;
                    when 3 => key_reg(15 downto 8)  <= rx_byte;
                    when 4 => key_reg(7 downto 0)   <= rx_byte;
                    when 5 => act_reg(31 downto 24) <= rx_byte;
                    when 6 => act_reg(23 downto 16) <= rx_byte;
                    when 7 => act_reg(15 downto 8)  <= rx_byte;
                    when 8 =>
                        act_reg(7 downto 0) <= rx_byte;
                        emit_flag <= '1';
                    when others =>
                        null;
                end case;

                if byte_counter = 8 then
                    byte_counter <= 0;
                else
                    byte_counter <= byte_counter + 1;
                end if;
            end if;
        end if;
    end process;

end rtl;