`timescale 1ns / 1ps

// ============================================================
// BLOCK3 WRAPPER
// Input  : pool2 feature map = 5x5x16, packed 16ch x 32-bit
// Process: kernel 3x3x16 -> conv3_time_mux_32 -> pool3 max4
// Output : pool3 feature vector = 1x1x32, packed 32ch x 32-bit
//
// Handshake:
// - ready_out goes back to FIFO/block before block3
// - ready_in comes from dense block
// ============================================================

(* keep_hierarchy = "yes" *)
module block3 #(
    parameter IN_CHANNELS      = 16,
    parameter GROUP_CHANNELS   = 8,
    parameter KERNEL_SIZE      = 9,
    parameter IN_WIDTH         = 32,
    parameter ACT_SIZE         = 24,
    parameter WEIGHT_SIZE      = 16,
    parameter PARTIAL_WIDTH    = 48,

    parameter OUT_CHANNELS     = 32,
    parameter OUT_WIDTH        = 32,

    parameter KERNEL_WINDOW_SIZE = 5,
    parameter ONLY_POOL3_WINDOWS = 1,
    parameter ACT_SHIFT          = 0
)(
    input  wire clk,
    input  wire rst,

    // input dari FIFO setelah pool2
    input  wire valid_in,
    output wire ready_out,
    input  wire [IN_CHANNELS*IN_WIDTH-1:0] din,

    // ready dari dense block
    input  wire ready_in,

    // output pool3 / flatten 32 data
    output wire valid_out,
    output wire [OUT_CHANNELS*OUT_WIDTH-1:0] dout,

    // debug opsional
    output wire conv3_busy,
    output wire [5:0] conv3_launch_step,
    output wire [5:0] conv3_collect_step
);

    // ========================================================
    // Kernel generator conv3: 3x3x16
    // ========================================================
    wire kernel_valid;
    wire conv3_ready;
    wire [IN_CHANNELS*KERNEL_SIZE*IN_WIDTH-1:0] kernel_dout;

    conv3_fifo_shift_register_kernel #(
        .WINDOW_SIZE(KERNEL_WINDOW_SIZE),
        .DATA_SIZE(IN_WIDTH),
        .CHANNELS(IN_CHANNELS),
        .ONLY_POOL3_WINDOWS(ONLY_POOL3_WINDOWS)
    ) u_conv3_kernel (
        .clk(clk),
        .rst(rst),

        .valid_in(valid_in),
        .ready_out(ready_out),

        .ready_in(conv3_ready),

        .din(din),

        .valid_out(kernel_valid),
        .dout(kernel_dout)
    );

    // ========================================================
    // Conv3 time-mux: 16 input channel -> 32 output channel
    // ========================================================
    wire conv3_valid;
    wire pool3_ready;
    wire [OUT_CHANNELS*OUT_WIDTH-1:0] conv3_dout;

    conv3_time_mux_32 #(
        .TOTAL_IN_CHANNELS(IN_CHANNELS),
        .GROUP_CHANNELS(GROUP_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .DATA_SIZE(IN_WIDTH),
        .ACT_SIZE(ACT_SIZE),
        .WEIGHT_SIZE(WEIGHT_SIZE),
        .PARTIAL_WIDTH(PARTIAL_WIDTH),
        .OUT_WIDTH(OUT_WIDTH),
        .OUT_CHANNELS(OUT_CHANNELS),
        .ACT_SHIFT(ACT_SHIFT)
    ) u_conv3_time_mux_32 (
        .clk(clk),
        .rst(rst),

        .valid_in(kernel_valid),
        .ready_out(conv3_ready),
        .din(kernel_dout),

        .ready_in(pool3_ready),

        .valid_out(conv3_valid),
        .dout(conv3_dout),

        .busy(conv3_busy),
        .launch_step(conv3_launch_step),
        .collect_step(conv3_collect_step)
    );

    // ========================================================
    // Pool3: max4 untuk 32 channel -> 1x1x32
    // ========================================================
    pool3_max4_32ch #(
        .CHANNELS(OUT_CHANNELS),
        .DATA_SIZE(OUT_WIDTH)
    ) u_pool3_max4 (
        .clk(clk),
        .rst(rst),

        .valid_in(conv3_valid),
        .ready_out(pool3_ready),

        .ready_in(ready_in),

        .din(conv3_dout),

        .valid_out(valid_out),
        .dout(dout)
    );

endmodule