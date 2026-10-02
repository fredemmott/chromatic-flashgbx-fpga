import cartio_types::*;

module cartio_top(
    input  wire        clk,
    input  wire        reset,
    output reg         enabled_o,

    output reg         rx_ready,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    output reg         tx_flush,
    output reg         tx_valid,
    output reg  [7:0]  tx_data,

    output reg         cart_enabled,
    input wire         cart_powered,
    input wire         cart_ready,

    input  wire        cart_det,
    output reg  [15:0] cart_a,
    output reg         cart_a_oe,
    output reg         cart_clk,
    output reg         cart_cs,
    output reg         cart_rd,
    output reg         cart_wr,
    output reg         cart_data_dir_e,   // 1 = read, 0 = write
    output reg  [7:0]  cart_d_out,        // data to write
    input  wire [7:0]  cart_d_in,         // data read from cart
    output tristate_pin_t cart_rst,
    output tristate_pin_t cart_audio
);

logic [25:0] timeout;
always @(posedge clk) begin
    if (reset) begin
        timeout <= 26'd0;
    end else if (rx_valid) begin
        timeout <= 26'd60_000_000;
    end else if (timeout > 26'd0) begin
        timeout <= timeout - 26'd1;
    end
end

logic [7:0] fifo [2047:0];
logic [10:0] fifo_read_p;
logic [10:0] fifo_write_p;
logic [11:0] fifo_count;
logic [7:0] fifo_q;
assign fifo_q = fifo[fifo_read_p];

wire next_byte_valid = fifo_count > 12'd0;
wire [7:0] next_byte = fifo_q;
//wire next_byte_valid = rx_valid;
//wire [7:0] next_byte = rx_data;

typedef enum {
  S_IDLE,
  S_WAIT_ARG,
  S_EXEC_VERIFY, // post-write CMD_VERIFY_DATA or CMD_VERIFY_STATUS_REGISTER
  S_EXEC_DELAY,
  S_EXEC_DISCONNECT, // we've hit our timeout; reset MBC, disable
  S_DISCONNECTED
} state_t;
state_t state;
state_t state_d;
always @(posedge clk) begin
    state_d <= state;
end
assign rx_ready = (fifo_count <= 12'd1536); // 2048 - 512 (max packet size)

logic next_byte_pop;
always @(*) begin
    next_byte_pop = 1'b0;
    if (next_byte_valid) begin
        unique case (state)
            S_IDLE, S_WAIT_ARG: next_byte_pop = 1'b1;
            default: ;
        endcase
    end
end

always @(posedge clk) begin
    if (reset) begin
        enabled_o <= 1'b0;
    end else if (next_byte_pop) begin
        enabled_o <= 1'b1;
    end else if (state == S_DISCONNECTED) begin
        enabled_o <= 1'b0;
    end
end

always @(posedge clk) begin
    if (reset) begin
        fifo_count <= 12'd0;
        fifo_read_p <= 11'd0;
        fifo_write_p <= 11'd0;
    end else begin
        if (rx_valid) begin
            fifo[fifo_write_p] <= rx_data;
            fifo_write_p <= fifo_write_p + 11'd1;
        end
        if (next_byte_pop) begin
            fifo_read_p <= fifo_read_p + 11'd1;
        end
        unique case ({rx_valid, next_byte_pop})
            2'b00, 2'b11: /* no change to count */ ;
            2'b01: fifo_count <= fifo_count - 12'd1;
            2'b10: fifo_count <= fifo_count + 12'd1;
        endcase
    end
end

typedef enum {
    VS_SET_RD_L,
    VS_HOLD_RD_L,
    VS_SET_RD_H, // also read and TX here
    VS_HOLD_RD_H,
    VS_COMPLETE
} verify_state_t;
verify_state_t verify_state;

wire delay_complete;

logic disconnect_complete;

command_t command;
command_t command_latched;
logic [7:0] arg;
logic [7:0] arg_latched;

always @(*) begin
    command = CMD_NOP;
    arg = 8'd0;
    unique case (state)
        S_IDLE: /* nop */;
        S_WAIT_ARG: begin
            // NOP *until* we receive the arg byte, then we have everything
            if (next_byte_valid) begin
                command = command_latched;
                arg = next_byte;
            end
        end
        default: begin
            command = command_latched;
            arg = arg_latched;
        end
    endcase
end


always @(posedge clk) begin
    state <= state;
    command_latched <= command_latched;
    arg_latched <= arg_latched;
    tx_flush <= 1'b0;

    if (reset) begin
        state <= S_IDLE;
        command_latched <= CMD_NOP;
        arg_latched <= 8'd0;
    end else if (state == S_EXEC_VERIFY) begin
        if (verify_state == VS_COMPLETE) begin
            state <= S_IDLE;
        end
    end else if (state == S_EXEC_DELAY) begin
        if (delay_complete) begin
            state <= S_IDLE;
        end
    end else if (next_byte_valid) begin
        unique case (state)
            S_IDLE: begin
                command_latched <= command_t'(next_byte);

                state <= S_WAIT_ARG;
            end
            S_WAIT_ARG: begin
                state <= S_IDLE;
                arg_latched <= next_byte;

                unique case (command)
                    CMD_VERIFY_DATA: state <= S_EXEC_VERIFY;
                    CMD_VERIFY_STATUS_REGISTER: state <= S_EXEC_VERIFY;
                    CMD_DELAY: state <= S_EXEC_DELAY;
                    CMD_FLUSH: tx_flush <= 1'b1;
                    CMD_BYE: state <= S_EXEC_DISCONNECT;
                    default: /* nothing to do */ ;
                endcase
            end
            S_EXEC_VERIFY: /* nothing */ ;
            default: state <= S_IDLE;
        endcase
    end else if ((state == S_IDLE) && (timeout == 26'd0) && enabled_o) begin
        state <= S_EXEC_DISCONNECT;
    end else if ((state == S_EXEC_DISCONNECT) && disconnect_complete) begin
        state <= S_DISCONNECTED;
    end else if (state == S_DISCONNECTED) begin
        state <= S_IDLE;
    end
end

logic [7:0] status_register_mask;
logic [7:0] status_register_value;

always @(posedge clk) begin
    if (reset) begin
        status_register_mask <= 8'd0;
        status_register_value <= 8'd0;
    end else if (next_byte_valid) begin
        unique case (command)
            CMD_SET_STATUS_REGISTER_MASK: status_register_mask <= next_byte;
            CMD_SET_STATUS_REGISTER_VALUE: status_register_value <= next_byte;
            default: /* nothing */;
        endcase
    end
end

logic [4:0] verify_delay;
logic [31:0] verify_timeout;
logic [7:0] verify_result;

logic verify_pass;
always @(*) begin
    unique case (command)
        CMD_VERIFY_DATA: verify_pass = (verify_result == arg);
        CMD_VERIFY_STATUS_REGISTER: verify_pass = (verify_result & status_register_mask) == status_register_value;
        default: verify_pass = 1'b0;
    endcase
end

always @(posedge clk) begin
    verify_delay <= verify_delay;
    if (state != S_EXEC_VERIFY) begin
        verify_timeout <= 32'd60_000; // 1ms in 16.667 ticks
        verify_state <= VS_SET_RD_L;
    end else begin
        if (verify_timeout > 32'd0) begin
            verify_timeout <= verify_timeout - 32'd1;
        end
        if (verify_delay > 5'd0) begin
            verify_delay <= verify_delay - 5'd1;
        end
        unique case (verify_state)
            VS_SET_RD_L: begin
                verify_delay <= 5'd24; // 400ns in 16.667ns ticks
                verify_state <= VS_HOLD_RD_L;
            end
            VS_HOLD_RD_L: begin
                if (verify_delay == 5'd1) begin
                    verify_result <= cart_d_in;
                    verify_state <= VS_SET_RD_H;
                end
            end
            VS_SET_RD_H: begin
                verify_delay <= 5'd3; // 50ns
                verify_state <= VS_HOLD_RD_H;
            end
            VS_HOLD_RD_H: begin
                if (verify_delay == 5'd1) begin
                    if (verify_pass || (verify_timeout == 32'd0)) begin
                        verify_state <= VS_COMPLETE;
                    end else begin
                        verify_state <= VS_SET_RD_L;
                    end
                end
            end
            default: ;
        endcase
    end
end

logic [15:0] disconnect_a;
logic [7:0] disconnect_d;

typedef enum {
    DS_HIGH,
    DS_SETUP,
    DS_LOW,
    DS_DELAY,
    DS_COMPLETE
} disconnect_state_t;
disconnect_state_t disconnect_state;

`define SET_PIN(TARGET, IDX) \
        if (arg[IDX + 4]) TARGET <= arg[IDX];
`define SET_TRISTATE_PIN(TARGET, IDX) \
        if (arg[IDX + 4]) begin \
            TARGET.oe <= 1'b1; \
            TARGET.value <= arg[IDX]; \
        end

always @(posedge clk) begin
    if (reset | !enabled_o) begin
        cart_clk <= 1'b1;
        cart_wr <= 1'b1;
        cart_rd <= 1'b1;
        cart_cs <= 1'b1;
        cart_rst <= '{default: 0};
        cart_audio <= '{default: 0};

        cart_a <= 16'd0;
        cart_d_out <= 8'd0;
        cart_data_dir_e <= 1'b1; // read

        cart_a_oe <= 1'b1;
    end else begin
        unique case (command)
            CMD_SET_OUTPUT_ENABLE: begin
                if (arg[OE_AUDIO + 4]) begin
                    cart_audio.oe <= arg[OE_AUDIO];
                end
                if (arg[OE_DATA + 4]) begin
                    cart_data_dir_e <= ~arg[OE_DATA];
                end
                if (arg[OE_ADDRESS + 4]) begin
                    cart_a_oe <= arg[OE_ADDRESS];
                end
            end
            CMD_SET_PINS_A: begin
                `SET_PIN(cart_clk, SET_PINS_A_CLK);
                `SET_PIN(cart_wr, SET_PINS_A_WR);
                `SET_PIN(cart_rd, SET_PINS_A_RD)
                `SET_PIN(cart_cs, SET_PINS_A_CS)
            end
            CMD_SET_PINS_B: begin
                `SET_PIN(cart_a[15], SET_PINS_B_A15);
                `SET_TRISTATE_PIN(cart_rst, SET_PINS_B_RST);
                `SET_TRISTATE_PIN(cart_audio, SET_PINS_B_AUDIO);
            end
            CMD_SET_ADDRESS_MSB: begin
                cart_a[15:8] <= arg;
            end
            CMD_SET_ADDRESS_LSB: begin
                cart_a[7:0] <= arg;
            end
            CMD_SET_DATA: begin
                cart_d_out[7:0] <= arg;
            end
            default: ;
        endcase

        if (state == S_EXEC_VERIFY) begin
            unique case (verify_state)
                VS_SET_RD_L: cart_rd <= 1'b0;
                VS_SET_RD_H: cart_rd <= 1'b1;
                default: /* nothing */ ;
            endcase
        end else if (state == S_EXEC_DISCONNECT) begin
            cart_cs <= 1'b1;
            unique case (disconnect_state)
                DS_HIGH: begin
                    cart_clk <= 1'b1;
                    cart_wr <= 1'b1;
                end
                DS_SETUP: begin
                    cart_a <= disconnect_a;
                    cart_d_out <= disconnect_d;
                    cart_data_dir_e <= 1'b0;
                end
                DS_LOW: begin
                    cart_clk <= 1'b0;
                    cart_wr <= 1'b0;
                end
                DS_COMPLETE: begin
                    cart_rst.value <= 1'b1;
                    cart_rst.oe <= 1'b1;
                end
                default: ;
            endcase
        end
    end
end

assign cart_enabled = 1'b1;

localparam FW_INFO_BLOB = {
    // Size of this response, in bytes
    8'd0,

    // Our version timestamp - BCD
    /*  YYYY_MM_DD */
    32'h2026_09_27,

    // If we do multiple builds on the same day... __NOT__ BCD!
    8'd00, // Revision

    // Upstream (ModRetro) version number - __NOT__ BCD
    8'(fpga_fw_version::MAJOR),
    8'(fpga_fw_version::MINOR)
};
localparam FW_INFO_LEN = $bits(FW_INFO_BLOB) / 8;
localparam FW_INFO_ADDR_WIDTH = $clog2(FW_INFO_LEN);
reg [7:0] fw_info[0:FW_INFO_LEN- 1];

integer i;
initial begin
    fw_info[0] = 8'(FW_INFO_LEN);
    for (i = 1; i < FW_INFO_LEN; i = i + 1) begin
        fw_info[i] = FW_INFO_BLOB[(FW_INFO_LEN - 1 - i)*8 +: 8];
    end
end

always @(posedge clk) begin
    tx_valid <= 1'b0;
    tx_data <= 8'd0;

    if (!reset) begin
        unique case (command)
            CMD_PING: begin
                tx_valid <= 1'b1;
                tx_data <= ~arg;
            end
            CMD_GET_DATA: begin
                tx_valid <= 1'b1;
                tx_data <= cart_d_in;
            end
            CMD_VERIFY_DATA, CMD_VERIFY_STATUS_REGISTER: begin
                tx_valid <= (verify_state == VS_COMPLETE);
                tx_data <= verify_result;
            end
            CMD_GET_STATE_BITS: begin
                tx_valid <= 1'b1;
                tx_data <= 8'd0;
                tx_data[STATE_BIT_CART_PRESENT] <= cart_det;
                tx_data[STATE_BIT_CART_POWERED] <= cart_powered;
                tx_data[STATE_BIT_CART_READY]   <= cart_ready;
            end
            CMD_GET_FW_INFO: begin
                tx_valid <= arg < FW_INFO_LEN;
                tx_data <= (arg < FW_INFO_LEN) ? fw_info[arg] : 8'd0;
            end
            default: /* nop */ ;
        endcase
    end
end

logic [7:0] delay_counter;
always @(posedge clk) begin
    delay_counter <= arg;
    if (state == S_EXEC_DELAY) begin
        if (delay_counter >= 8'd1) begin
            delay_counter <= delay_counter - 8'd1;
        end
    end
end
assign delay_complete = delay_counter == 1'b1;

localparam LAST_DISCONNECT_STEP = 3'd5;

/* Holding RST low *should* reset a cartridge, but there are cartridges that ignore RST low.
 * https://github.com/Lesserkuma/FlashGBX_LK_Firmware/issues/9
 *
 * This sequence should reset an MBC1, MBC3, or MBC5, using the same sequence of commands
 * for all of them; in some cases they have slightly different but useful behaviors, on others,
 * they're ignored
 *
 * Thanks to the gbdev.io pandocs: https://gbdev.io/pandocs/MBCs.html
 *
 * ROM_BANK_SEL_HIGH
 * -----------------
 *
 * MBC1: same as BANK_SEL_LOW, but MBC1 treats 0x00 selection as 0x01
 * MBC3: sets all 7 bits, but also treats 0x00 selection as 0x01
 * MBC5: set high bits of bank
 *
 * ... so, setting to 0 always works :)
 *
 * RAM_BANK_SEL
 * ------------
 *
 * MBC1:
 *  - usually RAM bank select
 *  - also ROM bank number for some MBC multi-cart
 * MBC3: RAM bank select
 *
 * BANK_MODE_SEL
 * -------------
 *
 * MBC1: 0 is 'simple' bank 0 ROM+SRAM (default), 1 is 'advanced' (0x4000 register is live)
 */
logic [2:0] disconnect_step;
always @(*) begin
    unique case (disconnect_step)
        3'd0: begin
            // RAM_DISABLE
            disconnect_a = 16'h0000;
            disconnect_d = 8'h00;
        end
        3'd1: begin
            // ROM_BANK_SEL_LOW
            disconnect_a = 16'h2000;
            disconnect_d = 8'h01;
        end
        3'd2: begin
            // ROM_BANK_SEL_HIGH
            disconnect_a = 16'h3000;
            disconnect_d = 8'h00;
        end
        3'd3: begin
            // RAM_BANK_SEL
            disconnect_a = 16'h4000;
            disconnect_d = 8'h00;
        end
        3'd4: begin
            // BANK_MODE_SEL
            disconnect_a = 16'h6000;
            disconnect_d = 8'h00;
        end
        default: begin
            disconnect_a = 16'h0000;
            disconnect_d = 8'h00;
        end
    endcase
end

logic [5:0] disconnect_delay;
disconnect_state_t disconnect_state_next;
always @(posedge clk) begin
    if (state != S_EXEC_DISCONNECT) begin
        disconnect_step <= 3'd0;
        disconnect_state <= DS_HIGH;
        disconnect_delay <= 6'd0;
    end else if (disconnect_delay > 6'd0) begin
        disconnect_delay <= disconnect_delay - 6'd1;
    end else begin
        disconnect_state <= DS_DELAY;
        disconnect_state_next <= DS_DELAY;
        unique case (disconnect_state)
            DS_HIGH: begin
                disconnect_delay <= 6'd30; // ~ 500ns
                disconnect_state_next <= (disconnect_step == LAST_DISCONNECT_STEP) ? DS_COMPLETE : DS_SETUP;
            end
            DS_SETUP: begin
                disconnect_delay <= 6'd12; // ~ 200ns
                disconnect_state_next <= DS_LOW;
            end
            DS_LOW: begin
                disconnect_delay <= 6'd30;
                disconnect_state_next <= DS_HIGH;
                disconnect_step <= disconnect_step + 3'd1;
            end
            DS_DELAY: begin
                disconnect_state <= disconnect_state_next;
            end
            default: ;
        endcase
    end
end
assign disconnect_complete = disconnect_state == DS_COMPLETE;

endmodule