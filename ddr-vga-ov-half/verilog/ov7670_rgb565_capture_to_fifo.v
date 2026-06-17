`timescale 1ns / 1ps

module ov7670_rgb565_capture_to_fifo (
    input  wire        pclk,
    input  wire        rst,

    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_d,

    input  wire        fifo_full,
    input  wire        fifo_wr_rst_busy,

    output reg  [15:0] fifo_din,
    output reg         fifo_wr_en,

    output reg         frame_start,
    output reg  [9:0]  x,
    output reg  [9:0]  y
);

    // ============================================================
    // State
    // ============================================================
    localparam ST_WAIT_FRAME_START = 3'd0;
    localparam ST_WAIT_LINE_START  = 3'd1;
    localparam ST_BYTE_HIGH        = 3'd2;
    localparam ST_BYTE_LOW         = 3'd3;
    localparam ST_WAIT_LINE_END    = 3'd4;
    localparam ST_DROP_FRAME       = 3'd5;

    reg [2:0] state;

    reg [7:0] byte_high;

    reg vsync_d;
    reg href_d;

    wire vsync_fall;
    wire href_rise;
    wire href_fall;

    // Mengikuti repo:
    // VSYNC falling edge = awal frame
    assign vsync_fall =  vsync_d & ~cam_vsync;

    // Awal dan akhir line
    assign href_rise  = ~href_d  &  cam_href;
    assign href_fall  =  href_d  & ~cam_href;

    always @(posedge pclk) begin
        if (rst) begin
            state       <= ST_WAIT_FRAME_START;

            vsync_d     <= 1'b0;
            href_d      <= 1'b0;

            byte_high   <= 8'd0;
            fifo_din    <= 16'd0;
            fifo_wr_en  <= 1'b0;

            frame_start <= 1'b0;

            x           <= 10'd0;
            y           <= 10'd0;
        end else begin
            // default pulse
            fifo_wr_en  <= 1'b0;
            frame_start <= 1'b0;

            // register sync signal kamera pada domain pclk
            vsync_d <= cam_vsync;
            href_d  <= cam_href;

            case (state)

                // ====================================================
                // Tunggu awal frame kamera.
                // Di OV7670, mengikuti repo, awal frame = VSYNC falling.
                // ====================================================
                ST_WAIT_FRAME_START: begin
                    x <= 10'd0;
                    y <= 10'd0;

                    if (vsync_fall) begin
                        frame_start <= 1'b1;
                        state       <= ST_WAIT_LINE_START;
                    end
                end

                // ====================================================
                // Tunggu awal line valid.
                // HREF high berarti data byte valid.
                // ====================================================
                ST_WAIT_LINE_START: begin
                    x <= 10'd0;

                    // Kalau tiba-tiba masuk VSYNC lagi, ulang tunggu frame.
                    if (cam_vsync) begin
                        state <= ST_WAIT_FRAME_START;
                    end else if (href_rise || cam_href) begin
                        state <= ST_BYTE_HIGH;
                    end
                end

                // ====================================================
                // Byte pertama pixel RGB565.
                // Urutan sama dengan repo:
                // byte pertama -> [15:8]
                // byte kedua   -> [7:0]
                // ====================================================
                ST_BYTE_HIGH: begin
                    if (!cam_href) begin
                        state <= ST_WAIT_LINE_START;
                    end else begin
                        byte_high <= cam_d;
                        state     <= ST_BYTE_LOW;
                    end
                end

                // ====================================================
                // Byte kedua pixel RGB565, lalu tulis 1 pixel ke FIFO.
                // ====================================================
                ST_BYTE_LOW: begin
                    if (!cam_href) begin
                        state <= ST_WAIT_LINE_START;
                    end else begin
                        // Kalau FIFO penuh, jangan campur frame rusak.
                        // Drop sisa frame dan tunggu frame berikutnya.
                        if (fifo_full || fifo_wr_rst_busy) begin
                            state <= ST_DROP_FRAME;
                        end else begin
                            fifo_din   <= {byte_high, cam_d};
                            fifo_wr_en <= 1'b1;

                            if (x == 10'd639) begin
                                x <= 10'd0;

                                if (y == 10'd479) begin
                                    // Satu frame 640x480 selesai.
                                    // Jangan tulis lagi sampai frame berikutnya.
                                    state <= ST_WAIT_FRAME_START;
                                end else begin
                                    y     <= y + 1'b1;
                                    state <= ST_WAIT_LINE_END;
                                end
                            end else begin
                                x     <= x + 1'b1;
                                state <= ST_BYTE_HIGH;
                            end
                        end
                    end
                end

                // ====================================================
                // Setelah 640 pixel, abaikan sisa byte pada line itu
                // sampai HREF turun.
                // Ini penting supaya tidak wrap dan menulis extra pixel.
                // ====================================================
                ST_WAIT_LINE_END: begin
                    if (cam_vsync) begin
                        state <= ST_WAIT_FRAME_START;
                    end else if (href_fall || !cam_href) begin
                        state <= ST_WAIT_LINE_START;
                    end
                end

                // ====================================================
                // Kalau FIFO penuh saat capture, frame ini sudah rusak.
                // Lebih aman drop sampai frame berikutnya.
                // ====================================================
                ST_DROP_FRAME: begin
                    if (vsync_fall) begin
                        x           <= 10'd0;
                        y           <= 10'd0;
                        frame_start <= 1'b1;
                        state       <= ST_WAIT_LINE_START;
                    end
                end

                default: begin
                    state <= ST_WAIT_FRAME_START;
                end

            endcase
        end
    end

endmodule