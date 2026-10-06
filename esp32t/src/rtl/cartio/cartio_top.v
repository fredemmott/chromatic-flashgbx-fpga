import cartio_types::*;

module cartio_top(
    input  wire        clk,
    input  wire        reset,
    output reg         enabled_o,

    output reg         activity_led,

    input  wire [1:0]  pcb_version,

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

// Hold `cart_enable` low for a short while; this improves reliability:
// - on cartridges that take a while to reset
// - on games that don't use an MBC, but have an MBC cartridge; rst is sometimes not sufficient
//
// Can be peproed by flashing or dumping "Dangerous Demolition" to a FunnyPlaying EverSave MBC5 8MB/32KB
// then disconnecting; not 100% reliable repro, but say 60% failure rate at rebooting into the game
logic [22:0] disconnect_hold;
always @(posedge clk) begin
    if (state != S_DISCONNECTING) begin
        disconnect_hold <= 23'd6_000_000; // 100ms
    end else if (disconnect_hold > 23'd0) begin
        disconnect_hold <= disconnect_hold - 23'd1;
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
  S_DISCONNECTING, // power-off cartridge
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
                    CMD_BYE: state <= S_DISCONNECTING;
                    default: /* nothing to do */ ;
                endcase
            end
            S_EXEC_VERIFY: /* nothing */ ;
            default: state <= S_IDLE;
        endcase
    end else if ((state == S_IDLE) && (timeout == 26'd0) && enabled_o) begin
        state <= S_DISCONNECTING;
    end else if ((state == S_DISCONNECTING) && (disconnect_hold == 23'd0)) begin
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

logic enable_cart;
logic disable_cart;
always @(*) begin
    enable_cart = 1'b0;
    disable_cart = 1'b0;
    if ((command == CMD_SET_STATE_BITS) && arg[STATE_BIT_CART_POWERED + 4]) begin
        enable_cart = arg[STATE_BIT_CART_POWERED];
        disable_cart = ~arg[STATE_BIT_CART_POWERED];
    end else if (state == S_DISCONNECTING) begin
        disable_cart = 1'b1;
    end
end

`define SET_PIN(TARGET, IDX) \
        if (arg[IDX + 4]) TARGET <= arg[IDX];
`define SET_TRISTATE_PIN(TARGET, IDX) \
        if (arg[IDX + 4]) begin \
            TARGET.oe <= 1'b1; \
            TARGET.value <= arg[IDX]; \
        end

always @(posedge clk) begin
    if (reset | !enabled_o) begin
        cart_enabled <= 1'b0;

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
        end

        if (enable_cart) begin
            cart_enabled <= 1'b1;
        end else if (disable_cart) begin
            cart_enabled <= 1'b0;
            cart_a_oe <= 1'b0;
            cart_data_dir_e <= 1'b1;
            cart_clk <= 1'b0;
            cart_cs <= 1'b0;
            cart_rd <= 1'b0;
            cart_wr <= 1'b0;
            cart_rst.oe <= 1'b0;
            cart_audio.oe <= 1'b0;
        end

// Useful for voltage testing
`ifdef FORCE_EVERYTHING_HIGH
        cart_enabled <= 1'b1;
        cart_a <= 16'hFFFF;
        cart_a_oe <= 1'b1;
        cart_clk <= 1'b1;
        cart_cs <= 1'b1;
        cart_rd <= 1'b1;
        cart_wr <= 1'b1;
        cart_data_dir_e <= 1'b0;
        cart_d_out <= 8'hFF;
        cart_rst <= '{default: 1};
        cart_audio <= '{default: 1};
`endif
    end
end

localparam FW_INFO_BLOB = {
    // Size of this response, in bytes
    8'd0,

    // Our version timestamp - BCD
    /*  YYYY_MM_DD */
    32'h2026_10_06,

    // If we do multiple builds on the same day... __NOT__ BCD!
    8'd00, // Revision

    // Upstream (ModRetro) version number - __NOT__ BCD
    8'(fpga_fw_version::MAJOR),
    8'(fpga_fw_version::MINOR),

    // Lowest compatible protocol version
    8'd1,
    // Highest tested protocol version
    8'd1
};

localparam FW_INFO_ROM_LEN = $bits(FW_INFO_BLOB) / 8;
localparam FW_INFO_ROM_ADDR_WIDTH = $clog2(FW_INFO_ROM_LEN);
reg [7:0] fw_info_rom[0:FW_INFO_ROM_LEN- 1];

localparam FW_INFO_PCB_VERSION_IDX = FW_INFO_ROM_LEN;
localparam FW_INFO_LEN = FW_INFO_PCB_VERSION_IDX + 1;

integer i;
initial begin
    fw_info_rom[0] = 8'(FW_INFO_LEN);
    for (i = 1; i < FW_INFO_ROM_LEN; i = i + 1) begin
        fw_info_rom[i] = FW_INFO_BLOB[(FW_INFO_ROM_LEN - 1 - i)*8 +: 8];
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
                tx_data[STATE_BIT_ACTIVITY_LED] <= activity_led;
            end
            CMD_GET_FW_INFO: begin
                tx_valid <= arg < FW_INFO_LEN;
                tx_data <= 8'd0;
                if (arg < FW_INFO_ROM_LEN) begin
                    tx_data <= fw_info_rom[arg];
                end else if (arg == FW_INFO_PCB_VERSION_IDX) begin
                    tx_data <= { 6'd0, pcb_version };
                end
            end
            default: /* nop */ ;
        endcase
    end
end

always @(posedge clk) begin
    if (reset || !enabled_o) begin
        activity_led <= 1'b0;
    end else if ((command == CMD_SET_STATE_BITS) && arg[STATE_BIT_ACTIVITY_LED + 4]) begin
        activity_led <= arg[STATE_BIT_ACTIVITY_LED];
    end else begin
        activity_led <= activity_led;
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

endmodule