`timescale 1ns / 1ps

module block1_kernel_mac_unit #(
    parameter DATA_INPUT_SIZE  = 8,
    parameter DATA_OUTPUT_SIZE = 32
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,

    input wire ready_in,

    input wire [DATA_INPUT_SIZE-1:0]
        din0, din1, din2,
        din3, din4, din5,
        din6, din7, din8,

    input wire signed [15:0]
        wk0, wk1, wk2,
        wk3, wk4, wk5,
        wk6, wk7, wk8,
        bias,

    output reg valid_out,
    output reg [DATA_OUTPUT_SIZE-1:0] dout
);

    assign ready_out = ready_in;

    wire signed [8:0] p0 = {1'b0, din0};
    wire signed [8:0] p1 = {1'b0, din1};
    wire signed [8:0] p2 = {1'b0, din2};
    wire signed [8:0] p3 = {1'b0, din3};
    wire signed [8:0] p4 = {1'b0, din4};
    wire signed [8:0] p5 = {1'b0, din5};
    wire signed [8:0] p6 = {1'b0, din6};
    wire signed [8:0] p7 = {1'b0, din7};
    wire signed [8:0] p8 = {1'b0, din8};

    reg [3:0] valid_pipe;

    (* use_dsp = "yes" *)
    reg signed [24:0]
        m0, m1, m2,
        m3, m4, m5,
        m6, m7, m8;

    reg signed [25:0]
        s0, s1, s2, s3;

    reg signed [24:0] s4;

    reg signed [26:0]
        t0, t1;

    reg signed [25:0] t2;

    reg signed [31:0] final_sum;

    always @(posedge clk) begin
        if (rst) begin
            valid_pipe <= 4'b0;
            valid_out  <= 1'b0;
            dout       <= 0;

            m0 <= 0; m1 <= 0; m2 <= 0;
            m3 <= 0; m4 <= 0; m5 <= 0;
            m6 <= 0; m7 <= 0; m8 <= 0;

            s0 <= 0; s1 <= 0; s2 <= 0; s3 <= 0;
            s4 <= 0;

            t0 <= 0; t1 <= 0;
            t2 <= 0;

            final_sum <= 0;
        end

        else if (ready_in) begin

            valid_pipe <= {valid_pipe[2:0], valid_in};

            if (valid_in) begin
                m0 <= p0 * wk0;
                m1 <= p1 * wk1;
                m2 <= p2 * wk2;
                m3 <= p3 * wk3;
                m4 <= p4 * wk4;
                m5 <= p5 * wk5;
                m6 <= p6 * wk6;
                m7 <= p7 * wk7;
                m8 <= p8 * wk8;
            end

            s0 <= m0 + m1;
            s1 <= m2 + m3;
            s2 <= m4 + m5;
            s3 <= m6 + m7;
            s4 <= m8;

            t0 <= s0 + s1;
            t1 <= s2 + s3;
            t2 <= s4;

            final_sum <= t0 + t1 + t2 + bias;

            valid_out <= valid_pipe[3];

            if (valid_pipe[3]) begin
                if (final_sum[31])
                    dout <= 0;
                else
                    dout <= final_sum;
            end
        end

        // jika ready_in = 0:
        // semua register MAC ditahan
    end

endmodule