`timescale 1ns / 1ps

module argmax10_u32 #(
    parameter WORD_WIDTH  = 32,
    parameter NUM_CLASSES = 10
)(
    input  wire clk,
    input  wire rst,
    input  wire valid_in,
    input  wire [NUM_CLASSES*WORD_WIDTH-1:0] din,
    output reg  [3:0] class_out
);

    // =========================================================
    // Unpack input
    // =========================================================
    wire [WORD_WIDTH-1:0] x0 = din[0*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x1 = din[1*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x2 = din[2*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x3 = din[3*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x4 = din[4*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x5 = din[5*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x6 = din[6*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x7 = din[7*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x8 = din[8*WORD_WIDTH +: WORD_WIDTH];
    wire [WORD_WIDTH-1:0] x9 = din[9*WORD_WIDTH +: WORD_WIDTH];

    // =========================================================
    // Stage 1: bandingkan pasangan
    // 10 class -> 5 pemenang
    // =========================================================
    reg [WORD_WIDTH-1:0] s1_val0, s1_val1, s1_val2, s1_val3, s1_val4;
    reg [3:0]            s1_idx0, s1_idx1, s1_idx2, s1_idx3, s1_idx4;
    reg                  s1_valid;

    // =========================================================
    // Stage 2: 5 pemenang -> 3 pemenang
    // =========================================================
    reg [WORD_WIDTH-1:0] s2_val0, s2_val1, s2_val2;
    reg [3:0]            s2_idx0, s2_idx1, s2_idx2;
    reg                  s2_valid;

    // =========================================================
    // Stage 3: 3 pemenang -> 2 pemenang
    // =========================================================
    reg [WORD_WIDTH-1:0] s3_val0, s3_val1;
    reg [3:0]            s3_idx0, s3_idx1;
    reg                  s3_valid;

    // =========================================================
    // Stage 4: final compare
    // =========================================================
    reg                  s4_valid;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
            class_out <= 4'd0;
        end
        else begin
            // =================================================
            // Stage 1
            // =================================================
            s1_valid <= valid_in;

            if (x1 > x0) begin
                s1_val0 <= x1;
                s1_idx0 <= 4'd1;
            end
            else begin
                s1_val0 <= x0;
                s1_idx0 <= 4'd0;
            end

            if (x3 > x2) begin
                s1_val1 <= x3;
                s1_idx1 <= 4'd3;
            end
            else begin
                s1_val1 <= x2;
                s1_idx1 <= 4'd2;
            end

            if (x5 > x4) begin
                s1_val2 <= x5;
                s1_idx2 <= 4'd5;
            end
            else begin
                s1_val2 <= x4;
                s1_idx2 <= 4'd4;
            end

            if (x7 > x6) begin
                s1_val3 <= x7;
                s1_idx3 <= 4'd7;
            end
            else begin
                s1_val3 <= x6;
                s1_idx3 <= 4'd6;
            end

            if (x9 > x8) begin
                s1_val4 <= x9;
                s1_idx4 <= 4'd9;
            end
            else begin
                s1_val4 <= x8;
                s1_idx4 <= 4'd8;
            end

            // =================================================
            // Stage 2
            // =================================================
            s2_valid <= s1_valid;

            if (s1_val1 > s1_val0) begin
                s2_val0 <= s1_val1;
                s2_idx0 <= s1_idx1;
            end
            else begin
                s2_val0 <= s1_val0;
                s2_idx0 <= s1_idx0;
            end

            if (s1_val3 > s1_val2) begin
                s2_val1 <= s1_val3;
                s2_idx1 <= s1_idx3;
            end
            else begin
                s2_val1 <= s1_val2;
                s2_idx1 <= s1_idx2;
            end

            // class 8/9 pair langsung lewat
            s2_val2 <= s1_val4;
            s2_idx2 <= s1_idx4;

            // =================================================
            // Stage 3
            // =================================================
            s3_valid <= s2_valid;

            if (s2_val1 > s2_val0) begin
                s3_val0 <= s2_val1;
                s3_idx0 <= s2_idx1;
            end
            else begin
                s3_val0 <= s2_val0;
                s3_idx0 <= s2_idx0;
            end

            s3_val1 <= s2_val2;
            s3_idx1 <= s2_idx2;

            // =================================================
            // Stage 4 final
            // =================================================
            s4_valid <= s3_valid;

            if (s3_valid) begin
                if (s3_val1 > s3_val0) begin
                    class_out <= s3_idx1;
                end
                else begin
                    class_out <= s3_idx0;
                end
            end
        end
    end

endmodule