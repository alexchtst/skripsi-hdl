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
    // 640x480 @ 60 Hz VGA timing
    // Pixel clock sekitar 25 MHz
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

    reg [9:0] h_cnt = 10'd0;
    reg [9:0] v_cnt = 10'd0;

    wire active_video;
    wire hsync_active;
    wire vsync_active;
    wire can_read_fifo;

    assign active_video = (h_cnt < H_VISIBLE) && (v_cnt < V_VISIBLE);

    assign hsync_active =
        (h_cnt >= (H_VISIBLE + H_FRONT)) &&
        (h_cnt <  (H_VISIBLE + H_FRONT + H_SYNC));

    assign vsync_active =
        (v_cnt >= (V_VISIBLE + V_FRONT)) &&
        (v_cnt <  (V_VISIBLE + V_FRONT + V_SYNC));

    // Untuk FIFO FWFT:
    // Jika empty = 0, maka fifo_dout sudah berisi data valid.
    // rd_en dipakai untuk maju ke pixel berikutnya.
    assign can_read_fifo =
        active_video &&
        !fifo_empty &&
        !fifo_rd_rst_busy;

    assign fifo_rd_en = can_read_fifo;

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
            // ====================================================
            // VGA sync output
            // HSYNC dan VSYNC active-low
            // ====================================================
            vga_hs <= ~hsync_active;
            vga_vs <= ~vsync_active;

            // ====================================================
            // RGB output
            // RGB565:
            // [15:11] = R
            // [10:5]  = G
            // [4:0]   = B
            //
            // Pmod VGA pakai 4-bit per warna:
            // R = pixel[15:12]
            // G = pixel[10:7]
            // B = pixel[4:1]
            // ====================================================
            if (active_video) begin
                if (can_read_fifo) begin
                    vga_r <= fifo_dout[15:12];
                    vga_g <= fifo_dout[10:7];
                    vga_b <= fifo_dout[4:1];
                end else begin
                    // Kalau FIFO kosong, tampilkan hitam.
                    vga_r <= 4'h0;
                    vga_g <= 4'h0;
                    vga_b <= 4'h0;
                end
            end else begin
                // Blanking area harus hitam.
                vga_r <= 4'h0;
                vga_g <= 4'h0;
                vga_b <= 4'h0;
            end

            // ====================================================
            // Horizontal / vertical counter
            // ====================================================
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
