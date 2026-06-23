`timescale 1ns / 1ps

module cdc_event_sync (
    input  wire src_clk,
    input  wire src_rst,
    input  wire src_signal,

    input  wire dst_clk,
    input  wire dst_rst,
    output wire dst_pulse
);

    reg src_signal_d = 1'b0;
    reg src_toggle   = 1'b0;

    wire src_rise;
    assign src_rise = src_signal & ~src_signal_d;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_signal_d <= 1'b0;
            src_toggle   <= 1'b0;
        end else begin
            src_signal_d <= src_signal;

            if (src_rise) begin
                src_toggle <= ~src_toggle;
            end
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
