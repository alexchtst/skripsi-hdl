`timescale 1ns / 1ps

// ============================================================
// DENSE BLOCK WRAPPER
// Input  : pool3 output = 1x1x32
// Process: FC1 + FC2 memakai fc1_fc2_2dsp
// Output : 10 class score
// ============================================================

(* keep_hierarchy = "yes" *)
module dense_block #(
    parameter IN_WIDTH    = 32,
    parameter ACT_SIZE    = 24,
    parameter WEIGHT_SIZE = 16,
    parameter BIAS_SIZE   = 32,
    parameter ACC_WIDTH   = 64,

    parameter FC1_IN      = 32,
    parameter FC1_OUT     = 16,
    parameter FC2_OUT     = 10,
    parameter OUT_WIDTH   = 32,

    parameter INPUT_SHIFT = 0,
    parameter FC1_SHIFT   = 14,
    parameter FC2_SHIFT   = 14,
    parameter FC2_RELU    = 1
)(
    input  wire clk,
    input  wire rst,

    input  wire valid_in,
    output wire ready_out,
    input  wire [FC1_IN*IN_WIDTH-1:0] din,

    input  wire ready_in,

    output wire valid_out,
    output wire [FC2_OUT*OUT_WIDTH-1:0] dout,

    // debug opsional
    output wire busy,
    output wire [4:0] fc1_neuron_dbg,
    output wire [4:0] fc2_class_dbg
);

    fc1_fc2_2dsp #(
        .IN_WIDTH(IN_WIDTH),
        .ACT_SIZE(ACT_SIZE),
        .WEIGHT_SIZE(WEIGHT_SIZE),
        .BIAS_SIZE(BIAS_SIZE),
        .ACC_WIDTH(ACC_WIDTH),

        .FC1_IN(FC1_IN),
        .FC1_OUT(FC1_OUT),
        .FC2_OUT(FC2_OUT),
        .OUT_WIDTH(OUT_WIDTH),

        .INPUT_SHIFT(INPUT_SHIFT),
        .FC1_SHIFT(FC1_SHIFT),
        .FC2_SHIFT(FC2_SHIFT),
        .FC2_RELU(FC2_RELU)
    ) u_fc1_fc2_2dsp (
        .clk(clk),
        .rst(rst),

        .valid_in(valid_in),
        .ready_out(ready_out),

        .ready_in(ready_in),

        .din(din),

        .valid_out(valid_out),
        .dout(dout),

        .busy(busy),
        .fc1_neuron_dbg(fc1_neuron_dbg),
        .fc2_class_dbg(fc2_class_dbg)
    );

endmodule