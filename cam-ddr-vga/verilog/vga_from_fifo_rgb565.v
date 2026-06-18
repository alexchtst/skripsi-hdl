`timescale 1ns / 1ps

module vga_from_fifo_rgb565 (
    input  wire        vga_clk,
    input  wire        rst,

    input  wire [15:0] fifo_dout,
    input  wire        fifo_empty,
    input  wire        fifo_valid,
    input  wire        fifo_rd_rst_busy,
    output wire        fifo_rd_en,

    output reg  [3:0]  vga_r,
    output reg  [3:0]  vga_g,
    output reg  [3:0]  vga_b,
    output reg         vga_hs,
    output reg         vga_vs
);

    // ============================================================
    // VGA 640x480 @ 60Hz
    // Pixel clock 25 MHz
    // ============================================================
    localparam H_VISIBLE = 640;
    localparam H_FRONT   = 16;
    localparam H_SYNC    = 96;
    localparam H_BACK    = 48;
    localparam H_TOTAL   = 800;

    localparam V_VISIBLE = 480;
    localparam V_FRONT   = 10;
    localparam V_SYNC    = 2;
    localparam V_BACK    = 33;
    localparam V_TOTAL   = 525;

    // ============================================================
    // ROI tengah 280x280
    // ============================================================
    localparam ROI_SIZE   = 280;
    localparam ROI_BORDER = 2;   // ketebalan bingkai hijau

    localparam ROI_X_START = (H_VISIBLE - ROI_SIZE) / 2; // 180
    localparam ROI_X_END   = ROI_X_START + ROI_SIZE;     // 460

    localparam ROI_Y_START = (V_VISIBLE - ROI_SIZE) / 2; // 100
    localparam ROI_Y_END   = ROI_Y_START + ROI_SIZE;     // 380

    reg [9:0] h_cnt = 10'd0;
    reg [9:0] v_cnt = 10'd0;

    wire active_video;
    wire hsync_active;
    wire vsync_active;
    wire can_read_fifo;

    wire roi_top;
    wire roi_bottom;
    wire roi_left;
    wire roi_right;
    wire roi_border;

    assign active_video = (h_cnt < H_VISIBLE) && (v_cnt < V_VISIBLE);

    assign hsync_active =
        (h_cnt >= (H_VISIBLE + H_FRONT)) &&
        (h_cnt <  (H_VISIBLE + H_FRONT + H_SYNC));

    assign vsync_active =
        (v_cnt >= (V_VISIBLE + V_FRONT)) &&
        (v_cnt <  (V_VISIBLE + V_FRONT + V_SYNC));

    // ============================================================
    // FIFO tetap dibaca pada seluruh active_video
    // supaya stream pixel tetap 640x480 dan tidak bergeser
    // ============================================================
    assign can_read_fifo =
        active_video &&
        !fifo_empty &&
        !fifo_rd_rst_busy;

    assign fifo_rd_en = can_read_fifo;

    // ============================================================
    // Deteksi garis bingkai ROI
    // ROI area:
    // X = 180 sampai 459
    // Y = 100 sampai 379
    // ============================================================

    assign roi_top =
        active_video &&
        (h_cnt >= ROI_X_START) &&
        (h_cnt <  ROI_X_END) &&
        (v_cnt >= ROI_Y_START) &&
        (v_cnt <  ROI_Y_START + ROI_BORDER);

    assign roi_bottom =
        active_video &&
        (h_cnt >= ROI_X_START) &&
        (h_cnt <  ROI_X_END) &&
        (v_cnt >= ROI_Y_END - ROI_BORDER) &&
        (v_cnt <  ROI_Y_END);

    assign roi_left =
        active_video &&
        (h_cnt >= ROI_X_START) &&
        (h_cnt <  ROI_X_START + ROI_BORDER) &&
        (v_cnt >= ROI_Y_START) &&
        (v_cnt <  ROI_Y_END);

    assign roi_right =
        active_video &&
        (h_cnt >= ROI_X_END - ROI_BORDER) &&
        (h_cnt <  ROI_X_END) &&
        (v_cnt >= ROI_Y_START) &&
        (v_cnt <  ROI_Y_END);

    assign roi_border = roi_top | roi_bottom | roi_left | roi_right;

    always @(posedge vga_clk) begin
        if (rst) begin
            h_cnt  <= 10'd0;
            v_cnt  <= 10'd0;

            vga_r  <= 4'h0;
            vga_g  <= 4'h0;
            vga_b  <= 4'h0;

            vga_hs <= 1'b1;
            vga_vs <= 1'b1;
        end else begin
            // VGA sync aktif-low
            vga_hs <= ~hsync_active;
            vga_vs <= ~vsync_active;

            if (active_video) begin

                // ====================================================
                // Overlay bingkai ROI hijau
                // ====================================================
                if (roi_border) begin
                    vga_r <= 4'h0;
                    vga_g <= 4'hF;
                    vga_b <= 4'h0;
                end

                // ====================================================
                // Selain bingkai ROI, tampilkan pixel asli dari FIFO
                // ====================================================
                else if (can_read_fifo) begin
                    vga_r <= fifo_dout[15:12];
                    vga_g <= fifo_dout[10:7];
                    vga_b <= fifo_dout[4:1];
                end

                // Jika FIFO kosong, tampilkan hitam
                else begin
                    vga_r <= 4'h0;
                    vga_g <= 4'h0;
                    vga_b <= 4'h0;
                end

            end else begin
                vga_r <= 4'h0;
                vga_g <= 4'h0;
                vga_b <= 4'h0;
            end

            // ========================================================
            // Counter horizontal dan vertical VGA
            // ========================================================
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

endmodule