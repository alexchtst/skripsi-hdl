`timescale 1ns / 1ps

// ============================================================
// CONV3 PARTIAL 8CH - OPTIMIZED WEIGHT BANK VERSION
//
// Tujuan:
// - Memakai 72 multiplier/DSP:
//      8 input channel x 9 tap = 72 MAC
// - Dipakai oleh conv3_time_mux_32:
//      32 output channel x 2 group input
//
// Perbedaan penting dari versi lama:
// - Weight tidak dibaca dari 1 ROM flat besar dengan index panjang.
// - Weight diubah menjadi 72 bank kecil.
// - Setiap DSP punya 1 bank weight kecil berisi:
//      32 output channel x 2 group = 64 weight
//
// Ini jauh lebih ringan untuk synthesis dibanding:
//      W[out_channel_idx*TOTAL_N + group_idx*N + i]
// ============================================================

module conv3_partial_8ch #(
    parameter IN_CHANNELS        = 8,
    parameter TOTAL_IN_CHANNELS  = 16,
    parameter KERNEL_SIZE        = 9,
    parameter DATA_SIZE          = 32,
    parameter ACT_SIZE           = 24,
    parameter WEIGHT_SIZE        = 16,
    parameter OUT_WIDTH          = 48,
    parameter ACT_SHIFT          = 0,
    parameter OUT_CHANNELS       = 32
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,
    input wire ready_in,

    input wire [4:0] out_channel_idx,
    input wire group_idx,

    input wire [IN_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] din,

    output reg signed [OUT_WIDTH-1:0] dout,
    output reg valid_out
);

    // =========================================================
    // LOCAL PARAMETER
    // =========================================================
    localparam N          = IN_CHANNELS * KERNEL_SIZE;        // 8 x 9 = 72
    localparam TOTAL_N    = TOTAL_IN_CHANNELS * KERNEL_SIZE;  // 16 x 9 = 144
    localparam GROUPS     = TOTAL_IN_CHANNELS / IN_CHANNELS;  // 16 / 8 = 2
    localparam BANK_DEPTH = OUT_CHANNELS * GROUPS;            // 32 x 2 = 64

    localparam MULT_WIDTH = ACT_SIZE + 1 + WEIGHT_SIZE;

    assign ready_out = ready_in;

    integer i;
    integer oc;
    integer g;
    integer j;

    // =========================================================
    // INPUT QUANTIZATION
    // unsigned activation 32-bit -> unsigned ACT_SIZE
    // =========================================================
    function [ACT_SIZE-1:0] quantize_act;
        input [DATA_SIZE-1:0] val;
        reg [DATA_SIZE-1:0] shifted;
        reg [DATA_SIZE-1:0] max_val;
        begin
            shifted = val >> ACT_SHIFT;
            max_val = {{(DATA_SIZE-ACT_SIZE){1'b0}}, {ACT_SIZE{1'b1}}};

            if (shifted > max_val)
                quantize_act = {ACT_SIZE{1'b1}};
            else
                quantize_act = shifted[ACT_SIZE-1:0];
        end
    endfunction

    wire [DATA_SIZE-1:0] x_raw [0:N-1];
    wire [ACT_SIZE-1:0] x_q   [0:N-1];
    wire signed [ACT_SIZE:0] x_s [0:N-1];

    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : UNPACK_INPUT
            assign x_raw[gi] = din[gi*DATA_SIZE +: DATA_SIZE];
            assign x_q[gi]   = quantize_act(x_raw[gi]);
            assign x_s[gi]   = $signed({1'b0, x_q[gi]});
        end
    endgenerate

    // =========================================================
    // WEIGHT MEMORY
    // Original conv3_w.mem layout diasumsikan:
    //
    // W[oc * TOTAL_N + input_channel * 9 + tap]
    //
    // Untuk hardware, kita bentuk bank:
    //
    // W_BANK[mac_index][oc, group]
    //
    // Karena Verilog .v lebih aman pakai array 1D:
    // W_BANK[mac_index * BANK_DEPTH + weight_addr]
    //
    // mac_index   = 0..71
    // weight_addr = output_channel*2 + group
    // =========================================================

    reg signed [WEIGHT_SIZE-1:0] W_FLAT [0:OUT_CHANNELS*TOTAL_IN_CHANNELS*KERNEL_SIZE-1];

    (* rom_style = "distributed" *)
    reg signed [WEIGHT_SIZE-1:0] W_BANK [0:N*BANK_DEPTH-1];

    initial begin
        $readmemh("conv3_w.mem", W_FLAT);

        for (oc = 0; oc < OUT_CHANNELS; oc = oc + 1) begin
            for (g = 0; g < GROUPS; g = g + 1) begin
                for (j = 0; j < N; j = j + 1) begin
                    W_BANK[j*BANK_DEPTH + oc*GROUPS + g] =
                        W_FLAT[oc*TOTAL_N + g*N + j];
                end
            end
        end
    end

    wire [5:0] weight_addr;
    assign weight_addr = out_channel_idx * GROUPS + group_idx;

    // =========================================================
    // PIPELINE REGISTER
    // Stage 0: baca input dan weight
    // Stage 1: multiply 72 DSP
    // Stage 2..6: adder tree
    // =========================================================

    reg signed [ACT_SIZE:0]      x_reg [0:N-1];
    reg signed [WEIGHT_SIZE-1:0] w_reg [0:N-1];

    (* use_dsp = "yes" *)
    reg signed [MULT_WIDTH-1:0] mult [0:N-1];

    reg signed [OUT_WIDTH-1:0] sum_l1 [0:35];
    reg signed [OUT_WIDTH-1:0] sum_l2 [0:17];
    reg signed [OUT_WIDTH-1:0] sum_l3 [0:8];
    reg signed [OUT_WIDTH-1:0] sum_l4 [0:4];
    reg signed [OUT_WIDTH-1:0] sum_l5 [0:2];

    wire signed [OUT_WIDTH-1:0] final_calc;
    assign final_calc = sum_l5[0] + sum_l5[1] + sum_l5[2];

    // Karena ada tambahan stage register weight/input,
    // latency pipeline dibuat 7 tahap.
    reg [6:0] valid_pipe;

    always @(posedge clk) begin
        if (rst) begin
            valid_pipe <= 7'b0;
            valid_out  <= 1'b0;
            dout       <= {OUT_WIDTH{1'b0}};
        end

        else if (ready_in) begin
            // valid pipeline
            valid_pipe <= {valid_pipe[5:0], valid_in};

            // =================================================
            // Stage 0: latch input dan weight
            // =================================================
            if (valid_in) begin
                for (i = 0; i < N; i = i + 1) begin
                    x_reg[i] <= x_s[i];
                    w_reg[i] <= W_BANK[i*BANK_DEPTH + weight_addr];
                end
            end

            // =================================================
            // Stage 1: 72 parallel multipliers
            // =================================================
            for (i = 0; i < N; i = i + 1) begin
                mult[i] <= x_reg[i] * w_reg[i];
            end

            // =================================================
            // Stage 2: adder tree level 1
            // 72 -> 36
            // =================================================
            for (i = 0; i < 36; i = i + 1) begin
                sum_l1[i] <= mult[2*i] + mult[2*i+1];
            end

            // =================================================
            // Stage 3: adder tree level 2
            // 36 -> 18
            // =================================================
            for (i = 0; i < 18; i = i + 1) begin
                sum_l2[i] <= sum_l1[2*i] + sum_l1[2*i+1];
            end

            // =================================================
            // Stage 4: adder tree level 3
            // 18 -> 9
            // =================================================
            for (i = 0; i < 9; i = i + 1) begin
                sum_l3[i] <= sum_l2[2*i] + sum_l2[2*i+1];
            end

            // =================================================
            // Stage 5: adder tree level 4
            // 9 -> 5
            // =================================================
            sum_l4[0] <= sum_l3[0] + sum_l3[1];
            sum_l4[1] <= sum_l3[2] + sum_l3[3];
            sum_l4[2] <= sum_l3[4] + sum_l3[5];
            sum_l4[3] <= sum_l3[6] + sum_l3[7];
            sum_l4[4] <= sum_l3[8];

            // =================================================
            // Stage 6: adder tree level 5
            // 5 -> 3
            // =================================================
            sum_l5[0] <= sum_l4[0] + sum_l4[1];
            sum_l5[1] <= sum_l4[2] + sum_l4[3];
            sum_l5[2] <= sum_l4[4];

            // =================================================
            // Stage 7: output valid
            // =================================================
            valid_out <= valid_pipe[6];

            if (valid_pipe[6]) begin
                dout <= final_calc;
            end
        end
    end

endmodule