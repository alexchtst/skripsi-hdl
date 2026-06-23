`timescale 1ns / 1ps

module camera_read(
    input  wire       p_clock,
    input  wire       vsync,
    input  wire       href,
    input  wire [7:0] p_data,

    output reg [15:0] pixel_data  = 16'd0,
    output reg        pixel_valid = 1'b0,
    output reg        frame_done  = 1'b0,

    output reg [9:0]  cam_x       = 10'd0,
    output reg [9:0]  cam_y       = 10'd0,
    output reg        frame_start = 1'b0
);

    localparam WAIT_FRAME_START = 2'd0;
    localparam ROW_CAPTURE      = 2'd1;

    reg [1:0] FSM_state = WAIT_FRAME_START;
    reg       pixel_half = 1'b0;

    reg [9:0] x_cnt = 10'd0;
    reg [9:0] y_cnt = 10'd0;

    // =========================================================
    // ROI Border 280x280 Center
    // Frame camera diasumsikan 640x480
    // ROI: x = 180..459, y = 100..379
    // =========================================================
    localparam [9:0] ROI_X0 = 10'd180;
    localparam [9:0] ROI_Y0 = 10'd100;
    localparam [9:0] ROI_X1 = 10'd459;
    localparam [9:0] ROI_Y1 = 10'd379;

    localparam [9:0] BORDER_THICK = 10'd2;

    wire in_roi_x;
    wire in_roi_y;
    wire roi_border;

    assign in_roi_x = (x_cnt >= ROI_X0) && (x_cnt <= ROI_X1);
    assign in_roi_y = (y_cnt >= ROI_Y0) && (y_cnt <= ROI_Y1);

    assign roi_border =
        in_roi_x &&
        in_roi_y &&
        (
            (x_cnt < ROI_X0 + BORDER_THICK) ||
            (x_cnt > ROI_X1 - BORDER_THICK) ||
            (y_cnt < ROI_Y0 + BORDER_THICK) ||
            (y_cnt > ROI_Y1 - BORDER_THICK)
        );

    always @(posedge p_clock) begin
        // default pulse
        pixel_valid <= 1'b0;
        frame_start <= 1'b0;
        frame_done  <= 1'b0;

        case (FSM_state)

            WAIT_FRAME_START: begin
                pixel_half <= 1'b0;

                x_cnt <= 10'd0;
                y_cnt <= 10'd0;
                cam_x <= 10'd0;
                cam_y <= 10'd0;

                // OV7670 aktif capture ketika VSYNC low
                if (!vsync) begin
                    FSM_state   <= ROW_CAPTURE;
                    frame_start <= 1'b1;   // benar-benar pulse 1 p_clock
                end
            end

            ROW_CAPTURE: begin
                if (vsync) begin
                    FSM_state  <= WAIT_FRAME_START;
                    frame_done <= 1'b1;    // pulse 1 p_clock saat frame selesai

                    pixel_half <= 1'b0;
                    x_cnt      <= 10'd0;
                    y_cnt      <= 10'd0;
                    cam_x      <= 10'd0;
                    cam_y      <= 10'd0;
                end else begin
                    if (href) begin
                        pixel_half <= ~pixel_half;

                        if (!pixel_half) begin
                            // byte pertama RGB565
                            pixel_data[15:8] <= p_data;
                        end else begin
                            // byte kedua RGB565
                            if (roi_border) begin
                                // Green ROI border RGB565
                                pixel_data <= 16'h07E0;
                            end else begin
                                pixel_data[7:0] <= p_data;
                            end

                            pixel_valid <= 1'b1;

                            cam_x <= x_cnt;
                            cam_y <= y_cnt;

                            if (x_cnt == 10'd639) begin
                                x_cnt <= 10'd0;

                                if (y_cnt == 10'd479)
                                    y_cnt <= 10'd0;
                                else
                                    y_cnt <= y_cnt + 1'b1;
                            end else begin
                                x_cnt <= x_cnt + 1'b1;
                            end
                        end
                    end else begin
                        // penting supaya byte alignment tidak geser antar baris
                        pixel_half <= 1'b0;
                    end
                end
            end

            default: begin
                FSM_state <= WAIT_FRAME_START;
            end

        endcase
    end

endmodule