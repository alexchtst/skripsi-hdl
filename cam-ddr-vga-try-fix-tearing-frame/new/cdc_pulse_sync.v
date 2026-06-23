`timescale 1ns / 1ps

module cdc_pulse_sync (
    input  wire src_clk,
    input  wire src_rst,
    input  wire src_pulse,

    input  wire dst_clk,
    input  wire dst_rst,
    output wire dst_pulse
);

    reg src_toggle = 1'b0;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_toggle <= 1'b0;
        end else if (src_pulse) begin
            src_toggle <= ~src_toggle;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg dst_sync1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg dst_sync2 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg dst_sync3 = 1'b0;

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_sync1 <= 1'b0;
            dst_sync2 <= 1'b0;
            dst_sync3 <= 1'b0;
        end else begin
            dst_sync1 <= src_toggle;
            dst_sync2 <= dst_sync1;
            dst_sync3 <= dst_sync2;
        end
    end

    assign dst_pulse = dst_sync2 ^ dst_sync3;

endmodule