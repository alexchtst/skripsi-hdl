`timescale 1ns / 1ps

module cdc_bit_sync (
    input  wire clk,
    input  wire rst,
    input  wire async_in,
    output wire sync_out
);

    (* ASYNC_REG = "TRUE" *) reg sync1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg sync2 = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            sync1 <= 1'b0;
            sync2 <= 1'b0;
        end else begin
            sync1 <= async_in;
            sync2 <= sync1;
        end
    end

    assign sync_out = sync2;

endmodule