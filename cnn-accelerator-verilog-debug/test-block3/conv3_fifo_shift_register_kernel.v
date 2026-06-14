`timescale 1ns / 1ps

module conv3_fifo_shift_register_kernel #(
    parameter WINDOW_SIZE = 5,
    parameter DATA_SIZE   = 32,
    parameter CHANNELS    = 16,
    // 1 = hanya keluarkan 4 window conv3 yang dipakai oleh pool3 2x2
    //     ending position: (2,2), (2,3), (3,2), (3,3)
    // 0 = keluarkan semua 9 window conv3 dari feature map 5x5
    parameter ONLY_POOL3_WINDOWS = 1
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,

    input wire ready_in,

    input wire [CHANNELS*DATA_SIZE-1:0] din,

    output reg valid_out,
    output reg [CHANNELS*9*DATA_SIZE-1:0] dout
);

    localparam VECTOR_SIZE = CHANNELS * DATA_SIZE;

    integer ch;

    reg [VECTOR_SIZE-1:0] row0 [0:WINDOW_SIZE-1];
    reg [VECTOR_SIZE-1:0] row1 [0:WINDOW_SIZE-1];

    reg [5:0] col_counter;
    reg [5:0] row_counter;

    wire window_full;
    wire window_used_by_pool3;

    assign ready_out = ready_in;

    assign window_full = (row_counter >= 2) && (col_counter >= 2);

    assign window_used_by_pool3 =
        window_full &&
        (row_counter <= 3) &&
        (col_counter <= 3);

    always @(posedge clk) begin
        if (rst) begin
            col_counter <= 0;
            row_counter <= 0;
            valid_out   <= 0;
            dout        <= 0;
        end

        else if (ready_in) begin
            valid_out <= 0;

            if (valid_in) begin
                row1[col_counter] <= row0[col_counter];
                row0[col_counter] <= din;

                for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                    // top row taps 0,1,2
                    dout[(ch*9 + 0)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 1)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 1)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 2)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 2)*DATA_SIZE +: DATA_SIZE] <= row1[col_counter][ch*DATA_SIZE +: DATA_SIZE];

                    // middle row taps 3,4,5
                    dout[(ch*9 + 3)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 4)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 4)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 5)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 5)*DATA_SIZE +: DATA_SIZE] <= row0[col_counter][ch*DATA_SIZE +: DATA_SIZE];

                    // bottom row taps 6,7,8
                    dout[(ch*9 + 6)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 7)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 7)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 8)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 8)*DATA_SIZE +: DATA_SIZE] <= din[ch*DATA_SIZE +: DATA_SIZE];
                end

                if (ONLY_POOL3_WINDOWS) begin
                    valid_out <= window_used_by_pool3;
                end
                else begin
                    valid_out <= window_full;
                end

                if (col_counter == WINDOW_SIZE - 1) begin
                    col_counter <= 0;

                    if (row_counter == WINDOW_SIZE - 1)
                        row_counter <= 0;
                    else
                        row_counter <= row_counter + 1'b1;
                end
                else begin
                    col_counter <= col_counter + 1'b1;
                end
            end
        end
    end

endmodule