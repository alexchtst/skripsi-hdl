`timescale 1ns / 1ps

module tb_block3_dump;

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

    localparam POOL2_TO_CONV3_FIFO_DEPTH = 8;

    localparam CONV3_DATA_SIZE      = 32;
    localparam CONV3_ACT_SIZE       = 24;
    localparam CONV3_IN_CHANNELS    = 16;
    localparam CONV3_GROUP_CHANNELS = 8;
    localparam CONV3_OUT_CHANNELS   = 32;
    localparam CONV3_OUT_WIDTH      = 32;

    // Full conv3:
    // input pool2 = 5x5
    // kernel 3x3
    // output conv3 = 3x3 = 9 vector
    localparam CONV3_TOTAL          = 9;

    // Pool3:
    // maxpool 2x2 dari conv3 3x3
    // output = 1x1 = 1 vector
    localparam POOL3_TOTAL          = 1;

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
    // BLOCK1: CONV1 + RELU + POOL1
    // output = 13x13x8
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
    // FIFO BLOCK1 -> BLOCK2
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
    // input  = 13x13x8
    // output = 3x3x8 window
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
    // CONV2 TIME MUX
    // output = 11x11x16
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
    // POOL2
    // input  = 11x11x16
    // output = 5x5x16
    // ============================================================
    wire conv2_pool_valid;
    wire conv2_pool_final_ready;

    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] conv2_pool_dout;

    wire fifo_ready_to_pool2;

    assign conv2_pool_final_ready = fifo_ready_to_pool2;

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
    // FIFO POOL2 -> CONV3
    // ============================================================
    wire fifo_valid_to_conv3;
    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] fifo_pool2_to_conv3_dout;

    wire fifo_pool2_to_conv3_full;
    wire fifo_pool2_to_conv3_empty;
    wire [$clog2(POOL2_TO_CONV3_FIFO_DEPTH+1)-1:0] fifo_pool2_to_conv3_level;

    wire conv3_kernel_ready;

    elastic_fifo #(
        .DATA_WIDTH(CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH),
        .DEPTH(POOL2_TO_CONV3_FIFO_DEPTH)
    ) fifo_pool2_to_conv3 (
        .clk(clk),
        .rst(rst),

        .valid_in(conv2_pool_valid),
        .ready_out(fifo_ready_to_pool2),
        .din(conv2_pool_dout),

        .valid_out(fifo_valid_to_conv3),
        .ready_in(conv3_kernel_ready),
        .dout(fifo_pool2_to_conv3_dout),

        .full(fifo_pool2_to_conv3_full),
        .empty(fifo_pool2_to_conv3_empty),
        .level(fifo_pool2_to_conv3_level)
    );

    // ============================================================
    // CONV3 KERNEL GENERATOR
    // input  = 5x5x16
    // output = full 3x3x16 window
    //
    // PENTING:
    // ONLY_POOL3_WINDOWS = 0
    // supaya conv3 keluar full 9 data.
    // ============================================================
    wire conv3_window_valid;
    wire conv3_fsm_ready;

    wire [CONV3_IN_CHANNELS*9*CONV3_DATA_SIZE-1:0] conv3_window_dout;

    conv3_fifo_shift_register_kernel #(
        .WINDOW_SIZE(5),
        .DATA_SIZE(CONV3_DATA_SIZE),
        .CHANNELS(CONV3_IN_CHANNELS),
        .ONLY_POOL3_WINDOWS(0)
    ) uut_conv3_kernel (
        .clk(clk),
        .rst(rst),

        .valid_in(fifo_valid_to_conv3),
        .ready_out(conv3_kernel_ready),

        .ready_in(conv3_fsm_ready),

        .din(fifo_pool2_to_conv3_dout),

        .valid_out(conv3_window_valid),
        .dout(conv3_window_dout)
    );

    // ============================================================
    // CONV3 TIME MUX 32 OUTPUT CHANNEL
    // output = full 3x3x32 = 9 vector
    // ============================================================
    wire conv3_downstream_ready;
    wire conv3_valid;
    wire conv3_busy;

    wire [5:0] conv3_launch_step;
    wire [5:0] conv3_collect_step;

    wire [CONV3_OUT_CHANNELS*CONV3_OUT_WIDTH-1:0] conv3_dout;

    conv3_time_mux_32 #(
        .TOTAL_IN_CHANNELS(CONV3_IN_CHANNELS),
        .GROUP_CHANNELS(CONV3_GROUP_CHANNELS),
        .KERNEL_SIZE(9),
        .DATA_SIZE(CONV3_DATA_SIZE),
        .ACT_SIZE(CONV3_ACT_SIZE),
        .WEIGHT_SIZE(16),
        .PARTIAL_WIDTH(48),
        .OUT_WIDTH(CONV3_OUT_WIDTH),
        .OUT_CHANNELS(CONV3_OUT_CHANNELS),
        .ACT_SHIFT(0)
    ) uut_conv3_time_mux_32 (
        .clk(clk),
        .rst(rst),

        .valid_in(conv3_window_valid),
        .ready_out(conv3_fsm_ready),
        .din(conv3_window_dout),

        .ready_in(conv3_downstream_ready),

        .valid_out(conv3_valid),
        .dout(conv3_dout),

        .busy(conv3_busy),
        .launch_step(conv3_launch_step),
        .collect_step(conv3_collect_step)
    );

    // ============================================================
    // SELECTOR CONV3 -> POOL3
    //
    // Full conv3 3x3 raster order:
    //
    // idx0 idx1 idx2
    // idx3 idx4 idx5
    // idx6 idx7 idx8
    //
    // Pool3 maxpool 2x2 hanya butuh:
    //
    // idx0 idx1
    // idx3 idx4
    //
    // Jadi yang dikirim ke pool3 hanya idx:
    // 0, 1, 3, 4
    // ============================================================
    wire pool3_ready;

    reg [3:0] conv3_idx;

    wire conv3_selected_for_pool3;

    assign conv3_selected_for_pool3 =
        (conv3_idx == 4'd0) ||
        (conv3_idx == 4'd1) ||
        (conv3_idx == 4'd3) ||
        (conv3_idx == 4'd4);

    // Kalau data conv3 sedang dibutuhkan pool3, ready ikut pool3_ready.
    // Kalau data conv3 tidak dibutuhkan pool3, langsung consume dan buang.
    assign conv3_downstream_ready =
        conv3_selected_for_pool3 ? pool3_ready : 1'b1;

    wire conv3_fire;
    assign conv3_fire = conv3_valid && conv3_downstream_ready;

    wire conv3_valid_to_pool3;
    assign conv3_valid_to_pool3 = conv3_valid && conv3_selected_for_pool3;

    always @(posedge clk) begin
        if (rst) begin
            conv3_idx <= 0;
        end else begin
            if (conv3_fire) begin
                if (conv3_idx == 4'd8)
                    conv3_idx <= 0;
                else
                    conv3_idx <= conv3_idx + 1'b1;
            end
        end
    end

    // ============================================================
    // POOL3 MAX4
    // input  = hanya conv3 idx 0,1,3,4
    // output = 1x1x32
    // ============================================================
    wire pool3_valid;
    wire pool3_final_ready;

    wire [CONV3_OUT_CHANNELS*CONV3_OUT_WIDTH-1:0] pool3_dout;

    // Karena test berhenti di block3, downstream selalu ready.
    assign pool3_final_ready = 1'b1;

    pool3_max4_32ch #(
        .CHANNELS(CONV3_OUT_CHANNELS),
        .DATA_SIZE(CONV3_OUT_WIDTH)
    ) uut_pool3_max4 (
        .clk(clk),
        .rst(rst),

        .valid_in(conv3_valid_to_pool3),
        .ready_out(pool3_ready),

        .ready_in(pool3_final_ready),

        .din(conv3_dout),

        .valid_out(pool3_valid),
        .dout(pool3_dout)
    );

    // ============================================================
    // CSV FILE
    // ============================================================
    localparam STR_MAX = 256;

    reg [8*STR_MAX-1:0] conv3_file;
    reg [8*STR_MAX-1:0] pool3_file;

    integer fconv3;
    integer fpool3;

    integer conv3_count;
    integer pool3_count;

    // ============================================================
    // TASK WRITE 32 CHANNEL CSV
    // ============================================================
    task write_32ch_csv;
        input integer fd;
        input [CONV3_OUT_CHANNELS*CONV3_OUT_WIDTH-1:0] vec;

        integer ch;
        begin
            for (ch = 0; ch < CONV3_OUT_CHANNELS; ch = ch + 1) begin
                if (ch == CONV3_OUT_CHANNELS-1) begin
                    $fwrite(fd, "%0d\n", vec[ch*32 +: 32]);
                end else begin
                    $fwrite(fd, "%0d,", vec[ch*32 +: 32]);
                end
            end
        end
    endtask

    // ============================================================
    // OPEN FILE
    // ============================================================
    initial begin
        if (!$value$plusargs("CONV3_OUT=%s", conv3_file)) begin
            conv3_file = "conv3_out.csv";
        end

        if (!$value$plusargs("POOL3_OUT=%s", pool3_file)) begin
            pool3_file = "pool3_out.csv";
        end

        fconv3 = $fopen(conv3_file, "w");
        fpool3 = $fopen(pool3_file, "w");

        if (fconv3 == 0) begin
            $display("ERROR: cannot open conv3 output file: %0s", conv3_file);
            $finish;
        end

        if (fpool3 == 0) begin
            $display("ERROR: cannot open pool3 output file: %0s", pool3_file);
            $finish;
        end

        $fwrite(fconv3, "ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7,ch8,ch9,ch10,ch11,ch12,ch13,ch14,ch15,ch16,ch17,ch18,ch19,ch20,ch21,ch22,ch23,ch24,ch25,ch26,ch27,ch28,ch29,ch30,ch31\n");
        $fwrite(fpool3, "ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7,ch8,ch9,ch10,ch11,ch12,ch13,ch14,ch15,ch16,ch17,ch18,ch19,ch20,ch21,ch22,ch23,ch24,ch25,ch26,ch27,ch28,ch29,ch30,ch31\n");
    end

    // ============================================================
    // RESET DAN START 1 FRAME
    // ============================================================
    initial begin
        rst = 1;
        frame_ready = 0;

        conv3_count = 0;
        pool3_count = 0;

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
        #5000000;
        $display("TIMEOUT BLOCK3");
        $display("conv3_count = %0d", conv3_count);
        $display("pool3_count = %0d", pool3_count);
        $display("conv3_idx   = %0d", conv3_idx);
        $fclose(fconv3);
        $fclose(fpool3);
        $finish;
    end

    // ============================================================
    // WRITE CONV3 DAN POOL3
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            conv3_count <= 0;
            pool3_count <= 0;
        end else begin

            // ====================================================
            // CONV3 OUT
            // Full 3x3 = 9 vector x 32 channel
            //
            // Pakai conv3_fire supaya data ditulis hanya saat
            // output conv3 benar-benar diterima.
            // ====================================================
            if (conv3_fire && conv3_count < CONV3_TOTAL) begin
                write_32ch_csv(fconv3, conv3_dout);
                conv3_count <= conv3_count + 1;
            end

            // ====================================================
            // POOL3 OUT
            // 1 vector x 32 channel
            // ====================================================
            if (pool3_valid && pool3_final_ready && pool3_count < POOL3_TOTAL) begin
                write_32ch_csv(fpool3, pool3_dout);
                pool3_count <= pool3_count + 1;
            end

            // ====================================================
            // FINISH
            // ====================================================
            if (conv3_count >= CONV3_TOTAL && pool3_count >= POOL3_TOTAL) begin
                $display("DONE BLOCK3 DUMP");
                $display("conv3_count = %0d", conv3_count);
                $display("pool3_count = %0d", pool3_count);
                $display("conv3_idx   = %0d", conv3_idx);

                $fclose(fconv3);
                $fclose(fpool3);

                $finish;
            end
        end
    end

endmodule