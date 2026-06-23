`timescale 1ns / 1ps

module block2_fifo_shift_register_pool_16ch #(
    parameter WINDOW_SIZE  = 11,  // input conv2 feature map: 11x11
    parameter DATA_SIZE    = 32,
    parameter CHANNELS     = 16,
    parameter TOTAL_WINDOW = 5    // output pool: floor(11/2) = 5
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,

    input wire ready_in,

    // 16 channel packed
    // ch0 = din[31:0]
    // ch1 = din[63:32]
    // ...
    // ch15 = din[511:480]
    input wire [CHANNELS*DATA_SIZE-1:0] din,

    output reg valid_out,

    // 16 channel packed setelah maxpool
    output reg [CHANNELS*DATA_SIZE-1:0] dout
);

    localparam VECTOR_SIZE = CHANNELS * DATA_SIZE;

    assign ready_out = ready_in;

    // Menyimpan horizontal max dari row pertama pada pasangan 2x2
    reg [VECTOR_SIZE-1:0] row0 [0:TOTAL_WINDOW-1];

    reg [VECTOR_SIZE-1:0] hold;
    reg hold_valid;

    reg [$clog2(WINDOW_SIZE):0] col_counter;
    reg [$clog2(WINDOW_SIZE):0] row_counter;
    reg [$clog2(TOTAL_WINDOW+1):0] pool_col;

    // row_odd = 0 -> row pertama dari pasangan pool, simpan horizontal max
    // row_odd = 1 -> row kedua dari pasangan pool, keluarkan vertical max
    reg row_odd;

    integer i;

    // =========================================================
    // MAX VECTOR 16 CHANNEL
    // membandingkan per channel, bukan 512-bit sekaligus
    // =========================================================
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

    wire [VECTOR_SIZE-1:0] hmax_vec;
    wire [VECTOR_SIZE-1:0] vmax_vec;

    assign hmax_vec = max_vec2(hold, din);
    assign vmax_vec = max_vec2(row0[pool_col], hmax_vec);

    always @(posedge clk) begin
        if (rst) begin
            col_counter <= 0;
            row_counter <= 0;
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

                // =================================================
                // HORIZONTAL PAIR
                // col 0 dan 1 -> pool_col 0
                // col 2 dan 3 -> pool_col 1
                // ...
                // col 8 dan 9 -> pool_col 4
                // col 10 dibuang karena 11 ganjil
                // =================================================
                if (!hold_valid) begin
                    hold       <= din;
                    hold_valid <= 1'b1;
                end

                else begin
                    if (pool_col < TOTAL_WINDOW) begin

                        // row pertama dari 2x2
                        // simpan horizontal max
                        if (!row_odd) begin
                            row0[pool_col] <= hmax_vec;
                        end

                        // row kedua dari 2x2
                        // bandingkan dengan row0, lalu output
                        else begin
                            dout      <= vmax_vec;
                            valid_out <= 1'b1;
                        end

                        pool_col <= pool_col + 1'b1;
                    end

                    hold_valid <= 1'b0;
                end

                // =================================================
                // COUNTER 11x11
                // =================================================
                if (col_counter == WINDOW_SIZE - 1) begin
                    col_counter <= 0;
                    pool_col    <= 0;
                    hold_valid  <= 0;

                    if (row_counter == WINDOW_SIZE - 1) begin
                        row_counter <= 0;
                        row_odd     <= 0;
                    end

                    else begin
                        row_counter <= row_counter + 1'b1;
                        row_odd     <= ~row_odd;
                    end
                end

                else begin
                    col_counter <= col_counter + 1'b1;
                end
            end
        end

        // Jika ready_in = 0:
        // semua register ditahan.
    end

endmodule