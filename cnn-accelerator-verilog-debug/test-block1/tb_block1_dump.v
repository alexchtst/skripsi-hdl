`timescale 1ns / 1ps

module tb_block1_dump;

    // ============================================================
    // CLOCK RESET
    // ============================================================
    reg clk = 0;
    reg rst = 1;

    always #5 clk = ~clk; // 100 MHz

    // ============================================================
    // STREAM 28x28
    // ============================================================
    reg frame_ready = 0;

    wire stream_valid;
    wire stream_ready;
    wire [7:0] pixel_out;
    wire [4:0] sx;
    wire [4:0] sy;
    wire frame_start;
    wire frame_done;

    stream_safe_28x28_mem_reader u_stream (
        .clk(clk),
        .rst(rst),

        .frame_ready(frame_ready),
        .ready_in(stream_ready),

        .valid_out(stream_valid),
        .pixel_out(pixel_out),
        .x(sx),
        .y(sy),
        .frame_start(frame_start),
        .frame_done(frame_done)
    );

    // ============================================================
    // KERNEL WINDOW 3x3
    // ============================================================
    wire kernel_valid;
    wire block_ready;

    wire [7:0]
        k0, k1, k2,
        k3, k4, k5,
        k6, k7, k8;

    block1_fifo_shift_register_kernel #(
        .WINDOW_SIZE(28),
        .DATA_SIZE(8)
    ) u_kernel (
        .clk(clk),
        .rst(rst),

        .valid_in(stream_valid),
        .ready_out(stream_ready),
        .din(pixel_out),

        .valid_out(kernel_valid),
        .ready_in(block_ready),

        .dout0(k0), .dout1(k1), .dout2(k2),
        .dout3(k3), .dout4(k4), .dout5(k5),
        .dout6(k6), .dout7(k7), .dout8(k8)
    );

    // ============================================================
    // BLOCK1: CONV + RELU + POOL
    // ============================================================
    wire [31:0]
        pool_ch0, pool_ch1, pool_ch2, pool_ch3,
        pool_ch4, pool_ch5, pool_ch6, pool_ch7;

    wire [7:0] pool_valid_channel;
    wire pool_valid_out;

    block1 u_block1 (
        .clk(clk),
        .rst(rst),

        .valid_in(kernel_valid),

        .din0(k0), .din1(k1), .din2(k2),
        .din3(k3), .din4(k4), .din5(k5),
        .din6(k6), .din7(k7), .din8(k8),

        .ready_in(1'b1),
        .ready_out(block_ready),

        .dout_ch0(pool_ch0),
        .dout_ch1(pool_ch1),
        .dout_ch2(pool_ch2),
        .dout_ch3(pool_ch3),
        .dout_ch4(pool_ch4),
        .dout_ch5(pool_ch5),
        .dout_ch6(pool_ch6),
        .dout_ch7(pool_ch7),

        .valid_channel(pool_valid_channel),
        .valid_out(pool_valid_out)
    );

    // ============================================================
    // AMBIL OUTPUT CONV INTERNAL
    // Ini hanya untuk simulasi/debug.
    // ============================================================
    wire [31:0] conv_ch0 = u_block1.ch0.mac_dout;
    wire [31:0] conv_ch1 = u_block1.ch1.mac_dout;
    wire [31:0] conv_ch2 = u_block1.ch2.mac_dout;
    wire [31:0] conv_ch3 = u_block1.ch3.mac_dout;
    wire [31:0] conv_ch4 = u_block1.ch4.mac_dout;
    wire [31:0] conv_ch5 = u_block1.ch5.mac_dout;
    wire [31:0] conv_ch6 = u_block1.ch6.mac_dout;
    wire [31:0] conv_ch7 = u_block1.ch7.mac_dout;

    wire conv_valid_out =
        u_block1.ch0.mac_valid &
        u_block1.ch1.mac_valid &
        u_block1.ch2.mac_valid &
        u_block1.ch3.mac_valid &
        u_block1.ch4.mac_valid &
        u_block1.ch5.mac_valid &
        u_block1.ch6.mac_valid &
        u_block1.ch7.mac_valid;

    // ============================================================
    // OUTPUT FILE
    // ============================================================
    localparam STR_MAX = 256;

    reg [8*STR_MAX-1:0] conv_file;
    reg [8*STR_MAX-1:0] pool_file;

    integer fconv;
    integer fpool;

    integer conv_count;
    integer pool_count;

    initial begin
        if (!$value$plusargs("CONV_OUT=%s", conv_file)) begin
            conv_file = "conv_out.csv";
        end

        if (!$value$plusargs("POOL_OUT=%s", pool_file)) begin
            pool_file = "pool_out.csv";
        end

        fconv = $fopen(conv_file, "w");
        fpool = $fopen(pool_file, "w");

        if (fconv == 0) begin
            $display("ERROR: cannot open conv output file");
            $finish;
        end

        if (fpool == 0) begin
            $display("ERROR: cannot open pool output file");
            $finish;
        end

        $fwrite(fconv, "ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7\n");
        $fwrite(fpool, "ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7\n");
    end

    // ============================================================
    // RESET DAN START 1 FRAME
    // ============================================================
    initial begin
        rst = 1;
        frame_ready = 0;

        repeat (10) @(posedge clk);
        rst = 0;

        repeat (5) @(posedge clk);

        // start hanya 1 frame
        frame_ready = 1;
        @(posedge clk);
        frame_ready = 0;
    end

    // ============================================================
    // WRITE CONV 26x26 DAN POOL 13x13
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            conv_count <= 0;
            pool_count <= 0;
        end else begin

            // ====================================================
            // CONV OUTPUT: 26x26 = 676 data
            // ====================================================
            if (conv_valid_out && conv_count < 676) begin
                $fwrite(
                    fconv,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    conv_ch0, conv_ch1, conv_ch2, conv_ch3,
                    conv_ch4, conv_ch5, conv_ch6, conv_ch7
                );

                conv_count <= conv_count + 1;
            end

            // ====================================================
            // POOL OUTPUT: 13x13 = 169 data
            // ====================================================
            if (pool_valid_out && pool_count < 169) begin
                $fwrite(
                    fpool,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    pool_ch0, pool_ch1, pool_ch2, pool_ch3,
                    pool_ch4, pool_ch5, pool_ch6, pool_ch7
                );

                pool_count <= pool_count + 1;
            end

            // selesai jika conv dan pool sudah lengkap
            if (conv_count == 676 && pool_count == 169) begin
                $display("DONE");
                $display("conv_count = %0d", conv_count);
                $display("pool_count = %0d", pool_count);

                $fclose(fconv);
                $fclose(fpool);

                $finish;
            end
        end
    end

endmodule