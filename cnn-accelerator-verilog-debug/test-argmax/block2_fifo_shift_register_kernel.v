`timescale 1ns / 1ps

module block2_fifo_shift_register_kernel #(
    parameter WINDOW_SIZE = 13,
    parameter DATA_SIZE   = 32,
    parameter CHANNELS    = 8
)(
    input wire clk,
    input wire rst,

    // input dari FIFO
    input wire valid_in,
    output wire ready_out,

    // ready dari block setelah kernel ini, misalnya FSM conv2
    input wire ready_in,

    // 8 channel packed menjadi 1 feature vector
    input wire [CHANNELS*DATA_SIZE-1:0] din,

    output reg valid_out,

    // output window 3x3 untuk 8 channel
    // format: channel-major
    // ch0 tap0..tap8, ch1 tap0..tap8, ..., ch7 tap0..tap8
    output reg [CHANNELS*9*DATA_SIZE-1:0] dout
);

    localparam VECTOR_SIZE = CHANNELS * DATA_SIZE;

    integer ch;

    // Setiap elemen row menyimpan 1 posisi spasial berisi 8 channel
    // 1 elemen = 256-bit kalau CHANNELS=8 dan DATA_SIZE=32
    reg [VECTOR_SIZE-1:0] row0 [0:WINDOW_SIZE-1];
    reg [VECTOR_SIZE-1:0] row1 [0:WINDOW_SIZE-1];

    reg [5:0] col_counter;
    reg [5:0] row_counter;

    // Versi sederhana:
    // module ini hanya menerima input baru kalau downstream siap.
    assign ready_out = ready_in;

    always @(posedge clk) begin
        if (rst) begin
            col_counter <= 0;
            row_counter <= 0;

            valid_out <= 0;
            dout      <= 0;
        end

        else if (ready_in) begin

            valid_out <= 0;

            if (valid_in) begin

                // =================================================
                // SHIFT LINE BUFFER
                // =================================================
                row1[col_counter] <= row0[col_counter];
                row0[col_counter] <= din;

                // =================================================
                // BENTUK WINDOW 3x3 UNTUK SETIAP CHANNEL
                // =================================================
                for (ch = 0; ch < CHANNELS; ch = ch + 1) begin

                    // TOP ROW
                    // tap0 tap1 tap2
                    dout[(ch*9 + 0)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 1)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 1)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 2)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 2)*DATA_SIZE +: DATA_SIZE] <= row1[col_counter][ch*DATA_SIZE +: DATA_SIZE];

                    // MIDDLE ROW
                    // tap3 tap4 tap5
                    dout[(ch*9 + 3)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 4)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 4)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 5)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 5)*DATA_SIZE +: DATA_SIZE] <= row0[col_counter][ch*DATA_SIZE +: DATA_SIZE];

                    // BOTTOM ROW
                    // tap6 tap7 tap8
                    dout[(ch*9 + 6)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 7)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 7)*DATA_SIZE +: DATA_SIZE] <= dout[(ch*9 + 8)*DATA_SIZE +: DATA_SIZE];
                    dout[(ch*9 + 8)*DATA_SIZE +: DATA_SIZE] <= din[ch*DATA_SIZE +: DATA_SIZE];

                end

                // =================================================
                // VALID WINDOW
                // Untuk input 13x13, window valid mulai dari:
                // row >= 2 dan col >= 2
                // Output conv valid size = 11x11
                // =================================================
                if ((row_counter >= 2) && (col_counter >= 2)) begin
                    valid_out <= 1'b1;
                end

                // =================================================
                // COUNTER FEATURE MAP 13x13
                // =================================================
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

        // Jika ready_in = 0:
        // semua register ditahan.
        // FIFO juga ikut tertahan karena ready_out = 0.
    end

endmodule