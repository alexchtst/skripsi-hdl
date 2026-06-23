`timescale 1ns / 1ps

// ============================================================
// FC1 + FC2 shared 2-DSP engine - PIPELINED VERSION
//
// Input  : pool3 output = 32 activation values
// FC1    : 32 input -> 16 hidden, ReLU
// FC2    : 16 hidden -> 10 output, optional ReLU
// DSP    : 2 multipliers shared by FC1 and FC2
//
// Tujuan versi ini:
// - Memecah jalur timing dense yang terlalu panjang
// - Baca operand/weight, multiply, accumulate, dan write result
//   dipisah menjadi beberapa state/cycle
// - Tetap memakai 2 DSP
// - Reset hanya untuk control register, bukan semua data besar
// ============================================================

module fc1_fc2_2dsp #(
    parameter IN_WIDTH    = 32,
    parameter ACT_SIZE    = 24,
    parameter WEIGHT_SIZE = 16,
    parameter BIAS_SIZE   = 32,
    parameter ACC_WIDTH   = 64,

    parameter FC1_IN      = 32,
    parameter FC1_OUT     = 16,
    parameter FC2_OUT     = 10,
    parameter OUT_WIDTH   = 32,

    // Fixed-point convention:
    // input activations = Q14, weights = Q14
    // product = Q28
    // bias memory = Q14, sehingga bias digeser kiri FRAC_BITS
    parameter FRAC_BITS   = 14,
    parameter INPUT_SHIFT = 0,
    parameter FC1_SHIFT   = 14,
    parameter FC2_SHIFT   = 14,

    parameter FC2_RELU    = 1
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,

    input wire ready_in,

    input wire [FC1_IN*IN_WIDTH-1:0] din,

    output reg valid_out,
    output reg [FC2_OUT*OUT_WIDTH-1:0] dout,

    output reg busy,
    output reg [4:0] fc1_neuron_dbg,
    output reg [4:0] fc2_class_dbg
);

    // =========================================================
    // FSM STATE
    // =========================================================
    localparam S_IDLE     = 3'd0;
    localparam S_FC1_LOAD = 3'd1;
    localparam S_FC2_LOAD = 3'd2;
    localparam S_MUL      = 3'd3;
    localparam S_ACC      = 3'd4;
    localparam S_WRITE    = 3'd5;
    localparam S_DONE     = 3'd6;

    localparam FC1_PAIRS  = FC1_IN  / 2;
    localparam FC2_PAIRS  = FC1_OUT / 2;
    localparam PROD_WIDTH = (ACT_SIZE + 1) + WEIGHT_SIZE;

    reg [2:0] state;

    assign ready_out = (state == S_IDLE);

    // =========================================================
    // DATA STORAGE
    // =========================================================
    reg [FC1_IN*IN_WIDTH-1:0] input_reg;
    reg [ACT_SIZE-1:0] hidden [0:FC1_OUT-1];

    reg [4:0] fc1_neuron;
    reg [4:0] fc1_pair;
    reg [4:0] fc2_class;
    reg [4:0] fc2_pair;

    reg signed [ACC_WIDTH-1:0] acc;

    // =========================================================
    // WEIGHT / BIAS ROM
    // =========================================================
    (* rom_style = "distributed" *) reg signed [WEIGHT_SIZE-1:0] fc1_w [0:FC1_IN*FC1_OUT-1];
    (* rom_style = "distributed" *) reg signed [BIAS_SIZE-1:0]   fc1_b [0:FC1_OUT-1];

    (* rom_style = "distributed" *) reg signed [WEIGHT_SIZE-1:0] fc2_w [0:FC1_OUT*FC2_OUT-1];
    (* rom_style = "distributed" *) reg signed [BIAS_SIZE-1:0]   fc2_b [0:FC2_OUT-1];

    initial begin
        $readmemh("fc1_w.mem", fc1_w);
        $readmemh("fc1_b.mem", fc1_b);
        $readmemh("fc2_w.mem", fc2_w);
        $readmemh("fc2_b.mem", fc2_b);
    end

    // =========================================================
    // QUANTIZATION FUNCTION
    // unsigned 32-bit activation -> unsigned ACT_SIZE
    // =========================================================
    localparam [IN_WIDTH-1:0] ACT_MAX_EXT =
        {{(IN_WIDTH-ACT_SIZE){1'b0}}, {ACT_SIZE{1'b1}}};

    function [ACT_SIZE-1:0] quant_input;
        input [IN_WIDTH-1:0] x;
        reg [IN_WIDTH-1:0] scaled;
        begin
            scaled = x >> INPUT_SHIFT;

            if (scaled > ACT_MAX_EXT)
                quant_input = {ACT_SIZE{1'b1}};
            else
                quant_input = scaled[ACT_SIZE-1:0];
        end
    endfunction

    // =========================================================
    // SATURATION FUNCTION
    // =========================================================
    localparam [ACC_WIDTH-1:0] ACT_MAX_ACC =
        {{(ACC_WIDTH-ACT_SIZE){1'b0}}, {ACT_SIZE{1'b1}}};

    localparam [ACC_WIDTH-1:0] OUT_MAX_ACC =
        {{(ACC_WIDTH-OUT_WIDTH){1'b0}}, {OUT_WIDTH{1'b1}}};

    function [ACT_SIZE-1:0] relu_sat_act;
        input signed [ACC_WIDTH-1:0] x;
        begin
            if (x[ACC_WIDTH-1])
                relu_sat_act = {ACT_SIZE{1'b0}};
            else if ($unsigned(x) > ACT_MAX_ACC)
                relu_sat_act = {ACT_SIZE{1'b1}};
            else
                relu_sat_act = x[ACT_SIZE-1:0];
        end
    endfunction

    function [OUT_WIDTH-1:0] relu_sat_out;
        input signed [ACC_WIDTH-1:0] x;
        begin
            if (x[ACC_WIDTH-1])
                relu_sat_out = {OUT_WIDTH{1'b0}};
            else if ($unsigned(x) > OUT_MAX_ACC)
                relu_sat_out = {OUT_WIDTH{1'b1}};
            else
                relu_sat_out = x[OUT_WIDTH-1:0];
        end
    endfunction

    function [OUT_WIDTH-1:0] raw_out;
        input signed [ACC_WIDTH-1:0] x;
        begin
            raw_out = x[OUT_WIDTH-1:0];
        end
    endfunction

    // =========================================================
    // PIPELINE REGISTERS
    // =========================================================

    // Stage LOAD
    reg signed [ACT_SIZE:0]      act0_reg;
    reg signed [ACT_SIZE:0]      act1_reg;
    reg signed [WEIGHT_SIZE-1:0] w0_reg;
    reg signed [WEIGHT_SIZE-1:0] w1_reg;
    reg signed [ACC_WIDTH-1:0]   base_reg;

    reg phase_fc2_reg;       // 0 = FC1, 1 = FC2
    reg last_pair_reg;
    reg [4:0] target_idx_reg;

    // Stage MUL
    (* use_dsp = "yes" *) reg signed [PROD_WIDTH-1:0] prod0_reg;
    (* use_dsp = "yes" *) reg signed [PROD_WIDTH-1:0] prod1_reg;

    // Stage ACC
    reg signed [ACC_WIDTH-1:0] sum_reg;

    wire signed [ACC_WIDTH-1:0] prod0_ext;
    wire signed [ACC_WIDTH-1:0] prod1_ext;

    assign prod0_ext = {{(ACC_WIDTH-PROD_WIDTH){prod0_reg[PROD_WIDTH-1]}}, prod0_reg};
    assign prod1_ext = {{(ACC_WIDTH-PROD_WIDTH){prod1_reg[PROD_WIDTH-1]}}, prod1_reg};

    wire signed [ACC_WIDTH-1:0] fc1_sum_shifted;
    wire signed [ACC_WIDTH-1:0] fc2_sum_shifted;

    assign fc1_sum_shifted = sum_reg >>> FC1_SHIFT;
    assign fc2_sum_shifted = sum_reg >>> FC2_SHIFT;

    // =========================================================
    // INDEX WIRES
    // =========================================================
    wire [4:0] fc1_i0;
    wire [4:0] fc1_i1;
    wire [4:0] fc2_i0;
    wire [4:0] fc2_i1;

    assign fc1_i0 = {fc1_pair[3:0], 1'b0};
    assign fc1_i1 = {fc1_pair[3:0], 1'b0} + 5'd1;

    assign fc2_i0 = {fc2_pair[3:0], 1'b0};
    assign fc2_i1 = {fc2_pair[3:0], 1'b0} + 5'd1;

    wire [IN_WIDTH-1:0] fc1_x0_full;
    wire [IN_WIDTH-1:0] fc1_x1_full;

    assign fc1_x0_full = input_reg[fc1_i0*IN_WIDTH +: IN_WIDTH];
    assign fc1_x1_full = input_reg[fc1_i1*IN_WIDTH +: IN_WIDTH];

    wire signed [ACC_WIDTH-1:0] fc1_bias_ext;
    wire signed [ACC_WIDTH-1:0] fc2_bias_ext;

    assign fc1_bias_ext =
        {{(ACC_WIDTH-BIAS_SIZE){fc1_b[fc1_neuron][BIAS_SIZE-1]}}, fc1_b[fc1_neuron]};

    assign fc2_bias_ext =
        {{(ACC_WIDTH-BIAS_SIZE){fc2_b[fc2_class][BIAS_SIZE-1]}}, fc2_b[fc2_class]};

    wire signed [ACC_WIDTH-1:0] fc1_bias_q;
    wire signed [ACC_WIDTH-1:0] fc2_bias_q;

    assign fc1_bias_q = fc1_bias_ext <<< FRAC_BITS;
    assign fc2_bias_q = fc2_bias_ext <<< FRAC_BITS;

    // =========================================================
    // MAIN FSM
    // =========================================================
    always @(posedge clk) begin
        if (rst) begin
            // Reset hanya control register.
            // Register data besar seperti dout, hidden, input_reg, acc,
            // prod, dan sum tidak di-reset supaya reset fanout kecil.
            state <= S_IDLE;

            valid_out <= 1'b0;
            busy      <= 1'b0;

            fc1_neuron <= 5'd0;
            fc1_pair   <= 5'd0;
            fc2_class  <= 5'd0;
            fc2_pair   <= 5'd0;

            fc1_neuron_dbg <= 5'd0;
            fc2_class_dbg  <= 5'd0;
        end

        else begin
            case (state)

                // =================================================
                // IDLE
                // Tunggu input dari pool3/block3
                // =================================================
                S_IDLE: begin
                    valid_out <= 1'b0;
                    busy      <= 1'b0;

                    if (valid_in) begin
                        input_reg <= din;

                        fc1_neuron <= 5'd0;
                        fc1_pair   <= 5'd0;
                        fc2_class  <= 5'd0;
                        fc2_pair   <= 5'd0;

                        acc  <= {ACC_WIDTH{1'b0}};
                        busy <= 1'b1;

                        state <= S_FC1_LOAD;
                    end
                end

                // =================================================
                // FC1 LOAD
                // Ambil 2 activation + 2 weight + base accumulator
                // =================================================
                S_FC1_LOAD: begin
                    busy <= 1'b1;
                    fc1_neuron_dbg <= fc1_neuron;

                    act0_reg <= $signed({1'b0, quant_input(fc1_x0_full)});
                    act1_reg <= $signed({1'b0, quant_input(fc1_x1_full)});

                    w0_reg <= fc1_w[fc1_neuron*FC1_IN + fc1_i0];
                    w1_reg <= fc1_w[fc1_neuron*FC1_IN + fc1_i1];

                    if (fc1_pair == 0)
                        base_reg <= fc1_bias_q;
                    else
                        base_reg <= acc;

                    phase_fc2_reg  <= 1'b0;
                    target_idx_reg <= fc1_neuron;
                    last_pair_reg  <= (fc1_pair == FC1_PAIRS-1);

                    state <= S_MUL;
                end

                // =================================================
                // FC2 LOAD
                // Ambil 2 hidden activation + 2 weight + base accumulator
                // =================================================
                S_FC2_LOAD: begin
                    busy <= 1'b1;
                    fc2_class_dbg <= fc2_class;

                    act0_reg <= $signed({1'b0, hidden[fc2_i0]});
                    act1_reg <= $signed({1'b0, hidden[fc2_i1]});

                    w0_reg <= fc2_w[fc2_class*FC1_OUT + fc2_i0];
                    w1_reg <= fc2_w[fc2_class*FC1_OUT + fc2_i1];

                    if (fc2_pair == 0)
                        base_reg <= fc2_bias_q;
                    else
                        base_reg <= acc;

                    phase_fc2_reg  <= 1'b1;
                    target_idx_reg <= fc2_class;
                    last_pair_reg  <= (fc2_pair == FC2_PAIRS-1);

                    state <= S_MUL;
                end

                // =================================================
                // MUL
                // 2 DSP aktif di sini
                // =================================================
                S_MUL: begin
                    prod0_reg <= act0_reg * w0_reg;
                    prod1_reg <= act1_reg * w1_reg;

                    state <= S_ACC;
                end

                // =================================================
                // ACC
                // Accumulate dipisah dari multiply supaya timing ringan
                // =================================================
                S_ACC: begin
                    sum_reg <= base_reg + prod0_ext + prod1_ext;

                    state <= S_WRITE;
                end

                // =================================================
                // WRITE / UPDATE COUNTER
                // =================================================
                S_WRITE: begin
                    // ---------------------------------------------
                    // FC1 result path
                    // ---------------------------------------------
                    if (!phase_fc2_reg) begin
                        if (last_pair_reg) begin
                            hidden[target_idx_reg] <= relu_sat_act(fc1_sum_shifted);

                            acc      <= {ACC_WIDTH{1'b0}};
                            fc1_pair <= 5'd0;

                            if (target_idx_reg == FC1_OUT-1) begin
                                fc1_neuron <= 5'd0;
                                fc2_class  <= 5'd0;
                                fc2_pair   <= 5'd0;
                                state      <= S_FC2_LOAD;
                            end
                            else begin
                                fc1_neuron <= target_idx_reg + 5'd1;
                                state      <= S_FC1_LOAD;
                            end
                        end
                        else begin
                            acc      <= sum_reg;
                            fc1_pair <= fc1_pair + 5'd1;
                            state    <= S_FC1_LOAD;
                        end
                    end

                    // ---------------------------------------------
                    // FC2 result path
                    // ---------------------------------------------
                    else begin
                        if (last_pair_reg) begin
                            if (FC2_RELU)
                                dout[target_idx_reg*OUT_WIDTH +: OUT_WIDTH]
                                    <= relu_sat_out(fc2_sum_shifted);
                            else
                                dout[target_idx_reg*OUT_WIDTH +: OUT_WIDTH]
                                    <= raw_out(fc2_sum_shifted);

                            acc      <= {ACC_WIDTH{1'b0}};
                            fc2_pair <= 5'd0;

                            if (target_idx_reg == FC2_OUT-1) begin
                                fc2_class <= 5'd0;
                                valid_out <= 1'b1;
                                busy      <= 1'b0;
                                state     <= S_DONE;
                            end
                            else begin
                                fc2_class <= target_idx_reg + 5'd1;
                                state     <= S_FC2_LOAD;
                            end
                        end
                        else begin
                            acc      <= sum_reg;
                            fc2_pair <= fc2_pair + 5'd1;
                            state    <= S_FC2_LOAD;
                        end
                    end
                end

                // =================================================
                // DONE
                // Output dense valid sampai downstream siap
                // =================================================
                S_DONE: begin
                    busy <= 1'b0;

                    if (ready_in) begin
                        valid_out <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: begin
                    state     <= S_IDLE;
                    valid_out <= 1'b0;
                    busy      <= 1'b0;
                end

            endcase
        end
    end

endmodule