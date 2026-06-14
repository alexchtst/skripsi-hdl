`timescale 1ns / 1ps

module conv2_partial #(
    parameter IN_CHANNELS = 8,
    parameter KERNEL_SIZE = 9,
    parameter DATA_SIZE   = 32,

    // Pilih 24 atau 18.
    // ACT_SIZE = 24 -> activation dipakai sebagai 25-bit signed-positive x 16-bit signed weight
    // ACT_SIZE = 18 -> activation dipakai sebagai 19-bit signed-positive x 16-bit signed weight
    parameter ACT_SIZE    = 24,

    parameter WEIGHT_SIZE = 16,
    parameter OUT_WIDTH   = 32,

    // Jika nilai activation masih terlalu besar, naikkan ACT_SHIFT.
    // Contoh ACT_SHIFT=4 artinya activation dibagi 16 sebelum saturasi.
    parameter ACT_SHIFT   = 0
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,

    // ready dari module pembungkus / downstream.
    // Jika ready_in = 0, seluruh pipeline MAC ditahan.
    input wire ready_in,

    // index output-channel conv2: 0..15
    input wire [4:0] channel_idx,

    // input window 3x3 x 8 channel dari block2_fifo_shift_register_kernel
    // Format harus sama dengan block2 kernel:
    // ch0 tap0..tap8, ch1 tap0..tap8, ..., ch7 tap0..tap8
    input wire [IN_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] din,

    // output sudah melewati ReLU, jadi unsigned
    output reg [OUT_WIDTH-1:0] dout,
    output reg valid_out
);

    // =========================================================
    // LOCALPARAM
    // =========================================================
    localparam N = IN_CHANNELS * KERNEL_SIZE; // 8 x 9 = 72

    // Conv2 fixed output channel = 16
    localparam OUT_CHANNELS = 16;

    // Untuk ACT_SIZE=24: 25-bit signed-positive x 16-bit signed = 41-bit signed
    // Untuk ACT_SIZE=18: 19-bit signed-positive x 16-bit signed = 35-bit signed
    localparam ACT_SIGNED_SIZE = ACT_SIZE + 1;
    localparam MUL_WIDTH       = ACT_SIGNED_SIZE + WEIGHT_SIZE;

    // 72 hasil perkalian dijumlahkan. 72 < 2^7, jadi +7 bit aman.
    localparam ACC_WIDTH       = MUL_WIDTH + 7;

    localparam FRAC_BITS = 14;

    integer i;
    integer oc;
    integer j;

    // =========================================================
    // Handshake sederhana
    // =========================================================
    assign ready_out = ready_in;

    // =========================================================
    // Unpack input 32-bit unsigned dari window block2
    // Setelah block1 ReLU + pool, activation dianggap unsigned.
    // =========================================================
    wire [DATA_SIZE-1:0] x_raw [0:N-1];

    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : UNPACK_INPUT
            assign x_raw[gi] = din[gi*DATA_SIZE +: DATA_SIZE];
        end
    endgenerate

    // =========================================================
    // Quantize activation: 32-bit unsigned -> ACT_SIZE unsigned
    // Lalu dikonversi menjadi signed-positive dengan {1'b0, act_u}
    // =========================================================
    localparam [DATA_SIZE-1:0] ACT_MAX =
        (({{(DATA_SIZE-1){1'b0}}, 1'b1}) << ACT_SIZE) - 1'b1;

    function [ACT_SIZE-1:0] act_quantize;
        input [DATA_SIZE-1:0] val;
        reg [DATA_SIZE-1:0] shifted;
        begin
            shifted = val >> ACT_SHIFT;

            if (shifted > ACT_MAX)
                act_quantize = {ACT_SIZE{1'b1}};
            else
                act_quantize = shifted[ACT_SIZE-1:0];
        end
    endfunction

    wire [ACT_SIZE-1:0] x_act_u [0:N-1];
    wire signed [ACT_SIGNED_SIZE-1:0] x_act_s [0:N-1];

    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : ACT_QUANTIZE
            assign x_act_u[gi] = act_quantize(x_raw[gi]);
            assign x_act_s[gi] = $signed({1'b0, x_act_u[gi]});
        end
    endgenerate

    // =========================================================
    // Weight dan bias conv2
    //
    // Total weight = 16 output channel x 8 input channel x 9 tap
    //              = 16 x 72 = 1152
    //
    // W_FLAT layout dari file:
    // W_FLAT[out_channel * 72 + mac_index]
    //
    // W_BANK layout internal:
    // W_BANK[mac_index * 16 + out_channel]
    //
    // Tujuannya:
    // - setiap MAC/DSP punya bank weight kecil sendiri
    // - mengurangi mux besar pada weight selection
    // - membantu timing
    // =========================================================
    reg signed [WEIGHT_SIZE-1:0] W_FLAT [0:OUT_CHANNELS*N-1];
    reg signed [WEIGHT_SIZE-1:0] B      [0:OUT_CHANNELS-1];

    (* rom_style = "distributed" *)
    reg signed [WEIGHT_SIZE-1:0] W_BANK [0:N*OUT_CHANNELS-1];

    initial begin
        $readmemh("conv2_w.mem", W_FLAT);
        $readmemh("conv2_b.mem", B);

        for (oc = 0; oc < OUT_CHANNELS; oc = oc + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                W_BANK[j*OUT_CHANNELS + oc] = W_FLAT[oc*N + j];
            end
        end
    end

    // =========================================================
    // DSP INPUT PIPELINE
    //
    // Sebelumnya:
    //   mult[i] <= x_act_s[i] * W[channel_idx*N + i];
    //
    // Masalah:
    // - input DSP A/B langsung dari logic quantize + weight mux
    // - Vivado memberi warning DSP input not pipelined
    //
    // Sekarang:
    //   Stage 0: register activation dan weight
    //   Stage 1: multiply di DSP
    //
    // Ini tidak mengubah conv2_time_mux_16.v.
    // Yang berubah hanya latency valid_out bertambah 1 cycle.
    // =========================================================
    reg signed [ACT_SIGNED_SIZE-1:0] x_reg [0:N-1];
    reg signed [WEIGHT_SIZE-1:0]     w_reg [0:N-1];

    (* use_dsp = "yes" *)
    reg signed [MUL_WIDTH-1:0] mult [0:N-1];

    // =========================================================
    // Bias pipeline
    // Karena ada tambahan stage register input DSP,
    // latency bertambah dari 6 menjadi 7 cycle.
    // Maka bias pipe juga dibuat 7 stage: [0]..[6].
    // =========================================================
    reg signed [WEIGHT_SIZE-1:0] bias_pipe [0:6];

    // =========================================================
    // Valid pipeline
    //
    // Latency valid_in -> valid_out = 7 cycle ketika ready_in selalu 1
    //
    // cycle 0 : latch x_reg / w_reg
    // cycle 1 : mult
    // cycle 2 : sum_l1
    // cycle 3 : sum_l2
    // cycle 4 : sum_l3
    // cycle 5 : sum_l4
    // cycle 6 : sum_l5
    // cycle 7 : output
    // =========================================================
    reg [6:0] valid_pipe;

    // =========================================================
    // Adder tree dibuat ACC_WIDTH supaya aman untuk ACT_SIZE 18 maupun 24.
    // 72 -> 36 -> 18 -> 9 -> 5 -> 3 -> final
    // =========================================================
    reg signed [ACC_WIDTH-1:0] sum_l1 [0:35];
    reg signed [ACC_WIDTH-1:0] sum_l2 [0:17];
    reg signed [ACC_WIDTH-1:0] sum_l3 [0:8];
    reg signed [ACC_WIDTH-1:0] sum_l4 [0:4];
    reg signed [ACC_WIDTH-1:0] sum_l5 [0:2];

    wire signed [ACC_WIDTH-1:0] mult_ext [0:N-1];

    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : EXTEND_MULT
            assign mult_ext[gi] =
                {{(ACC_WIDTH-MUL_WIDTH){mult[gi][MUL_WIDTH-1]}}, mult[gi]};
        end
    endgenerate

    // =========================================================
    // Final add + bias + shift + ReLU saturasi
    // =========================================================
    wire signed [ACC_WIDTH-1:0] bias_q28;
    wire signed [ACC_WIDTH-1:0] final_q28;
    wire signed [ACC_WIDTH-1:0] final_q14;

    assign bias_q28 =
        ({{(ACC_WIDTH-WEIGHT_SIZE){bias_pipe[6][WEIGHT_SIZE-1]}}, bias_pipe[6]})
        <<< FRAC_BITS;

    assign final_q28 =
        sum_l5[0] +
        sum_l5[1] +
        sum_l5[2] +
        bias_q28;

    assign final_q14 = final_q28 >>> FRAC_BITS;

    // Nilai maksimum output untuk saturasi ReLU output
    localparam [ACC_WIDTH-1:0] OUT_MAX =
        (({{(ACC_WIDTH-1){1'b0}}, 1'b1}) << OUT_WIDTH) - 1'b1;

    // =========================================================
    // MAIN PIPELINE
    // =========================================================
    always @(posedge clk) begin
        if (rst) begin
            // Reset hanya control-valid dan output visible.
            // Register data besar seperti x_reg, w_reg, mult, sum_l*
            // tidak perlu di-reset supaya fanout reset lebih ringan.
            valid_pipe <= 7'b0;
            valid_out  <= 1'b0;
            dout       <= {OUT_WIDTH{1'b0}};

            for (i = 0; i < 7; i = i + 1) begin
                bias_pipe[i] <= {WEIGHT_SIZE{1'b0}};
            end
        end

        else if (ready_in) begin
            // =================================================
            // Valid pipeline
            // =================================================
            valid_pipe <= {valid_pipe[5:0], valid_in};

            // =================================================
            // Bias pipeline
            // =================================================
            bias_pipe[0] <= B[channel_idx[3:0]];
            bias_pipe[1] <= bias_pipe[0];
            bias_pipe[2] <= bias_pipe[1];
            bias_pipe[3] <= bias_pipe[2];
            bias_pipe[4] <= bias_pipe[3];
            bias_pipe[5] <= bias_pipe[4];
            bias_pipe[6] <= bias_pipe[5];

            // =================================================
            // Stage 0: register DSP input
            // Activation dan weight dilatch dulu sebelum masuk DSP.
            // Ini bagian penting untuk menghilangkan warning DSP input
            // not pipelined.
            // =================================================
            if (valid_in) begin
                for (i = 0; i < N; i = i + 1) begin
                    x_reg[i] <= x_act_s[i];
                    w_reg[i] <= W_BANK[i*OUT_CHANNELS + channel_idx[3:0]];
                end
            end

            // =================================================
            // Stage 1: 72 multiplications
            // Input DSP sekarang berasal dari register x_reg dan w_reg.
            // =================================================
            for (i = 0; i < N; i = i + 1) begin
                mult[i] <= x_reg[i] * w_reg[i];
            end

            // =================================================
            // Stage 2: 72 -> 36
            // =================================================
            for (i = 0; i < 36; i = i + 1) begin
                sum_l1[i] <= mult_ext[2*i] + mult_ext[2*i+1];
            end

            // =================================================
            // Stage 3: 36 -> 18
            // =================================================
            for (i = 0; i < 18; i = i + 1) begin
                sum_l2[i] <= sum_l1[2*i] + sum_l1[2*i+1];
            end

            // =================================================
            // Stage 4: 18 -> 9
            // =================================================
            for (i = 0; i < 9; i = i + 1) begin
                sum_l3[i] <= sum_l2[2*i] + sum_l2[2*i+1];
            end

            // =================================================
            // Stage 5: 9 -> 5
            // =================================================
            sum_l4[0] <= sum_l3[0] + sum_l3[1];
            sum_l4[1] <= sum_l3[2] + sum_l3[3];
            sum_l4[2] <= sum_l3[4] + sum_l3[5];
            sum_l4[3] <= sum_l3[6] + sum_l3[7];
            sum_l4[4] <= sum_l3[8];

            // =================================================
            // Stage 6: 5 -> 3
            // =================================================
            sum_l5[0] <= sum_l4[0] + sum_l4[1];
            sum_l5[1] <= sum_l4[2] + sum_l4[3];
            sum_l5[2] <= sum_l4[4];

            // =================================================
            // Stage 7: Output + ReLU + saturasi unsigned
            // =================================================
            valid_out <= valid_pipe[6];

            if (valid_pipe[6]) begin
                if (final_q14[ACC_WIDTH-1]) begin
                    dout <= {OUT_WIDTH{1'b0}};
                end
                else if (final_q14 > $signed({1'b0, OUT_MAX})) begin
                    dout <= {OUT_WIDTH{1'b1}};
                end
                else begin
                    dout <= final_q14[OUT_WIDTH-1:0];
                end
            end
        end

        // Jika ready_in = 0:
        // semua register pipeline ditahan.
    end

endmodule