`timescale 1ns / 1ps

// ============================================================
// BLOCK2 WRAPPER
// Input  : pool1/block1 feature map = 13x13x8, packed 8ch x 32-bit
// Process: kernel 3x3x8 -> conv2_time_mux_16 -> pool2 2x2
// Output : pool2 feature map = 5x5x16, packed 16ch x 32-bit
//
// Handshake:
// - ready_out goes back to FIFO/block before block2
// - ready_in comes from FIFO/block after block2
// ============================================================

(* keep_hierarchy = "yes" *)
module block2 #(
    parameter IN_CHANNELS  = 8,
    parameter KERNEL_SIZE  = 9,
    parameter IN_WIDTH     = 32,
    parameter ACT_SIZE     = 24,
    parameter WEIGHT_SIZE  = 16,

    parameter OUT_CHANNELS = 16,
    parameter OUT_WIDTH    = 32,

    parameter KERNEL_WINDOW_SIZE = 13,
    parameter POOL_WINDOW_SIZE   = 11,
    parameter POOL_TOTAL_WINDOW  = 5,
    parameter ACT_SHIFT          = 0
)(
    input  wire clk,
    input  wire rst,

    // input dari FIFO setelah block1
    input  wire valid_in,
    output wire ready_out,
    input  wire [IN_CHANNELS*IN_WIDTH-1:0] din,

    // ready dari FIFO/block setelah block2
    input  wire ready_in,

    // output pool2
    output wire valid_out,
    output wire [OUT_CHANNELS*OUT_WIDTH-1:0] dout,

    // debug opsional
    output wire conv2_busy,
    output wire [4:0] conv2_launch_channel,
    output wire [4:0] conv2_collected_channel
);

    // ========================================================
    // Kernel generator block2: 3x3x8
    // ========================================================
    wire kernel_valid;
    wire conv2_ready;
    wire [IN_CHANNELS*KERNEL_SIZE*IN_WIDTH-1:0] kernel_dout;

    block2_fifo_shift_register_kernel #(
        .WINDOW_SIZE(KERNEL_WINDOW_SIZE),
        .DATA_SIZE(IN_WIDTH),
        .CHANNELS(IN_CHANNELS)
    ) u_block2_kernel (
        .clk(clk),
        .rst(rst),

        .valid_in(valid_in),
        .ready_out(ready_out),

        .ready_in(conv2_ready),

        .din(din),

        .valid_out(kernel_valid),
        .dout(kernel_dout)
    );

    // ========================================================
    // Conv2 time-mux: 8 input channel -> 16 output channel
    // ========================================================
    wire conv2_valid;
    wire pool_ready;
    wire [OUT_CHANNELS*OUT_WIDTH-1:0] conv2_dout;

    conv2_time_mux_16 #(
        .IN_CHANNELS(IN_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .DATA_SIZE(IN_WIDTH),
        .ACT_SIZE(ACT_SIZE),
        .WEIGHT_SIZE(WEIGHT_SIZE),
        .OUT_WIDTH(OUT_WIDTH),
        .OUT_CHANNELS(OUT_CHANNELS),
        .ACT_SHIFT(ACT_SHIFT)
    ) u_conv2_time_mux_16 (
        .clk(clk),
        .rst(rst),

        .valid_in(kernel_valid),
        .ready_out(conv2_ready),
        .din(kernel_dout),

        .ready_in(pool_ready),

        .valid_out(conv2_valid),
        .dout(conv2_dout),

        .busy(conv2_busy),
        .launch_channel(conv2_launch_channel),
        .collected_channel(conv2_collected_channel)
    );

    // ========================================================
    // Pool2: input 11x11x16 -> output 5x5x16
    // ========================================================
    block2_fifo_shift_register_pool_16ch #(
        .WINDOW_SIZE(POOL_WINDOW_SIZE),
        .DATA_SIZE(OUT_WIDTH),
        .CHANNELS(OUT_CHANNELS),
        .TOTAL_WINDOW(POOL_TOTAL_WINDOW)
    ) u_pool2 (
        .clk(clk),
        .rst(rst),

        .valid_in(conv2_valid),
        .ready_out(pool_ready),

        .ready_in(ready_in),

        .din(conv2_dout),

        .valid_out(valid_out),
        .dout(dout)
    );

endmodule