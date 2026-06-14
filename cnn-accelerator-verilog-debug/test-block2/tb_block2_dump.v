`timescale 1ns / 1ps

module tb_block2_dump;

    // ============================================================
    // PARAMETER
    // ============================================================
    localparam FIFO_DEPTH          = 32;

    localparam BLOCK2_DATA_SIZE    = 32;
    localparam BLOCK2_ACT_SIZE     = 24;
    localparam BLOCK2_CHANNELS     = 8;
    localparam BLOCK2_TAPS         = 9;

    localparam CONV2_OUT_CHANNELS  = 16;
    localparam CONV2_OUT_WIDTH     = 32;

    localparam CONV2_TOTAL         = 121; // 11x11
    localparam POOL2_TOTAL         = 25;  // 5x5

    // ============================================================
    // CLOCK / RESET / CONTROL
    // ============================================================
    reg clk = 0;
    reg rst = 1;
    reg frame_ready = 0;

    always #5 clk = ~clk; // 100 MHz

    // ============================================================
    // STREAM 28x28 FROM MEM
    // ============================================================
    wire stream_valid;
    wire stream_ready;
    wire [7:0] pixel_out;

    wire [4:0] x;
    wire [4:0] y;
    wire frame_start;
    wire frame_done;

    stream_safe_28x28_mem_reader uut_stream (
        .clk(clk),
        .rst(rst),

        .frame_ready(frame_ready),
        .ready_in(stream_ready),

        .valid_out(stream_valid),
        .pixel_out(pixel_out),

        .x(x),
        .y(y),

        .frame_start(frame_start),
        .frame_done(frame_done)
    );

    // ============================================================
    // BLOCK1 KERNEL GENERATOR 3x3
    // ============================================================
    wire kernel_valid;
    wire block1_ready;

    wire [7:0]
        k0, k1, k2,
        k3, k4, k5,
        k6, k7, k8;

    block1_fifo_shift_register_kernel #(
        .WINDOW_SIZE(28),
        .DATA_SIZE(8)
    ) uut_kernel (
        .clk(clk),
        .rst(rst),

        .valid_in(stream_valid),
        .ready_out(stream_ready),

        .din(pixel_out),

        .valid_out(kernel_valid),
        .ready_in(block1_ready),

        .dout0(k0), .dout1(k1), .dout2(k2),
        .dout3(k3), .dout4(k4), .dout5(k5),
        .dout6(k6), .dout7(k7), .dout8(k8)
    );

    // ============================================================
    // BLOCK1: 8 CHANNEL CONV + RELU + POOL
    // output block1 = 13x13x8
    // ============================================================
    wire block1_valid;
    wire [7:0] block1_valid_channel;

    wire [31:0]
        dout1_ch0, dout1_ch1, dout1_ch2, dout1_ch3,
        dout1_ch4, dout1_ch5, dout1_ch6, dout1_ch7;

    wire fifo_ready_to_block1;

    block1 uut_block1 (
        .clk(clk),
        .rst(rst),

        .valid_in(kernel_valid),

        .din0(k0), .din1(k1), .din2(k2),
        .din3(k3), .din4(k4), .din5(k5),
        .din6(k6), .din7(k7), .din8(k8),

        .ready_in(fifo_ready_to_block1),
        .ready_out(block1_ready),

        .dout_ch0(dout1_ch0),
        .dout_ch1(dout1_ch1),
        .dout_ch2(dout1_ch2),
        .dout_ch3(dout1_ch3),
        .dout_ch4(dout1_ch4),
        .dout_ch5(dout1_ch5),
        .dout_ch6(dout1_ch6),
        .dout_ch7(dout1_ch7),

        .valid_channel(block1_valid_channel),
        .valid_out(block1_valid)
    );

    // ============================================================
    // PACK BLOCK1 OUTPUT MENJADI 256-BIT
    // bit [31:0]    = ch0
    // bit [63:32]   = ch1
    // ...
    // bit [255:224] = ch7
    // ============================================================
    wire [255:0] block1_feature_vec;

    assign block1_feature_vec = {
        dout1_ch7,
        dout1_ch6,
        dout1_ch5,
        dout1_ch4,
        dout1_ch3,
        dout1_ch2,
        dout1_ch1,
        dout1_ch0
    };

    // ============================================================
    // ELASTIC FIFO ANTARA BLOCK1 DAN BLOCK2
    // ============================================================
    wire fifo_valid_to_block2;
    wire [255:0] fifo_dout;

    wire fifo_full;
    wire fifo_empty;
    wire [$clog2(FIFO_DEPTH+1)-1:0] fifo_level;

    wire block2_kernel_ready;

    elastic_fifo #(
        .DATA_WIDTH(256),
        .DEPTH(FIFO_DEPTH)
    ) fifo_block1_to_block2 (
        .clk(clk),
        .rst(rst),

        .valid_in(block1_valid),
        .ready_out(fifo_ready_to_block1),
        .din(block1_feature_vec),

        .valid_out(fifo_valid_to_block2),
        .ready_in(block2_kernel_ready),
        .dout(fifo_dout),

        .full(fifo_full),
        .empty(fifo_empty),
        .level(fifo_level)
    );

    // ============================================================
    // BLOCK2 KERNEL GENERATOR
    // input  : 13x13x8
    // output : 3x3x8 window
    // ============================================================
    wire block2_window_valid;
    wire block2_fsm_ready;

    wire [BLOCK2_CHANNELS*BLOCK2_TAPS*BLOCK2_DATA_SIZE-1:0] block2_window_dout;

    block2_fifo_shift_register_kernel #(
        .WINDOW_SIZE(13),
        .DATA_SIZE(BLOCK2_DATA_SIZE),
        .CHANNELS(BLOCK2_CHANNELS)
    ) uut_block2_kernel (
        .clk(clk),
        .rst(rst),

        .valid_in(fifo_valid_to_block2),
        .ready_out(block2_kernel_ready),

        .ready_in(block2_fsm_ready),

        .din(fifo_dout),

        .valid_out(block2_window_valid),
        .dout(block2_window_dout)
    );

    // ============================================================
    // CONV2 TIME MUX 16 OUTPUT CHANNEL
    // output conv2 = 11x11x16
    // ============================================================
    wire conv2_downstream_ready;
    wire conv2_valid;
    wire conv2_busy;

    wire [4:0] conv2_launch_channel;
    wire [4:0] conv2_collected_channel;

    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] conv2_dout;

    wire conv2_pool_ready;

    assign conv2_downstream_ready = conv2_pool_ready;

    conv2_time_mux_16 #(
        .IN_CHANNELS(BLOCK2_CHANNELS),
        .KERNEL_SIZE(BLOCK2_TAPS),
        .DATA_SIZE(BLOCK2_DATA_SIZE),
        .ACT_SIZE(BLOCK2_ACT_SIZE),
        .WEIGHT_SIZE(16),
        .OUT_WIDTH(CONV2_OUT_WIDTH),
        .OUT_CHANNELS(CONV2_OUT_CHANNELS),
        .ACT_SHIFT(0)
    ) uut_conv2_time_mux_16 (
        .clk(clk),
        .rst(rst),

        .valid_in(block2_window_valid),
        .ready_out(block2_fsm_ready),
        .din(block2_window_dout),

        .ready_in(conv2_downstream_ready),

        .valid_out(conv2_valid),
        .dout(conv2_dout),

        .busy(conv2_busy),
        .launch_channel(conv2_launch_channel),
        .collected_channel(conv2_collected_channel)
    );

    // ============================================================
    // BLOCK2 MAXPOOL
    // input  : 11x11x16
    // output : 5x5x16
    // ============================================================
    wire conv2_pool_valid;
    wire conv2_pool_final_ready;

    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] conv2_pool_dout;

    // Karena test berhenti di block2, downstream selalu ready.
    assign conv2_pool_final_ready = 1'b1;

    block2_fifo_shift_register_pool_16ch #(
        .WINDOW_SIZE(11),
        .DATA_SIZE(CONV2_OUT_WIDTH),
        .CHANNELS(CONV2_OUT_CHANNELS),
        .TOTAL_WINDOW(5)
    ) uut_conv2_pool (
        .clk(clk),
        .rst(rst),

        .valid_in(conv2_valid),
        .ready_out(conv2_pool_ready),

        .ready_in(conv2_pool_final_ready),

        .din(conv2_dout),

        .valid_out(conv2_pool_valid),
        .dout(conv2_pool_dout)
    );

    // ============================================================
    // OUTPUT FILE
    // ============================================================
    localparam STR_MAX = 256;

    reg [8*STR_MAX-1:0] conv2_file;
    reg [8*STR_MAX-1:0] pool2_file;

    integer fconv2;
    integer fpool2;

    integer conv2_count;
    integer pool2_count;

    initial begin
        if (!$value$plusargs("CONV2_OUT=%s", conv2_file)) begin
            conv2_file = "conv2_out.csv";
        end

        if (!$value$plusargs("POOL2_OUT=%s", pool2_file)) begin
            pool2_file = "pool2_out.csv";
        end

        fconv2 = $fopen(conv2_file, "w");
        fpool2 = $fopen(pool2_file, "w");

        if (fconv2 == 0) begin
            $display("ERROR: cannot open conv2 output file: %0s", conv2_file);
            $finish;
        end

        if (fpool2 == 0) begin
            $display("ERROR: cannot open pool2 output file: %0s", pool2_file);
            $finish;
        end

        $fwrite(fconv2, "ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7,ch8,ch9,ch10,ch11,ch12,ch13,ch14,ch15\n");
        $fwrite(fpool2, "ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7,ch8,ch9,ch10,ch11,ch12,ch13,ch14,ch15\n");
    end

    // ============================================================
    // RESET DAN START 1 FRAME
    // ============================================================
    initial begin
        rst = 1;
        frame_ready = 0;

        conv2_count = 0;
        pool2_count = 0;

        repeat (10) @(posedge clk);
        rst = 0;

        repeat (5) @(posedge clk);

        // start hanya 1 frame
        frame_ready = 1;
        @(posedge clk);
        frame_ready = 0;
    end

    // ============================================================
    // TIMEOUT SAFETY
    // ============================================================
    initial begin
        #2000000;
        $display("TIMEOUT");
        $display("conv2_count = %0d", conv2_count);
        $display("pool2_count = %0d", pool2_count);
        $fclose(fconv2);
        $fclose(fpool2);
        $finish;
    end

    // ============================================================
    // WRITE CONV2 DAN POOL2 KE CSV
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            conv2_count <= 0;
            pool2_count <= 0;
        end else begin

            // ====================================================
            // CONV2 OUTPUT
            // 11x11 = 121 vector
            // setiap vector berisi 16 channel
            // ====================================================
            if (conv2_valid && conv2_downstream_ready && conv2_count < CONV2_TOTAL) begin
                $fwrite(
                    fconv2,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    conv2_dout[0*32  +: 32],
                    conv2_dout[1*32  +: 32],
                    conv2_dout[2*32  +: 32],
                    conv2_dout[3*32  +: 32],
                    conv2_dout[4*32  +: 32],
                    conv2_dout[5*32  +: 32],
                    conv2_dout[6*32  +: 32],
                    conv2_dout[7*32  +: 32],
                    conv2_dout[8*32  +: 32],
                    conv2_dout[9*32  +: 32],
                    conv2_dout[10*32 +: 32],
                    conv2_dout[11*32 +: 32],
                    conv2_dout[12*32 +: 32],
                    conv2_dout[13*32 +: 32],
                    conv2_dout[14*32 +: 32],
                    conv2_dout[15*32 +: 32]
                );

                conv2_count <= conv2_count + 1;
            end

            // ====================================================
            // POOL2 OUTPUT
            // 5x5 = 25 vector
            // setiap vector berisi 16 channel
            // ====================================================
            if (conv2_pool_valid && conv2_pool_final_ready && pool2_count < POOL2_TOTAL) begin
                $fwrite(
                    fpool2,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    conv2_pool_dout[0*32  +: 32],
                    conv2_pool_dout[1*32  +: 32],
                    conv2_pool_dout[2*32  +: 32],
                    conv2_pool_dout[3*32  +: 32],
                    conv2_pool_dout[4*32  +: 32],
                    conv2_pool_dout[5*32  +: 32],
                    conv2_pool_dout[6*32  +: 32],
                    conv2_pool_dout[7*32  +: 32],
                    conv2_pool_dout[8*32  +: 32],
                    conv2_pool_dout[9*32  +: 32],
                    conv2_pool_dout[10*32 +: 32],
                    conv2_pool_dout[11*32 +: 32],
                    conv2_pool_dout[12*32 +: 32],
                    conv2_pool_dout[13*32 +: 32],
                    conv2_pool_dout[14*32 +: 32],
                    conv2_pool_dout[15*32 +: 32]
                );

                pool2_count <= pool2_count + 1;
            end

            // ====================================================
            // FINISH
            // ====================================================
            if (conv2_count >= CONV2_TOTAL && pool2_count >= POOL2_TOTAL) begin
                $display("DONE BLOCK2 DUMP");
                $display("conv2_count = %0d", conv2_count);
                $display("pool2_count = %0d", pool2_count);

                $fclose(fconv2);
                $fclose(fpool2);

                $finish;
            end
        end
    end

endmodule