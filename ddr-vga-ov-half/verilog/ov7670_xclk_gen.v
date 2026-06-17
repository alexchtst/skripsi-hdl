`timescale 1ns / 1ps

module ov7670_xclk_gen(
    input  wire clk_100mhz,
    input  wire rst,
    output reg  xclk
);

    reg [1:0] div_cnt = 2'd0;

    always @(posedge clk_100mhz) begin
        if (rst) begin
            div_cnt <= 2'd0;
            xclk    <= 1'b0;
        end else begin
            div_cnt <= div_cnt + 1'b1;

            // Toggle setiap 2 clock 100 MHz.
            // Jadi periode output = 4 clock 100 MHz = 40 ns.
            // Frekuensi = 25 MHz.
            if (div_cnt == 2'd1) begin
                xclk <= ~xclk;
            end
        end
    end

endmodule