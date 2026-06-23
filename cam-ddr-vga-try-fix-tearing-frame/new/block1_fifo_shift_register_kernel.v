`timescale 1ns / 1ps

module block1_fifo_shift_register_kernel #(
    parameter WINDOW_SIZE = 28,
    parameter DATA_SIZE   = 8
)(
    input  wire clk,
    input  wire rst,

    // dari module sebelumnya: stream_safe_28x28
    input  wire valid_in,
    output wire ready_out,
    input  wire [DATA_SIZE-1:0] din,

    // ke module berikutnya: conv
    output reg  valid_out,
    input  wire ready_in,

    output reg [DATA_SIZE-1:0]
        dout0,dout1,dout2,
        dout3,dout4,dout5,
        dout6,dout7,dout8
);

    reg [DATA_SIZE-1:0] row0 [0:WINDOW_SIZE-1];
    reg [DATA_SIZE-1:0] row1 [0:WINDOW_SIZE-1];

    integer i;

    reg [5:0] col_counter;
    reg [5:0] row_counter;

    reg [DATA_SIZE-1:0] px_row0;
    reg [DATA_SIZE-1:0] px_row1;

    /*
        Backpressure sederhana:

        Kalau conv siap menerima window baru:
            ready_in = 1
            ready_out = 1
            kernel boleh menerima pixel baru dari stream

        Kalau conv sibuk:
            ready_in = 0
            ready_out = 0
            kernel berhenti
            stream juga ikut berhenti
    */
    assign ready_out = ready_in;

    wire fire;
    assign fire = valid_in && ready_out;

    always @(posedge clk) begin
        if (rst) begin
            col_counter <= 0;
            row_counter <= 0;

            valid_out <= 0;

            dout0 <= 0; dout1 <= 0; dout2 <= 0;
            dout3 <= 0; dout4 <= 0; dout5 <= 0;
            dout6 <= 0; dout7 <= 0; dout8 <= 0;

            px_row0 <= 0;
            px_row1 <= 0;

            for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                row0[i] <= 0;
                row1[i] <= 0;
            end

        end else begin

            if (fire) begin

                // ambil pixel dari dua baris sebelumnya
                px_row0 = row0[col_counter];
                px_row1 = row1[col_counter];

                // update line buffer
                row1[col_counter] <= row0[col_counter];
                row0[col_counter] <= din;

                // geser window 3x3
                dout0 <= dout1;
                dout1 <= dout2;
                dout2 <= px_row1;

                dout3 <= dout4;
                dout4 <= dout5;
                dout5 <= px_row0;

                dout6 <= dout7;
                dout7 <= dout8;
                dout8 <= din;

                // window valid setelah minimal baris ke-2 dan kolom ke-2
                if (row_counter >= 2 && col_counter >= 2)
                    valid_out <= 1'b1;
                else
                    valid_out <= 1'b0;

                // update posisi pixel
                if (col_counter == WINDOW_SIZE-1) begin
                    col_counter <= 0;
                    row_counter <= row_counter + 1'b1;
                end else begin
                    col_counter <= col_counter + 1'b1;
                end
            end

            else if (!valid_in && ready_out) begin
                valid_out <= 1'b0;
            end

            // kalau ready_out = 0:
            // semua register HOLD
            // dout tetap
            // valid_out tetap
            // counter tetap
        end
    end

endmodule