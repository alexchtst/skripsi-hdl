`timescale 1ns / 1ps

module top(
    input  wire clk,
    input  wire rst,
    
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_d,

    output wire        cam_xclk,
    output wire        cam_pwdn,
    output wire        cam_reset,

    output wire        cam_scl,
    inout  wire        cam_sda,
    
    output wire led0,
    output wire led1,
    output wire led2,
    output wire led3
);

    assign cam_pwdn  = 1'b0; // kamera aktif
    assign cam_reset = 1'b1; // keluar dari reset

    reg [1:0] xclk_div;

    always @(posedge clk) begin
        if (rst)
            xclk_div <= 2'b00;
        else
            xclk_div <= xclk_div + 1'b1;
    end
    
    assign cam_xclk = xclk_div[1]; // 100 MHz / 4 = 25 MHz
    
    assign cam_scl = 1'b1;
    assign cam_sda = 1'bz;

    // =========================================================
    // PARAMETER
    // =========================================================
    localparam FIFO_DEPTH          = 32;

    localparam BLOCK2_DATA_SIZE    = 32;
    localparam BLOCK2_ACT_SIZE     = 18;
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

    localparam FC_ACT_SIZE          = 24;
    localparam FC_OUT_WIDTH         = 32;
    localparam FC1_IN_SIZE          = 32;
    localparam FC1_OUT_SIZE         = 16;
    localparam FC2_OUT_SIZE         = 10;

    // =========================================================
    // LED MODE
    //
    // 0 = LED progress pipeline:
    //     led0 = frame_done pernah terjadi
    //     led1 = block1_valid pernah terjadi
    //     led2 = block2_valid pernah terjadi
    //     led3 = dense_valid pernah terjadi
    //
    // 1 = LED class binary setelah prediksi valid:
    //     class 0 = 0000
    //     class 1 = 0001 -> led0
    //     class 2 = 0010 -> led1
    //     class 3 = 0011 -> led0 + led1
    //     class 9 = 1001 -> led3 + led0
    //
    // 2 = AUTO:
    //     sebelum prediksi selesai, LED menunjukkan progress.
    //     setelah prediksi selesai, LED menunjukkan class binary.
    //
    // Saran:
    // Untuk debug pertama pakai 2.
    // Kalau mau lihat pipeline saja, ubah ke 0.
    // Kalau pipeline sudah aman, boleh ubah ke 1.
    // =========================================================
    localparam [1:0] LED_MODE = 2'd2;

    // sama seperti top_tb kamu: tunggu beberapa cycle setelah dense_valid
    localparam [3:0] ARGMAX_WAIT_CYCLES = 4'd5;

    // =========================================================
    // RESET SYNCHRONIZER
    // =========================================================
    (* ASYNC_REG = "TRUE" *) reg rst_ff1 = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_ff2 = 1'b1;

    always @(posedge clk) begin
        rst_ff1 <= rst;
        rst_ff2 <= rst_ff1;
    end

    wire rst_sync;
    assign rst_sync = rst_ff2;

    // =========================================================
    // LOCAL RESET REPLICATION
    // =========================================================
    (* DONT_TOUCH = "TRUE" *) reg rst_frame         = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_stream        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_block1_kernel = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_block1        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_fifo12        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_block2        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_fifo23        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_block3        = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_dense         = 1'b1;
    (* DONT_TOUCH = "TRUE" *) reg rst_argmax        = 1'b1;

    always @(posedge clk) begin
        rst_frame         <= rst_sync;
        rst_stream        <= rst_sync;
        rst_block1_kernel <= rst_sync;
        rst_block1        <= rst_sync;
        rst_fifo12        <= rst_sync;
        rst_block2        <= rst_sync;
        rst_fifo23        <= rst_sync;
        rst_block3        <= rst_sync;
        rst_dense         <= rst_sync;
        rst_argmax        <= rst_sync;
    end

    // =========================================================
    // Frame control
    //
    // RUN_CONTINUOUS = 0:
    //     kirim 1 frame saja setelah reset.
    //
    // RUN_CONTINUOUS = 1:
    //     stream akan jalan terus.
    //
    // Untuk debug image statis seperti top_tb, pakai 0 dulu.
    // Kalau ganti image ROM, reset FPGA / program ulang bitstream.
    // =========================================================
    localparam RUN_CONTINUOUS = 1'b0;

    wire frame_ready;
    wire frame_done;
    reg  frame_sent;

    assign frame_ready = (~rst_frame) && (RUN_CONTINUOUS || (~frame_sent));

    always @(posedge clk) begin
        if (rst_frame) begin
            frame_sent <= 1'b0;
        end
        else if (frame_done) begin
            frame_sent <= 1'b1;
        end
    end

    // =========================================================
    // STREAM 28x28
    // Catatan:
    // Versi ini masih memakai stream_safe_28x28 sebagai sumber image,
    // bukan kamera OV7670 langsung.
    // =========================================================
    wire stream_valid;
    wire stream_ready;
    wire [7:0] pixel_out;

    stream_safe_28x28 u_stream (
        .clk(clk),
        .rst(rst_stream),

        .frame_ready(frame_ready),
        .ready_in(stream_ready),

        .valid_out(stream_valid),
        .pixel_out(pixel_out),

        .x(),
        .y(),

        .frame_start(),
        .frame_done(frame_done)
    );

    // =========================================================
    // BLOCK1 KERNEL 3x3
    // =========================================================
    wire kernel_valid;
    wire block1_ready;

    wire [7:0] k0, k1, k2;
    wire [7:0] k3, k4, k5;
    wire [7:0] k6, k7, k8;

    block1_fifo_shift_register_kernel u_block1_kernel (
        .clk(clk),
        .rst(rst_block1_kernel),

        .valid_in(stream_valid),
        .ready_out(stream_ready),

        .din(pixel_out),

        .valid_out(kernel_valid),
        .ready_in(block1_ready),

        .dout0(k0), .dout1(k1), .dout2(k2),
        .dout3(k3), .dout4(k4), .dout5(k5),
        .dout6(k6), .dout7(k7), .dout8(k8)
    );

    // =========================================================
    // BLOCK1: CONV1 + RELU + POOL1
    // =========================================================
    wire block1_valid;
    wire fifo_ready_to_block1;

    wire [31:0] dout1_ch0, dout1_ch1, dout1_ch2, dout1_ch3;
    wire [31:0] dout1_ch4, dout1_ch5, dout1_ch6, dout1_ch7;

    block1 u_block1 (
        .clk(clk),
        .rst(rst_block1),

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

        .valid_channel(),
        .valid_out(block1_valid)
    );

    wire [255:0] block1_feature_vec;

    assign block1_feature_vec = {
        dout1_ch7, dout1_ch6, dout1_ch5, dout1_ch4,
        dout1_ch3, dout1_ch2, dout1_ch1, dout1_ch0
    };

    // =========================================================
    // FIFO BLOCK1 -> BLOCK2
    // =========================================================
    wire fifo_valid_to_block2;
    wire [255:0] fifo_dout_to_block2;
    wire block2_ready;

    elastic_fifo #(
        .DATA_WIDTH(256),
        .DEPTH(FIFO_DEPTH)
    ) u_fifo_block1_to_block2 (
        .clk(clk),
        .rst(rst_fifo12),

        .valid_in(block1_valid),
        .ready_out(fifo_ready_to_block1),
        .din(block1_feature_vec),

        .valid_out(fifo_valid_to_block2),
        .ready_in(block2_ready),
        .dout(fifo_dout_to_block2),

        .full(),
        .empty(),
        .level()
    );

    // =========================================================
    // BLOCK2 WRAPPER: kernel2 + conv2 + pool2
    // =========================================================
    wire block2_valid;
    wire fifo_ready_to_block2;
    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] block2_dout;

    block2 #(
        .IN_CHANNELS(BLOCK2_CHANNELS),
        .KERNEL_SIZE(BLOCK2_TAPS),
        .IN_WIDTH(BLOCK2_DATA_SIZE),
        .ACT_SIZE(BLOCK2_ACT_SIZE),
        .WEIGHT_SIZE(16),

        .OUT_CHANNELS(CONV2_OUT_CHANNELS),
        .OUT_WIDTH(CONV2_OUT_WIDTH),

        .KERNEL_WINDOW_SIZE(13),
        .POOL_WINDOW_SIZE(11),
        .POOL_TOTAL_WINDOW(5),
        .ACT_SHIFT(0)
    ) u_block2 (
        .clk(clk),
        .rst(rst_block2),

        .valid_in(fifo_valid_to_block2),
        .ready_out(block2_ready),
        .din(fifo_dout_to_block2),

        .ready_in(fifo_ready_to_block2),

        .valid_out(block2_valid),
        .dout(block2_dout),

        .conv2_busy(),
        .conv2_launch_channel(),
        .conv2_collected_channel()
    );

    // =========================================================
    // FIFO BLOCK2 / POOL2 -> BLOCK3
    // =========================================================
    wire fifo_valid_to_block3;
    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] fifo_dout_to_block3;
    wire block3_ready;

    elastic_fifo #(
        .DATA_WIDTH(CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH),
        .DEPTH(POOL2_TO_CONV3_FIFO_DEPTH)
    ) u_fifo_block2_to_block3 (
        .clk(clk),
        .rst(rst_fifo23),

        .valid_in(block2_valid),
        .ready_out(fifo_ready_to_block2),
        .din(block2_dout),

        .valid_out(fifo_valid_to_block3),
        .ready_in(block3_ready),
        .dout(fifo_dout_to_block3),

        .full(),
        .empty(),
        .level()
    );

    // =========================================================
    // BLOCK3 WRAPPER: kernel3 + conv3 + pool3
    // =========================================================
    wire block3_valid;
    wire dense_ready;
    wire [CONV3_OUT_CHANNELS*CONV3_OUT_WIDTH-1:0] block3_dout;

    block3 #(
        .IN_CHANNELS(CONV3_IN_CHANNELS),
        .GROUP_CHANNELS(CONV3_GROUP_CHANNELS),
        .KERNEL_SIZE(9),
        .IN_WIDTH(CONV3_DATA_SIZE),
        .ACT_SIZE(CONV3_ACT_SIZE),
        .WEIGHT_SIZE(16),
        .PARTIAL_WIDTH(48),

        .OUT_CHANNELS(CONV3_OUT_CHANNELS),
        .OUT_WIDTH(CONV3_OUT_WIDTH),

        .KERNEL_WINDOW_SIZE(5),
        .ONLY_POOL3_WINDOWS(1),
        .ACT_SHIFT(0)
    ) u_block3 (
        .clk(clk),
        .rst(rst_block3),

        .valid_in(fifo_valid_to_block3),
        .ready_out(block3_ready),
        .din(fifo_dout_to_block3),

        .ready_in(dense_ready),

        .valid_out(block3_valid),
        .dout(block3_dout),

        .conv3_busy(),
        .conv3_launch_step(),
        .conv3_collect_step()
    );

    // =========================================================
    // DENSE BLOCK: FC1 + FC2
    //
    // PENTING:
    // FC2_RELU saya ubah menjadi 0.
    // Untuk klasifikasi, output FC2 sebaiknya berupa skor/logit mentah.
    // Argmax membandingkan skor mentah antar class.
    // =========================================================
    wire dense_valid;
    wire [FC2_OUT_SIZE*FC_OUT_WIDTH-1:0] dense_dout;

    dense_block #(
        .IN_WIDTH(CONV3_OUT_WIDTH),
        .ACT_SIZE(FC_ACT_SIZE),
        .WEIGHT_SIZE(16),
        .BIAS_SIZE(32),
        .ACC_WIDTH(64),

        .FC1_IN(FC1_IN_SIZE),
        .FC1_OUT(FC1_OUT_SIZE),
        .FC2_OUT(FC2_OUT_SIZE),
        .OUT_WIDTH(FC_OUT_WIDTH),

        .INPUT_SHIFT(0),
        .FC1_SHIFT(14),
        .FC2_SHIFT(14),
        .FC2_RELU(0)
    ) u_dense_block (
        .clk(clk),
        .rst(rst_dense),

        .valid_in(block3_valid),
        .ready_out(dense_ready),
        .din(block3_dout),

        .ready_in(1'b1),

        .valid_out(dense_valid),
        .dout(dense_dout),

        .busy(),
        .fc1_neuron_dbg(),
        .fc2_class_dbg()
    );

    // =========================================================
    // ARGMAX FC2 OUTPUT
    // =========================================================
    wire [3:0] predicted_class;

    argmax10_u32 #(
        .WORD_WIDTH(FC_OUT_WIDTH),
        .NUM_CLASSES(FC2_OUT_SIZE)
    ) u_argmax10_u32 (
        .clk(clk),
        .rst(rst_argmax),

        .valid_in(dense_valid),
        .din(dense_dout),

        .class_out(predicted_class)
    );

    // =========================================================
    // DEBUG PIPELINE LATCH
    //
    // Karena valid pulse biasanya hanya 1 clock,
    // LED tidak akan kelihatan kalau langsung disambung.
    // Maka setiap valid yang pernah terjadi kita latch.
    // =========================================================
    reg seen_frame_done;
    reg seen_block1;
    reg seen_block2;
    reg seen_block3;
    reg seen_dense;

    always @(posedge clk) begin
        if (rst_sync) begin
            seen_frame_done <= 1'b0;
            seen_block1     <= 1'b0;
            seen_block2     <= 1'b0;
            seen_block3     <= 1'b0;
            seen_dense      <= 1'b0;
        end
        else begin
            if (frame_done)
                seen_frame_done <= 1'b1;

            if (block1_valid)
                seen_block1 <= 1'b1;

            if (block2_valid)
                seen_block2 <= 1'b1;

            if (block3_valid)
                seen_block3 <= 1'b1;

            if (dense_valid)
                seen_dense <= 1'b1;
        end
    end

    // =========================================================
    // DENSE_VALID RISING EDGE DETECTOR
    // =========================================================
    reg dense_valid_d;

    always @(posedge clk) begin
        if (rst_argmax)
            dense_valid_d <= 1'b0;
        else
            dense_valid_d <= dense_valid;
    end

    wire dense_valid_rise;
    assign dense_valid_rise = dense_valid & (~dense_valid_d);

    // =========================================================
    // PREDICTION LATCH
    //
    // Ini meniru top_tb:
    // wait dense_valid, lalu tunggu beberapa cycle,
    // baru simpan predicted_class.
    // =========================================================
    reg        argmax_wait_active;
    reg [3:0]  argmax_wait_cnt;
    reg        prediction_valid;
    reg [3:0]  predicted_class_latched;

    always @(posedge clk) begin
        if (rst_argmax) begin
            argmax_wait_active      <= 1'b0;
            argmax_wait_cnt         <= 4'd0;
            prediction_valid        <= 1'b0;
            predicted_class_latched <= 4'd0;
        end
        else begin
            if (dense_valid_rise) begin
                argmax_wait_active <= 1'b1;
                argmax_wait_cnt    <= ARGMAX_WAIT_CYCLES;
                prediction_valid   <= 1'b0;
            end
            else if (argmax_wait_active) begin
                if (argmax_wait_cnt <= 4'd1) begin
                    predicted_class_latched <= predicted_class;
                    prediction_valid        <= 1'b1;
                    argmax_wait_active      <= 1'b0;
                    argmax_wait_cnt         <= 4'd0;
                end
                else begin
                    argmax_wait_cnt <= argmax_wait_cnt - 4'd1;
                end
            end
        end
    end

    // =========================================================
    // LED OUTPUT MUX
    // =========================================================
    wire [3:0] led_progress;
    wire [3:0] led_class_binary;
    wire [3:0] led_auto;
    wire [3:0] led_mux;

    // Mode progress:
    // led0 = frame_done
    // led1 = block1_valid
    // led2 = block2_valid
    // led3 = dense_valid
    assign led_progress = {
        seen_dense,
        seen_block2,
        seen_block1,
        seen_frame_done
    };

    // Mode class binary:
    // sebelum prediction_valid, nyalakan semua LED sebagai tanda "belum final"
    // setelah valid, tampilkan class binary.
    assign led_class_binary = prediction_valid ? predicted_class_latched : 4'b1111;

    // Mode auto:
    // sebelum prediksi selesai = progress
    // setelah prediksi selesai = class binary
    assign led_auto = prediction_valid ? predicted_class_latched : led_progress;

    assign led_mux =
        (LED_MODE == 2'd0) ? led_progress :
        (LED_MODE == 2'd1) ? led_class_binary :
                             led_auto;

    assign led0 = led_mux[0];
    assign led1 = led_mux[1];
    assign led2 = led_mux[2];
    assign led3 = led_mux[3];

endmodule