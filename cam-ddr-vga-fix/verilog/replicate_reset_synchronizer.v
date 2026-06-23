`timescale 1ns / 1ps
`default_nettype none

module replicate_reset_synchronizer (
    input  wire clk,

    // rst_in active-high
    // Bisa dari proc_sys_reset.peripheral_reset[0]
    // atau dari tombol reset yang sudah dibuat active-high.
    input  wire rst_in,

    output reg  rst_frame,
    output reg  rst_stream,
    output reg  rst_double_buffer,

    output reg  rst_block1_kernel,
    output reg  rst_block1,
    output reg  rst_fifo12,

    output reg  rst_block2,
    output reg  rst_fifo23,

    output reg  rst_block3,

    output reg  rst_dense,
    output reg  rst_argmax
);

    // ============================================================
    // RESET SYNCHRONIZER
    // Async assert, sync deassert.
    // Reset langsung aktif saat rst_in naik,
    // tetapi lepas reset disinkronkan ke clk.
    // ============================================================

    (* ASYNC_REG = "TRUE" *) reg rst_ff1 = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_ff2 = 1'b1;

    always @(posedge clk or posedge rst_in) begin
        if (rst_in) begin
            rst_ff1 <= 1'b1;
            rst_ff2 <= 1'b1;
        end else begin
            rst_ff1 <= 1'b0;
            rst_ff2 <= rst_ff1;
        end
    end

    wire rst_sync;
    assign rst_sync = rst_ff2;

    // ============================================================
    // LOCAL RESET REPLICATION
    // Tujuannya mengurangi fanout reset dan membuat reset lebih rapi
    // untuk masing-masing block.
    // ============================================================

    (* DONT_TOUCH = "TRUE" *) reg rst_frame_r         = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_stream_r        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_double_buffer_r = 1'b1;

    (* DONT_TOUCH = "TRUE" *) reg rst_block1_kernel_r = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_block1_r        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_fifo12_r        = 1'b1;

    (* DONT_TOUCH = "TRUE" *) reg rst_block2_r        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_fifo23_r        = 1'b1;

    (* DONT_TOUCH = "TRUE" *) reg rst_block3_r        = 1'b1;

    (* DONT_TOUCH = "TRUE" *) reg rst_dense_r         = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_argmax_r        = 1'b1;

    always @(posedge clk) begin
        rst_frame_r         <= rst_sync;
        rst_stream_r        <= rst_sync;
        rst_double_buffer_r <= rst_sync;

        rst_block1_kernel_r <= rst_sync;
        rst_block1_r        <= rst_sync;
        rst_fifo12_r        <= rst_sync;

        rst_block2_r        <= rst_sync;
        rst_fifo23_r        <= rst_sync;

        rst_block3_r        <= rst_sync;

        rst_dense_r         <= rst_sync;
        rst_argmax_r        <= rst_sync;
    end

    // ============================================================
    // OUTPUT REGISTER
    // ============================================================

    always @(posedge clk) begin
        rst_frame         <= rst_frame_r;
        rst_stream        <= rst_stream_r;
        rst_double_buffer <= rst_double_buffer_r;

        rst_block1_kernel <= rst_block1_kernel_r;
        rst_block1        <= rst_block1_r;
        rst_fifo12        <= rst_fifo12_r;

        rst_block2        <= rst_block2_r;
        rst_fifo23        <= rst_fifo23_r;

        rst_block3        <= rst_block3_r;

        rst_dense         <= rst_dense_r;
        rst_argmax        <= rst_argmax_r;
    end

endmodule

`default_nettype wire