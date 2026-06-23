`timescale 1ns / 1ps

module vga_from_fifo_rgb565 (
    input  wire        vga_clk,
    input  wire        rst,

    input  wire [15:0] fifo_dout,
    input  wire        fifo_empty,
    input  wire        fifo_valid,
    input  wire        fifo_rd_rst_busy,
    output wire        fifo_rd_en,

    input  wire [3:0]  class_out,

    output reg  [3:0]  vga_r,
    output reg  [3:0]  vga_g,
    output reg  [3:0]  vga_b,
    output reg         vga_hs,
    output reg         vga_vs,
    
    output reg vga_vblank_start = 1'b0,
    output reg vga_frame_start  = 1'b0
);

    // =========================================================
    // VGA 640x480 @ 60 Hz Timing
    // =========================================================
    localparam H_VISIBLE = 640;
    localparam H_FRONT   = 16;
    localparam H_SYNC    = 96;
    localparam H_BACK    = 48;
    localparam H_TOTAL   = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;

    localparam V_VISIBLE = 480;
    localparam V_FRONT   = 10;
    localparam V_SYNC    = 2;
    localparam V_BACK    = 33;
    localparam V_TOTAL   = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

    reg [9:0] h_cnt = 10'd0;
    reg [9:0] v_cnt = 10'd0;

    wire active_video;
    assign active_video = (h_cnt < H_VISIBLE) && (v_cnt < V_VISIBLE);

    always @(posedge vga_clk) begin
        if (rst) begin
            h_cnt <= 10'd0;
            v_cnt <= 10'd0;
        end else begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 10'd0;

                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 10'd0;
                else
                    v_cnt <= v_cnt + 1'b1;
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    // VGA sync active-low
    always @(posedge vga_clk) begin
        if (rst) begin
            vga_hs <= 1'b1;
            vga_vs <= 1'b1;
        end else begin
            vga_hs <= ~((h_cnt >= H_VISIBLE + H_FRONT) &&
                        (h_cnt <  H_VISIBLE + H_FRONT + H_SYNC));

            vga_vs <= ~((v_cnt >= V_VISIBLE + V_FRONT) &&
                        (v_cnt <  V_VISIBLE + V_FRONT + V_SYNC));
        end
    end
    
    always @(posedge vga_clk) begin
        if (rst) begin
            vga_vblank_start <= 1'b0;
            vga_frame_start  <= 1'b0;
        end else begin
            vga_vblank_start <= 1'b0;
            vga_frame_start  <= 1'b0;
    
            // awal active frame, ini bukan yang utama untuk DDR read
            if ((h_cnt == 10'd0) && (v_cnt == 10'd0))
                vga_frame_start <= 1'b1;
    
            // awal vertical blank, ini yang bagus untuk mulai DDR read
            if ((h_cnt == 10'd0) && (v_cnt == V_VISIBLE))
                vga_vblank_start <= 1'b1;
        end
    end

    // =========================================================
    // FIFO Read
    // =========================================================
    assign fifo_rd_en = active_video &&
                        !fifo_empty &&
                        !fifo_rd_rst_busy;

    // =========================================================
    // RGB565 to RGB444
    // =========================================================
    wire [3:0] pixel_r;
    wire [3:0] pixel_g;
    wire [3:0] pixel_b;

    assign pixel_r = fifo_valid ? fifo_dout[15:12] : 4'h0;
    assign pixel_g = fifo_valid ? fifo_dout[10:7]  : 4'h0;
    assign pixel_b = fifo_valid ? fifo_dout[4:1]   : 4'h0;

    // =========================================================
    // Synchronize class_out to VGA clock domain
    // =========================================================
    reg [3:0] class_meta = 4'd0;
    reg [3:0] class_vga  = 4'd0;

    always @(posedge vga_clk) begin
        if (rst) begin
            class_meta <= 4'd0;
            class_vga  <= 4'd0;
        end else begin
            class_meta <= class_out;
            class_vga  <= class_meta;
        end
    end

    // =========================================================
    // ROI Box 280x280 Center
    // =========================================================
    localparam ROI_W = 280;
    localparam ROI_H = 280;

    localparam ROI_X0 = (H_VISIBLE - ROI_W) / 2; // 180
    localparam ROI_Y0 = (V_VISIBLE - ROI_H) / 2; // 100

    localparam ROI_X1 = ROI_X0 + ROI_W - 1;      // 459
    localparam ROI_Y1 = ROI_Y0 + ROI_H - 1;      // 379

    localparam BORDER_THICK = 2;

    wire in_roi_x;
    wire in_roi_y;
    wire roi_border;

    assign in_roi_x = (h_cnt >= ROI_X0) && (h_cnt <= ROI_X1);
    assign in_roi_y = (v_cnt >= ROI_Y0) && (v_cnt <= ROI_Y1);

    assign roi_border =
        active_video &&
        in_roi_x &&
        in_roi_y &&
        (
            (h_cnt < ROI_X0 + BORDER_THICK) ||
            (h_cnt > ROI_X1 - BORDER_THICK) ||
            (v_cnt < ROI_Y0 + BORDER_THICK) ||
            (v_cnt > ROI_Y1 - BORDER_THICK)
        );

    // =========================================================
    // Text Overlay: "PREDICTION: X"
    // =========================================================
    localparam TEXT_SCALE = 2;
    localparam FONT_W     = 8;
    localparam FONT_H     = 8;
    localparam CHAR_W     = FONT_W * TEXT_SCALE; // 16
    localparam CHAR_H     = FONT_H * TEXT_SCALE; // 16
    localparam TEXT_LEN   = 13; // P R E D I C T I O N : space digit

    localparam TEXT_X0 = ROI_X0;
    localparam TEXT_Y0 = ROI_Y0 - 22;

    wire text_area;
    assign text_area =
        active_video &&
        (h_cnt >= TEXT_X0) &&
        (h_cnt <  TEXT_X0 + TEXT_LEN * CHAR_W) &&
        (v_cnt >= TEXT_Y0) &&
        (v_cnt <  TEXT_Y0 + CHAR_H);

    wire [9:0] text_local_x;
    wire [9:0] text_local_y;

    assign text_local_x = h_cnt - TEXT_X0;
    assign text_local_y = v_cnt - TEXT_Y0;

    wire [3:0] text_char_idx;
    wire [2:0] font_col;
    wire [2:0] font_row;

    assign text_char_idx = text_local_x[9:4]; // /16
    assign font_col      = text_local_x[3:1]; // scale 2
    assign font_row      = text_local_y[3:1]; // scale 2

    wire [7:0] current_char;
    wire [7:0] font_bits;
    wire       font_pixel;

    assign current_char = get_text_char(text_char_idx, class_vga);
    assign font_bits    = font8x8(current_char, font_row);
    assign font_pixel   = text_area && ((font_bits & (8'h80 >> font_col)) != 8'd0);

    // =========================================================
    // Final Pixel Priority
    // Priority:
    // 1. Text
    // 2. ROI Border
    // 3. Camera Pixel
    // =========================================================
    always @(posedge vga_clk) begin
        if (rst) begin
            vga_r <= 4'h0;
            vga_g <= 4'h0;
            vga_b <= 4'h0;
        end else begin
            if (!active_video) begin
                vga_r <= 4'h0;
                vga_g <= 4'h0;
                vga_b <= 4'h0;
            end else if (font_pixel) begin
                // White text
                vga_r <= 4'hF;
                vga_g <= 4'hF;
                vga_b <= 4'hF;
            end else if (roi_border) begin
                // Green ROI border
                vga_r <= 4'h0;
                vga_g <= 4'hF;
                vga_b <= 4'h0;
            end else begin
                // Original camera pixel
                vga_r <= pixel_r;
                vga_g <= pixel_g;
                vga_b <= pixel_b;
            end
        end
    end

    // =========================================================
    // Text Character Selector
    // "PREDICTION: X"
    // =========================================================
    function [7:0] get_text_char;
        input [3:0] idx;
        input [3:0] digit;
        begin
            case (idx)
                4'd0:  get_text_char = 8'h50; // P
                4'd1:  get_text_char = 8'h52; // R
                4'd2:  get_text_char = 8'h45; // E
                4'd3:  get_text_char = 8'h44; // D
                4'd4:  get_text_char = 8'h49; // I
                4'd5:  get_text_char = 8'h43; // C
                4'd6:  get_text_char = 8'h54; // T
                4'd7:  get_text_char = 8'h49; // I
                4'd8:  get_text_char = 8'h4F; // O
                4'd9:  get_text_char = 8'h4E; // N
                4'd10: get_text_char = 8'h3A; // :
                4'd11: get_text_char = 8'h20; // space
                4'd12: begin
                    if (digit <= 4'd9)
                        get_text_char = 8'h30 + {4'b0000, digit};
                    else
                        get_text_char = 8'h3F; // ?
                end
                default: get_text_char = 8'h20;
            endcase
        end
    endfunction

    // =========================================================
    // Minimal 8x8 Font ROM
    // Only characters needed:
    // P R E D I C T O N : space ? 0-9
    // =========================================================
    function [7:0] font8x8;
        input [7:0] ch;
        input [2:0] row;
        begin
            case (ch)

                // Space
                8'h20: begin
                    font8x8 = 8'b00000000;
                end

                // :
                8'h3A: begin
                    case (row)
                        3'd0: font8x8 = 8'b00000000;
                        3'd1: font8x8 = 8'b00011000;
                        3'd2: font8x8 = 8'b00011000;
                        3'd3: font8x8 = 8'b00000000;
                        3'd4: font8x8 = 8'b00000000;
                        3'd5: font8x8 = 8'b00011000;
                        3'd6: font8x8 = 8'b00011000;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // ?
                8'h3F: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b00000110;
                        3'd3: font8x8 = 8'b00001100;
                        3'd4: font8x8 = 8'b00011000;
                        3'd5: font8x8 = 8'b00000000;
                        3'd6: font8x8 = 8'b00011000;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 0
                8'h30: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01101110;
                        3'd3: font8x8 = 8'b01110110;
                        3'd4: font8x8 = 8'b01100110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 1
                8'h31: begin
                    case (row)
                        3'd0: font8x8 = 8'b00011000;
                        3'd1: font8x8 = 8'b00111000;
                        3'd2: font8x8 = 8'b00011000;
                        3'd3: font8x8 = 8'b00011000;
                        3'd4: font8x8 = 8'b00011000;
                        3'd5: font8x8 = 8'b00011000;
                        3'd6: font8x8 = 8'b01111110;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 2
                8'h32: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b00000110;
                        3'd3: font8x8 = 8'b00001100;
                        3'd4: font8x8 = 8'b00110000;
                        3'd5: font8x8 = 8'b01100000;
                        3'd6: font8x8 = 8'b01111110;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 3
                8'h33: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b00000110;
                        3'd3: font8x8 = 8'b00011100;
                        3'd4: font8x8 = 8'b00000110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 4
                8'h34: begin
                    case (row)
                        3'd0: font8x8 = 8'b00001100;
                        3'd1: font8x8 = 8'b00011100;
                        3'd2: font8x8 = 8'b00101100;
                        3'd3: font8x8 = 8'b01001100;
                        3'd4: font8x8 = 8'b01111110;
                        3'd5: font8x8 = 8'b00001100;
                        3'd6: font8x8 = 8'b00001100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 5
                8'h35: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111110;
                        3'd1: font8x8 = 8'b01100000;
                        3'd2: font8x8 = 8'b01111100;
                        3'd3: font8x8 = 8'b00000110;
                        3'd4: font8x8 = 8'b00000110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 6
                8'h36: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100000;
                        3'd3: font8x8 = 8'b01111100;
                        3'd4: font8x8 = 8'b01100110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 7
                8'h37: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111110;
                        3'd1: font8x8 = 8'b00000110;
                        3'd2: font8x8 = 8'b00001100;
                        3'd3: font8x8 = 8'b00011000;
                        3'd4: font8x8 = 8'b00110000;
                        3'd5: font8x8 = 8'b00110000;
                        3'd6: font8x8 = 8'b00110000;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 8
                8'h38: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100110;
                        3'd3: font8x8 = 8'b00111100;
                        3'd4: font8x8 = 8'b01100110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // 9
                8'h39: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100110;
                        3'd3: font8x8 = 8'b00111110;
                        3'd4: font8x8 = 8'b00000110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // C
                8'h43: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100000;
                        3'd3: font8x8 = 8'b01100000;
                        3'd4: font8x8 = 8'b01100000;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // D
                8'h44: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111000;
                        3'd1: font8x8 = 8'b01101100;
                        3'd2: font8x8 = 8'b01100110;
                        3'd3: font8x8 = 8'b01100110;
                        3'd4: font8x8 = 8'b01100110;
                        3'd5: font8x8 = 8'b01101100;
                        3'd6: font8x8 = 8'b01111000;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // E
                8'h45: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111110;
                        3'd1: font8x8 = 8'b01100000;
                        3'd2: font8x8 = 8'b01100000;
                        3'd3: font8x8 = 8'b01111100;
                        3'd4: font8x8 = 8'b01100000;
                        3'd5: font8x8 = 8'b01100000;
                        3'd6: font8x8 = 8'b01111110;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // I
                8'h49: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111110;
                        3'd1: font8x8 = 8'b00011000;
                        3'd2: font8x8 = 8'b00011000;
                        3'd3: font8x8 = 8'b00011000;
                        3'd4: font8x8 = 8'b00011000;
                        3'd5: font8x8 = 8'b00011000;
                        3'd6: font8x8 = 8'b01111110;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // N
                8'h4E: begin
                    case (row)
                        3'd0: font8x8 = 8'b01100010;
                        3'd1: font8x8 = 8'b01110010;
                        3'd2: font8x8 = 8'b01111010;
                        3'd3: font8x8 = 8'b01101110;
                        3'd4: font8x8 = 8'b01100110;
                        3'd5: font8x8 = 8'b01100010;
                        3'd6: font8x8 = 8'b01100010;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // O
                8'h4F: begin
                    case (row)
                        3'd0: font8x8 = 8'b00111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100110;
                        3'd3: font8x8 = 8'b01100110;
                        3'd4: font8x8 = 8'b01100110;
                        3'd5: font8x8 = 8'b01100110;
                        3'd6: font8x8 = 8'b00111100;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // P
                8'h50: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100110;
                        3'd3: font8x8 = 8'b01111100;
                        3'd4: font8x8 = 8'b01100000;
                        3'd5: font8x8 = 8'b01100000;
                        3'd6: font8x8 = 8'b01100000;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // R
                8'h52: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111100;
                        3'd1: font8x8 = 8'b01100110;
                        3'd2: font8x8 = 8'b01100110;
                        3'd3: font8x8 = 8'b01111100;
                        3'd4: font8x8 = 8'b01111000;
                        3'd5: font8x8 = 8'b01101100;
                        3'd6: font8x8 = 8'b01100110;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                // T
                8'h54: begin
                    case (row)
                        3'd0: font8x8 = 8'b01111110;
                        3'd1: font8x8 = 8'b00011000;
                        3'd2: font8x8 = 8'b00011000;
                        3'd3: font8x8 = 8'b00011000;
                        3'd4: font8x8 = 8'b00011000;
                        3'd5: font8x8 = 8'b00011000;
                        3'd6: font8x8 = 8'b00011000;
                        3'd7: font8x8 = 8'b00000000;
                    endcase
                end

                default: begin
                    font8x8 = 8'b00000000;
                end
            endcase
        end
    endfunction

endmodule