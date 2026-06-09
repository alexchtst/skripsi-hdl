`timescale 1ns / 1ps

module test_top_dense;

    // =========================================================
    // PARAMETER
    // =========================================================
    localparam FIFO_DEPTH          = 32;

    localparam BLOCK2_DATA_SIZE    = 32;
    localparam BLOCK2_ACT_SIZE     = 24;   // ubah ke 18 kalau ingin input MAC conv2 18-bit
    localparam BLOCK2_CHANNELS     = 8;
    localparam BLOCK2_TAPS         = 9;

    localparam CONV2_OUT_CHANNELS  = 16;
    localparam CONV2_OUT_WIDTH     = 32;

    localparam POOL2_TO_CONV3_FIFO_DEPTH = 8;

    localparam CONV3_DATA_SIZE     = 32;
    localparam CONV3_ACT_SIZE      = 24;
    localparam CONV3_IN_CHANNELS   = 16;
    localparam CONV3_GROUP_CHANNELS = 8;
    localparam CONV3_OUT_CHANNELS  = 32;
    localparam CONV3_OUT_WIDTH     = 32;

    localparam FC_ACT_SIZE         = 24;
    localparam FC_OUT_WIDTH        = 32;
    localparam FC1_IN_SIZE         = 32;
    localparam FC1_OUT_SIZE        = 16;
    localparam FC2_OUT_SIZE        = 10;

    // =========================================================
    // CLOCK / RESET / CONTROL
    // =========================================================
    reg clk;
    reg rst;
    reg frame_ready;

    // =========================================================
    // STREAM
    // =========================================================
    wire stream_valid;
    wire stream_ready;
    wire [7:0] pixel_out;

    wire [4:0] x;
    wire [4:0] y;
    wire frame_start;
    wire frame_done;

    stream_safe_28x28 uut_stream (
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

    // =========================================================
    // BLOCK1 KERNEL GENERATOR 3x3
    // =========================================================
    wire kernel_valid;
    wire block1_ready;

    wire [7:0]
        k0, k1, k2,
        k3, k4, k5,
        k6, k7, k8;

    block1_fifo_shift_register_kernel uut_kernel (
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

    // =========================================================
    // BLOCK1: 8 CHANNEL CONV + RELU + POOL
    // =========================================================
    wire block1_valid;
    wire [7:0] block1_valid_channel;

    // Setelah ReLU + Pool, data dianggap unsigned
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

        // block1 melihat FIFO sebagai downstream
        .ready_in(fifo_ready_to_block1),

        // ready balik ke kernel block1
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

    // =========================================================
    // PACK 8 CHANNEL BLOCK1 OUTPUT MENJADI 256-BIT
    // urutan:
    // bit [31:0]    = ch0
    // bit [63:32]   = ch1
    // ...
    // bit [255:224] = ch7
    // =========================================================
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

    // =========================================================
    // ELASTIC FIFO ANTARA BLOCK1 DAN BLOCK2
    // =========================================================
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

        // input side: dari block1
        .valid_in(block1_valid),
        .ready_out(fifo_ready_to_block1),
        .din(block1_feature_vec),

        // output side: ke block2_fifo_shift_register_kernel
        .valid_out(fifo_valid_to_block2),
        .ready_in(block2_kernel_ready),
        .dout(fifo_dout),

        // debug
        .full(fifo_full),
        .empty(fifo_empty),
        .level(fifo_level)
    );

    // =========================================================
    // BLOCK2 KERNEL GENERATOR 3x3x8
    // input  : 256-bit feature vector dari FIFO
    // output : 9 tap x 8 channel x 32-bit = 2304-bit
    // =========================================================
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

        // ready dari conv2_time_mux_16
        .ready_in(block2_fsm_ready),

        .din(fifo_dout),

        .valid_out(block2_window_valid),
        .dout(block2_window_dout)
    );

    // =========================================================
    // CONV2 TIME MULTIPLEX 16 OUTPUT CHANNEL
    // 1 conv2_partial = 72 MAC
    // dipakai bergantian untuk output channel 0..15
    // =========================================================
    wire conv2_downstream_ready;
    wire conv2_valid;
    wire conv2_busy;

    wire [4:0] conv2_launch_channel;
    wire [4:0] conv2_collected_channel;

    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] conv2_dout;

    // ready dari maxpool block2
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

        // input dari block2_fifo_shift_register_kernel
        .valid_in(block2_window_valid),
        .ready_out(block2_fsm_ready),
        .din(block2_window_dout),

        // ready dari block setelah conv2, yaitu maxpool conv2
        .ready_in(conv2_downstream_ready),

        // output 16 channel hasil conv2 + ReLU
        .valid_out(conv2_valid),
        .dout(conv2_dout),

        // debug
        .busy(conv2_busy),
        .launch_channel(conv2_launch_channel),
        .collected_channel(conv2_collected_channel)
    );

    // =========================================================
    // BLOCK2 MAXPOOL 2x2 STRIDE 2
    // input  : 11x11x16 dari conv2_time_mux_16
    // output : 5x5x16
    // =========================================================
    wire conv2_pool_valid;
    wire conv2_pool_final_ready;

    wire [CONV2_OUT_CHANNELS*CONV2_OUT_WIDTH-1:0] conv2_pool_dout;

    // ready dari FIFO pool2 -> conv3
    // pool2 hanya mengeluarkan data kalau FIFO setelahnya masih bisa menerima
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



    // =========================================================
    // ELASTIC FIFO ANTARA POOL2 DAN BLOCK3 / CONV3
    // input/output vector = 16 channel x 32-bit = 512-bit
    // =========================================================
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

        // input side: dari pool2
        .valid_in(conv2_pool_valid),
        .ready_out(fifo_ready_to_pool2),
        .din(conv2_pool_dout),

        // output side: ke conv3 kernel generator
        .valid_out(fifo_valid_to_conv3),
        .ready_in(conv3_kernel_ready),
        .dout(fifo_pool2_to_conv3_dout),

        .full(fifo_pool2_to_conv3_full),
        .empty(fifo_pool2_to_conv3_empty),
        .level(fifo_pool2_to_conv3_level)
    );

    // =========================================================
    // BLOCK3 / CONV3 KERNEL GENERATOR
    // input  : 5x5x16 dari pool2
    // output : window 3x3x16
    // Catatan: ONLY_POOL3_WINDOWS=1 berarti hanya window yang dipakai
    //          pool3 2x2 yang diproses, yaitu 4 window pertama.
    // =========================================================
    wire conv3_window_valid;
    wire conv3_fsm_ready;

    wire [CONV3_IN_CHANNELS*9*CONV3_DATA_SIZE-1:0] conv3_window_dout;

    conv3_fifo_shift_register_kernel #(
        .WINDOW_SIZE(5),
        .DATA_SIZE(CONV3_DATA_SIZE),
        .CHANNELS(CONV3_IN_CHANNELS),
        .ONLY_POOL3_WINDOWS(1)
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

    // =========================================================
    // CONV3 TIME MULTIPLEX 32 OUTPUT CHANNEL
    // 72 DSP tetap dipakai:
    // 9 tap x 8 input channel per group.
    // Karena input conv3 ada 16 channel, setiap output channel butuh 2 group.
    // Total per window = 32 output channel x 2 group = 64 launch.
    // =========================================================
    wire conv3_downstream_ready;
    wire conv3_valid;
    wire conv3_busy;
    wire [5:0] conv3_launch_step;
    wire [5:0] conv3_collect_step;

    wire [CONV3_OUT_CHANNELS*CONV3_OUT_WIDTH-1:0] conv3_dout;

    wire pool3_ready;
    assign conv3_downstream_ready = pool3_ready;

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

    // =========================================================
    // POOL3: max dari 4 output conv3 yang dipakai oleh pooling 2x2
    // output akhir pool3 = 1x1x32
    // =========================================================
    wire pool3_valid;
    wire pool3_final_ready;
    wire [CONV3_OUT_CHANNELS*CONV3_OUT_WIDTH-1:0] pool3_dout;

    // Pool3 hanya boleh mengeluarkan hasil jika FC engine siap menerima.
    // Ini menjaga backpressure sampai ke conv3/pool2 jika FC sedang busy.
    wire fc_ready;
    assign pool3_final_ready = fc_ready;

    pool3_max4_32ch #(
        .CHANNELS(CONV3_OUT_CHANNELS),
        .DATA_SIZE(CONV3_OUT_WIDTH)
    ) uut_pool3_max4 (
        .clk(clk),
        .rst(rst),

        .valid_in(conv3_valid),
        .ready_out(pool3_ready),
        .ready_in(pool3_final_ready),

        .din(conv3_dout),

        .valid_out(pool3_valid),
        .dout(pool3_dout)
    );


    // =========================================================
    // FC1 + FC2 DENSE LAYERS, SHARED 2 DSP
    // input  : pool3_dout = 1x1x32
    // FC1    : 32 -> 16 + ReLU
    // FC2    : 16 -> 10 output + ReLU
    // output : 10 class/logit packed
    // =========================================================
    wire fc_valid;
    wire fc_busy;
    wire [FC2_OUT_SIZE*FC_OUT_WIDTH-1:0] fc_dout;
    wire [4:0] fc1_neuron_dbg;
    wire [4:0] fc2_class_dbg;

    fc1_fc2_2dsp #(
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

        // set 0 kalau FC2 di Python adalah logits mentah tanpa ReLU
        .FC2_RELU(1)
    ) uut_fc1_fc2_2dsp (
        .clk(clk),
        .rst(rst),

        .valid_in(pool3_valid),
        .ready_out(fc_ready),

        // output final selalu diterima oleh testbench
        .ready_in(1'b1),

        .din(pool3_dout),

        .valid_out(fc_valid),
        .dout(fc_dout),

        .busy(fc_busy),
        .fc1_neuron_dbg(fc1_neuron_dbg),
        .fc2_class_dbg(fc2_class_dbg)
    );

    // =========================================================
    // UNPACK FINAL FC2 OUTPUT UNTUK DEBUG PYTHON
    // =========================================================
    wire [31:0] fc_out0 = fc_dout[0*32 +: 32];
    wire [31:0] fc_out1 = fc_dout[1*32 +: 32];
    wire [31:0] fc_out2 = fc_dout[2*32 +: 32];
    wire [31:0] fc_out3 = fc_dout[3*32 +: 32];
    wire [31:0] fc_out4 = fc_dout[4*32 +: 32];
    wire [31:0] fc_out5 = fc_dout[5*32 +: 32];
    wire [31:0] fc_out6 = fc_dout[6*32 +: 32];
    wire [31:0] fc_out7 = fc_dout[7*32 +: 32];
    wire [31:0] fc_out8 = fc_dout[8*32 +: 32];
    wire [31:0] fc_out9 = fc_dout[9*32 +: 32];

    // =========================================================
    // DEBUG UNPACK CONV3 DAN POOL3
    // =========================================================
    wire [31:0] conv3_ch0  = conv3_dout[0*32  +: 32];
    wire [31:0] conv3_ch1  = conv3_dout[1*32  +: 32];
    wire [31:0] conv3_ch2  = conv3_dout[2*32  +: 32];
    wire [31:0] conv3_ch3  = conv3_dout[3*32  +: 32];
    wire [31:0] conv3_ch4  = conv3_dout[4*32  +: 32];
    wire [31:0] conv3_ch5  = conv3_dout[5*32  +: 32];
    wire [31:0] conv3_ch6  = conv3_dout[6*32  +: 32];
    wire [31:0] conv3_ch7  = conv3_dout[7*32  +: 32];
    wire [31:0] conv3_ch8  = conv3_dout[8*32  +: 32];
    wire [31:0] conv3_ch9  = conv3_dout[9*32  +: 32];
    wire [31:0] conv3_ch10 = conv3_dout[10*32 +: 32];
    wire [31:0] conv3_ch11 = conv3_dout[11*32 +: 32];
    wire [31:0] conv3_ch12 = conv3_dout[12*32 +: 32];
    wire [31:0] conv3_ch13 = conv3_dout[13*32 +: 32];
    wire [31:0] conv3_ch14 = conv3_dout[14*32 +: 32];
    wire [31:0] conv3_ch15 = conv3_dout[15*32 +: 32];
    wire [31:0] conv3_ch16 = conv3_dout[16*32 +: 32];
    wire [31:0] conv3_ch17 = conv3_dout[17*32 +: 32];
    wire [31:0] conv3_ch18 = conv3_dout[18*32 +: 32];
    wire [31:0] conv3_ch19 = conv3_dout[19*32 +: 32];
    wire [31:0] conv3_ch20 = conv3_dout[20*32 +: 32];
    wire [31:0] conv3_ch21 = conv3_dout[21*32 +: 32];
    wire [31:0] conv3_ch22 = conv3_dout[22*32 +: 32];
    wire [31:0] conv3_ch23 = conv3_dout[23*32 +: 32];
    wire [31:0] conv3_ch24 = conv3_dout[24*32 +: 32];
    wire [31:0] conv3_ch25 = conv3_dout[25*32 +: 32];
    wire [31:0] conv3_ch26 = conv3_dout[26*32 +: 32];
    wire [31:0] conv3_ch27 = conv3_dout[27*32 +: 32];
    wire [31:0] conv3_ch28 = conv3_dout[28*32 +: 32];
    wire [31:0] conv3_ch29 = conv3_dout[29*32 +: 32];
    wire [31:0] conv3_ch30 = conv3_dout[30*32 +: 32];
    wire [31:0] conv3_ch31 = conv3_dout[31*32 +: 32];

    wire [31:0] pool3_ch0  = pool3_dout[0*32  +: 32];
    wire [31:0] pool3_ch1  = pool3_dout[1*32  +: 32];
    wire [31:0] pool3_ch2  = pool3_dout[2*32  +: 32];
    wire [31:0] pool3_ch3  = pool3_dout[3*32  +: 32];
    wire [31:0] pool3_ch4  = pool3_dout[4*32  +: 32];
    wire [31:0] pool3_ch5  = pool3_dout[5*32  +: 32];
    wire [31:0] pool3_ch6  = pool3_dout[6*32  +: 32];
    wire [31:0] pool3_ch7  = pool3_dout[7*32  +: 32];
    wire [31:0] pool3_ch8  = pool3_dout[8*32  +: 32];
    wire [31:0] pool3_ch9  = pool3_dout[9*32  +: 32];
    wire [31:0] pool3_ch10 = pool3_dout[10*32 +: 32];
    wire [31:0] pool3_ch11 = pool3_dout[11*32 +: 32];
    wire [31:0] pool3_ch12 = pool3_dout[12*32 +: 32];
    wire [31:0] pool3_ch13 = pool3_dout[13*32 +: 32];
    wire [31:0] pool3_ch14 = pool3_dout[14*32 +: 32];
    wire [31:0] pool3_ch15 = pool3_dout[15*32 +: 32];
    wire [31:0] pool3_ch16 = pool3_dout[16*32 +: 32];
    wire [31:0] pool3_ch17 = pool3_dout[17*32 +: 32];
    wire [31:0] pool3_ch18 = pool3_dout[18*32 +: 32];
    wire [31:0] pool3_ch19 = pool3_dout[19*32 +: 32];
    wire [31:0] pool3_ch20 = pool3_dout[20*32 +: 32];
    wire [31:0] pool3_ch21 = pool3_dout[21*32 +: 32];
    wire [31:0] pool3_ch22 = pool3_dout[22*32 +: 32];
    wire [31:0] pool3_ch23 = pool3_dout[23*32 +: 32];
    wire [31:0] pool3_ch24 = pool3_dout[24*32 +: 32];
    wire [31:0] pool3_ch25 = pool3_dout[25*32 +: 32];
    wire [31:0] pool3_ch26 = pool3_dout[26*32 +: 32];
    wire [31:0] pool3_ch27 = pool3_dout[27*32 +: 32];
    wire [31:0] pool3_ch28 = pool3_dout[28*32 +: 32];
    wire [31:0] pool3_ch29 = pool3_dout[29*32 +: 32];
    wire [31:0] pool3_ch30 = pool3_dout[30*32 +: 32];
    wire [31:0] pool3_ch31 = pool3_dout[31*32 +: 32];

    // =========================================================
    // UNPACK CONV2 OUTPUT UNTUK DEBUG PYTHON
    // CONV2_OUT = sebelum pooling
    // =========================================================
    wire [31:0] conv2_ch0;
    wire [31:0] conv2_ch1;
    wire [31:0] conv2_ch2;
    wire [31:0] conv2_ch3;
    wire [31:0] conv2_ch4;
    wire [31:0] conv2_ch5;
    wire [31:0] conv2_ch6;
    wire [31:0] conv2_ch7;
    wire [31:0] conv2_ch8;
    wire [31:0] conv2_ch9;
    wire [31:0] conv2_ch10;
    wire [31:0] conv2_ch11;
    wire [31:0] conv2_ch12;
    wire [31:0] conv2_ch13;
    wire [31:0] conv2_ch14;
    wire [31:0] conv2_ch15;

    assign conv2_ch0  = conv2_dout[0*32  +: 32];
    assign conv2_ch1  = conv2_dout[1*32  +: 32];
    assign conv2_ch2  = conv2_dout[2*32  +: 32];
    assign conv2_ch3  = conv2_dout[3*32  +: 32];
    assign conv2_ch4  = conv2_dout[4*32  +: 32];
    assign conv2_ch5  = conv2_dout[5*32  +: 32];
    assign conv2_ch6  = conv2_dout[6*32  +: 32];
    assign conv2_ch7  = conv2_dout[7*32  +: 32];
    assign conv2_ch8  = conv2_dout[8*32  +: 32];
    assign conv2_ch9  = conv2_dout[9*32  +: 32];
    assign conv2_ch10 = conv2_dout[10*32 +: 32];
    assign conv2_ch11 = conv2_dout[11*32 +: 32];
    assign conv2_ch12 = conv2_dout[12*32 +: 32];
    assign conv2_ch13 = conv2_dout[13*32 +: 32];
    assign conv2_ch14 = conv2_dout[14*32 +: 32];
    assign conv2_ch15 = conv2_dout[15*32 +: 32];

    // =========================================================
    // UNPACK CONV2 POOL OUTPUT UNTUK DEBUG PYTHON
    // CONV2_POOL_OUT = setelah maxpool
    // =========================================================
    wire [31:0] conv2_pool_ch0;
    wire [31:0] conv2_pool_ch1;
    wire [31:0] conv2_pool_ch2;
    wire [31:0] conv2_pool_ch3;
    wire [31:0] conv2_pool_ch4;
    wire [31:0] conv2_pool_ch5;
    wire [31:0] conv2_pool_ch6;
    wire [31:0] conv2_pool_ch7;
    wire [31:0] conv2_pool_ch8;
    wire [31:0] conv2_pool_ch9;
    wire [31:0] conv2_pool_ch10;
    wire [31:0] conv2_pool_ch11;
    wire [31:0] conv2_pool_ch12;
    wire [31:0] conv2_pool_ch13;
    wire [31:0] conv2_pool_ch14;
    wire [31:0] conv2_pool_ch15;

    assign conv2_pool_ch0  = conv2_pool_dout[0*32  +: 32];
    assign conv2_pool_ch1  = conv2_pool_dout[1*32  +: 32];
    assign conv2_pool_ch2  = conv2_pool_dout[2*32  +: 32];
    assign conv2_pool_ch3  = conv2_pool_dout[3*32  +: 32];
    assign conv2_pool_ch4  = conv2_pool_dout[4*32  +: 32];
    assign conv2_pool_ch5  = conv2_pool_dout[5*32  +: 32];
    assign conv2_pool_ch6  = conv2_pool_dout[6*32  +: 32];
    assign conv2_pool_ch7  = conv2_pool_dout[7*32  +: 32];
    assign conv2_pool_ch8  = conv2_pool_dout[8*32  +: 32];
    assign conv2_pool_ch9  = conv2_pool_dout[9*32  +: 32];
    assign conv2_pool_ch10 = conv2_pool_dout[10*32 +: 32];
    assign conv2_pool_ch11 = conv2_pool_dout[11*32 +: 32];
    assign conv2_pool_ch12 = conv2_pool_dout[12*32 +: 32];
    assign conv2_pool_ch13 = conv2_pool_dout[13*32 +: 32];
    assign conv2_pool_ch14 = conv2_pool_dout[14*32 +: 32];
    assign conv2_pool_ch15 = conv2_pool_dout[15*32 +: 32];

    // =========================================================
    // DEBUG DISPLAY CONV2 OUT
    // Conv2 valid output seharusnya 11x11 = 121 vector.
    // Setiap vector berisi 16 channel.
    // =========================================================
    integer conv2_out_count;

//    always @(posedge clk) begin
//        if (rst) begin
//            conv2_out_count <= 0;
//        end

//        else begin
//            if (conv2_valid && conv2_downstream_ready) begin
//                $display(
//                    "CONV2_OUT idx=%0d time=%0t ch0=%0d ch1=%0d ch2=%0d ch3=%0d ch4=%0d ch5=%0d ch6=%0d ch7=%0d ch8=%0d ch9=%0d ch10=%0d ch11=%0d ch12=%0d ch13=%0d ch14=%0d ch15=%0d",
//                    conv2_out_count,
//                    $time,
//                    conv2_ch0,  conv2_ch1,  conv2_ch2,  conv2_ch3,
//                    conv2_ch4,  conv2_ch5,  conv2_ch6,  conv2_ch7,
//                    conv2_ch8,  conv2_ch9,  conv2_ch10, conv2_ch11,
//                    conv2_ch12, conv2_ch13, conv2_ch14, conv2_ch15
//                );

//                conv2_out_count <= conv2_out_count + 1;
//            end
//        end
//    end

    // =========================================================
    // DEBUG DISPLAY CONV2 POOL OUT
    // Pool output seharusnya 5x5 = 25 vector.
    // Setiap vector berisi 16 channel.
    // =========================================================
    integer conv2_pool_out_count;

//    always @(posedge clk) begin
//        if (rst) begin
//            conv2_pool_out_count <= 0;
//        end

//        else begin
//            if (conv2_pool_valid && conv2_pool_final_ready) begin
//                $display(
//                    "CONV2_POOL_OUT idx=%0d time=%0t ch0=%0d ch1=%0d ch2=%0d ch3=%0d ch4=%0d ch5=%0d ch6=%0d ch7=%0d ch8=%0d ch9=%0d ch10=%0d ch11=%0d ch12=%0d ch13=%0d ch14=%0d ch15=%0d",
//                    conv2_pool_out_count,
//                    $time,
//                    conv2_pool_ch0,  conv2_pool_ch1,  conv2_pool_ch2,  conv2_pool_ch3,
//                    conv2_pool_ch4,  conv2_pool_ch5,  conv2_pool_ch6,  conv2_pool_ch7,
//                    conv2_pool_ch8,  conv2_pool_ch9,  conv2_pool_ch10, conv2_pool_ch11,
//                    conv2_pool_ch12, conv2_pool_ch13, conv2_pool_ch14, conv2_pool_ch15
//                );

//                conv2_pool_out_count <= conv2_pool_out_count + 1;
//            end
//        end
//    end

    // =========================================================
    // OPTIONAL FLOW DEBUG
    // Aktifkan kalau ingin lihat aliran valid-ready.
    // =========================================================
    /*
    always @(posedge clk) begin
        if (!rst) begin
            $display(
                "FLOW t=%0t stream_v=%b stream_r=%b kernel_v=%b block1_v=%b fifo_level=%0d fifo_full=%b fifo_empty=%b fifo_v=%b b2win_v=%b b2_ready=%b conv2_busy=%b conv2_v=%b pool_ready=%b pool_v=%b",
                $time,
                stream_valid,
                stream_ready,
                kernel_valid,
                block1_valid,
                fifo_level,
                fifo_full,
                fifo_empty,
                fifo_valid_to_block2,
                block2_window_valid,
                block2_fsm_ready,
                conv2_busy,
                conv2_valid,
                conv2_pool_ready,
                conv2_pool_valid
            );
        end
    end
    */



    // =========================================================
    // DEBUG DISPLAY CONV3 OUT DAN POOL3 OUT
    // Dengan ONLY_POOL3_WINDOWS=1, CONV3_OUT muncul 4 kali per frame.
    // POOL3_OUT muncul 1 kali per frame, berisi 32 channel.
    // =========================================================
    integer conv3_out_count;
    integer pool3_out_count;

//    always @(posedge clk) begin
//        if (rst) begin
//            conv3_out_count <= 0;
//        end
//        else begin
//            if (conv3_valid && conv3_downstream_ready) begin
//                $display(
//                    "CONV3_OUT idx=%0d time=%0t ch0=%0d ch1=%0d ch2=%0d ch3=%0d ch4=%0d ch5=%0d ch6=%0d ch7=%0d ch8=%0d ch9=%0d ch10=%0d ch11=%0d ch12=%0d ch13=%0d ch14=%0d ch15=%0d ch16=%0d ch17=%0d ch18=%0d ch19=%0d ch20=%0d ch21=%0d ch22=%0d ch23=%0d ch24=%0d ch25=%0d ch26=%0d ch27=%0d ch28=%0d ch29=%0d ch30=%0d ch31=%0d",
//                    conv3_out_count,
//                    $time,
//                    conv3_ch0, conv3_ch1, conv3_ch2, conv3_ch3,
//                    conv3_ch4, conv3_ch5, conv3_ch6, conv3_ch7,
//                    conv3_ch8, conv3_ch9, conv3_ch10, conv3_ch11,
//                    conv3_ch12, conv3_ch13, conv3_ch14, conv3_ch15,
//                    conv3_ch16, conv3_ch17, conv3_ch18, conv3_ch19,
//                    conv3_ch20, conv3_ch21, conv3_ch22, conv3_ch23,
//                    conv3_ch24, conv3_ch25, conv3_ch26, conv3_ch27,
//                    conv3_ch28, conv3_ch29, conv3_ch30, conv3_ch31
//                );
//                conv3_out_count <= conv3_out_count + 1;
//            end
//        end
//    end

//    always @(posedge clk) begin
//        if (rst) begin
//            pool3_out_count <= 0;
//        end
//        else begin
//            if (pool3_valid && pool3_final_ready) begin
//                $display(
//                    "POOL3_OUT idx=%0d time=%0t ch0=%0d ch1=%0d ch2=%0d ch3=%0d ch4=%0d ch5=%0d ch6=%0d ch7=%0d ch8=%0d ch9=%0d ch10=%0d ch11=%0d ch12=%0d ch13=%0d ch14=%0d ch15=%0d ch16=%0d ch17=%0d ch18=%0d ch19=%0d ch20=%0d ch21=%0d ch22=%0d ch23=%0d ch24=%0d ch25=%0d ch26=%0d ch27=%0d ch28=%0d ch29=%0d ch30=%0d ch31=%0d",
//                    pool3_out_count,
//                    $time,
//                    pool3_ch0, pool3_ch1, pool3_ch2, pool3_ch3,
//                    pool3_ch4, pool3_ch5, pool3_ch6, pool3_ch7,
//                    pool3_ch8, pool3_ch9, pool3_ch10, pool3_ch11,
//                    pool3_ch12, pool3_ch13, pool3_ch14, pool3_ch15,
//                    pool3_ch16, pool3_ch17, pool3_ch18, pool3_ch19,
//                    pool3_ch20, pool3_ch21, pool3_ch22, pool3_ch23,
//                    pool3_ch24, pool3_ch25, pool3_ch26, pool3_ch27,
//                    pool3_ch28, pool3_ch29, pool3_ch30, pool3_ch31
//                );
//                pool3_out_count <= pool3_out_count + 1;
//            end
//        end
//    end


    // =========================================================
    // DEBUG DISPLAY FINAL FC2 OUTPUT
    // FINAL_OUT muncul 1 kali per frame, berisi 10 output class.
    // =========================================================
    integer final_out_count;

    always @(posedge clk) begin
        if (rst) begin
            final_out_count <= 0;
        end
        else begin
            if (fc_valid) begin
                $display(
                    "FINAL_OUT idx=%0d time=%0t c0=%0d c1=%0d c2=%0d c3=%0d c4=%0d c5=%0d c6=%0d c7=%0d c8=%0d c9=%0d",
                    final_out_count,
                    $time,
                    fc_out0, fc_out1, fc_out2, fc_out3, fc_out4,
                    fc_out5, fc_out6, fc_out7, fc_out8, fc_out9
                );
                final_out_count <= final_out_count + 1;
            end
        end
    end

    // =========================================================
    // CLOCK
    // =========================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================
    // TEST
    // =========================================================
    initial begin
        rst = 1;
        frame_ready = 0;

        conv2_out_count = 0;
        conv2_pool_out_count = 0;
        conv3_out_count = 0;
        pool3_out_count = 0;
        final_out_count = 0;

        #20;
        rst = 0;

        #10;
        frame_ready = 1;

        // dibuat panjang supaya output pool 5x5 sempat keluar semua
        #200000;
        $finish;
    end

endmodule