`timescale 1ns / 1ps

module block1_fifo_shift_register_pool #(
    parameter WINDOW_SIZE = 26,
    parameter DATA_SIZE = 32,
    parameter TOTAL_WINDOW = 13
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,

    input wire ready_in,

    input wire [DATA_SIZE-1:0] din,

    output reg valid_out,
    output reg [DATA_SIZE-1:0] dout
);

    assign ready_out = ready_in;

    reg [DATA_SIZE-1:0] row0 [0:TOTAL_WINDOW-1];

    integer i;

    reg [$clog2(WINDOW_SIZE):0] col_counter;
    reg [$clog2(TOTAL_WINDOW):0] pool_col;

    reg row_odd;

    reg [DATA_SIZE-1:0] hold;
    reg hold_valid;

    function [DATA_SIZE-1:0] max2;
        input [DATA_SIZE-1:0] a;
        input [DATA_SIZE-1:0] b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    wire [DATA_SIZE-1:0] hmax_val;
    wire [DATA_SIZE-1:0] vmax_val;

    assign hmax_val = max2(hold, din);
    assign vmax_val = max2(row0[pool_col], hmax_val);

    always @(posedge clk) begin
        if (rst) begin
            col_counter <= 0;
            pool_col    <= 0;
            row_odd     <= 0;

            hold        <= 0;
            hold_valid  <= 0;

            valid_out   <= 0;
            dout        <= 0;

            for (i = 0; i < TOTAL_WINDOW; i = i + 1) begin
                row0[i] <= 0;
            end
        end

        else if (ready_in) begin

            valid_out <= 0;

            if (valid_in) begin

                if (!hold_valid) begin
                    hold       <= din;
                    hold_valid <= 1'b1;
                end

                else begin
                    if (pool_col < TOTAL_WINDOW) begin

                        if (!row_odd) begin
                            row0[pool_col] <= hmax_val;
                        end

                        else begin
                            dout      <= vmax_val;
                            valid_out <= 1'b1;
                        end

                        pool_col <= pool_col + 1'b1;
                    end

                    hold_valid <= 1'b0;
                end

                if (col_counter == WINDOW_SIZE - 1) begin
                    col_counter <= 0;
                    pool_col    <= 0;
                    row_odd     <= ~row_odd;
                    hold_valid  <= 0;
                end

                else begin
                    col_counter <= col_counter + 1'b1;
                end
            end
        end

        // jika ready_in = 0:
        // semua register pool ditahan
    end

endmodule