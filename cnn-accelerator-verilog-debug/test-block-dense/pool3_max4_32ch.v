`timescale 1ns / 1ps

module pool3_max4_32ch #(
    parameter CHANNELS  = 32,
    parameter DATA_SIZE = 32
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,
    input wire ready_in,

    input wire [CHANNELS*DATA_SIZE-1:0] din,

    output reg valid_out,
    output reg [CHANNELS*DATA_SIZE-1:0] dout
);

    localparam VECTOR_SIZE = CHANNELS * DATA_SIZE;

    reg [1:0] count;
    reg [VECTOR_SIZE-1:0] max_reg;

    wire output_can_advance;
    assign output_can_advance = (!valid_out) || ready_in;
    assign ready_out = output_can_advance;

    function [VECTOR_SIZE-1:0] max_vec2;
        input [VECTOR_SIZE-1:0] a;
        input [VECTOR_SIZE-1:0] b;
        integer ch;
        reg [DATA_SIZE-1:0] aa;
        reg [DATA_SIZE-1:0] bb;
        begin
            for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                aa = a[ch*DATA_SIZE +: DATA_SIZE];
                bb = b[ch*DATA_SIZE +: DATA_SIZE];
                max_vec2[ch*DATA_SIZE +: DATA_SIZE] = (aa > bb) ? aa : bb;
            end
        end
    endfunction

    wire [VECTOR_SIZE-1:0] next_max;
    assign next_max = (count == 0) ? din : max_vec2(max_reg, din);

    always @(posedge clk) begin
        if (rst) begin
            count     <= 0;
            max_reg   <= 0;
            valid_out <= 0;
            dout      <= 0;
        end

        else begin
            if (valid_out && ready_in) begin
                valid_out <= 1'b0;
            end

            if (output_can_advance) begin
                if (valid_in) begin
                    if (count == 2'd3) begin
                        dout      <= next_max;
                        valid_out <= 1'b1;
                        count     <= 0;
                        max_reg   <= 0;
                    end
                    else begin
                        max_reg <= next_max;
                        count   <= count + 1'b1;
                    end
                end
            end
        end
    end

endmodule