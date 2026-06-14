`timescale 1ns / 1ps

module block1_channel_unit(

    input wire clk,
    input wire rst,

    // valid dari kernel window 3x3
    input wire valid_in,

    // ready dari block setelah channel ini
    input wire ready_in,

    input wire [7:0]
        din0, din1, din2,
        din3, din4, din5,
        din6, din7, din8,

    input wire [2:0] channel_idx,

    // ready balik ke kernel
    output wire ready_out,

    // output hasil conv + relu + pool
    output wire [31:0] dout,
    output wire valid_out
);

    // =========================================================
    // WEIGHT ROM
    // =========================================================
    wire signed [15:0]
        w0,w1,w2,
        w3,w4,w5,
        w6,w7,w8,
        b;

    block1_weight_rom conv1_params (
        .clk(clk),
        .filter_idx(channel_idx),

        .w0(w0), .w1(w1), .w2(w2),
        .w3(w3), .w4(w4), .w5(w5),
        .w6(w6), .w7(w7), .w8(w8),

        .bias(b)
    );

    // =========================================================
    // MAC CONV + RELU
    // =========================================================
    wire mac_valid;
    wire mac_ready_out;
    wire mac_ready_in;

    wire [31:0] mac_dout;

    block1_kernel_mac_unit #(
        .DATA_INPUT_SIZE(8),
        .DATA_OUTPUT_SIZE(32)
    ) comp_kmac (
        .clk(clk),
        .rst(rst),

        .valid_in(valid_in),
        .ready_out(mac_ready_out),

        .ready_in(mac_ready_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .wk0(w0), .wk1(w1), .wk2(w2),
        .wk3(w3), .wk4(w4), .wk5(w5),
        .wk6(w6), .wk7(w7), .wk8(w8),

        .bias(b),

        .valid_out(mac_valid),
        .dout(mac_dout)
    );

    // =========================================================
    // MAX POOL
    // =========================================================
    wire pool_valid;
    wire pool_ready_out;

    wire signed [31:0] pool_dout;

    block1_fifo_shift_register_pool #(
        .WINDOW_SIZE(26),
        .DATA_SIZE(32),
        .TOTAL_WINDOW(13)
    ) uut_pool (
        .clk(clk),
        .rst(rst),

        .valid_in(mac_valid),
        .ready_out(pool_ready_out),

        .ready_in(ready_in),

        .din(mac_dout),

        .valid_out(pool_valid),
        .dout(pool_dout)
    );

    // =========================================================
    // READY CHAIN
    // =========================================================
    assign mac_ready_in = pool_ready_out;
    assign ready_out    = mac_ready_out;

    // =========================================================
    // OUTPUT CHANNEL
    // =========================================================
    assign dout      = pool_dout;
    assign valid_out = pool_valid;

endmodule