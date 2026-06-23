`timescale 1ns / 1ps

module block1_weight_rom(
    input wire clk,
    input wire [2:0] filter_idx,
    output reg signed [15:0] w0,w1,w2,w3,w4,w5,w6,w7,w8,
    output reg signed [15:0] bias
);

    reg signed [15:0] W [0:71];
    reg signed [15:0] B [0:7];

    initial begin
        $readmemh("conv1_w.mem", W);
        $readmemh("conv1_b.mem", B);
    end

    wire [6:0] base = filter_idx * 9;

    always @(posedge clk) begin
        w0   <= W[base+0];
        w1   <= W[base+1];
        w2   <= W[base+2];
        w3   <= W[base+3];
        w4   <= W[base+4];
        w5   <= W[base+5];
        w6   <= W[base+6];
        w7   <= W[base+7];
        w8   <= W[base+8];
        bias <= B[filter_idx];
    end

endmodule

