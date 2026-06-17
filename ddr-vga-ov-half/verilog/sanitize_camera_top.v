`timescale 1ns / 1ps

module sanitize_camera_top(
    input  wire CLK100MHZ,
    input  wire reset,

    output wire cam_scl,
    inout  wire cam_sda,

    input  wire cam_vsync,
    input  wire cam_pclk,
    input  wire cam_href,
    input  wire [7:0] cam_d,

    output wire cam_xclk,
    output wire cam_rst,
    output wire cam_pwdn,

    output wire led4,
    output wire led5,
    output wire led6,
    output wire led7
);

    // ============================================================
    // Reset
    // ============================================================
    // Di sini reset dianggap ACTIVE-HIGH.
    // Kalau kamu pakai tombol active-low, ubah menjadi:
    // assign reset_raw_active_high = ~reset;
    // ============================================================
    wire reset_raw_active_high;
    assign reset_raw_active_high = reset;


    // ============================================================
    // OV7670 XCLK generator
    // CLK100MHZ / 4 = 25 MHz
    // ============================================================
    ov7670_xclk_gen u_ov7670_xclk_gen (
        .clk_100mhz (CLK100MHZ),
        .rst        (reset_raw_active_high),
        .xclk       (cam_xclk)
    );


    // ============================================================
    // Camera power control
    // ============================================================
    // OV7670 PWDN active-high.
    // 0 = camera aktif.
    // ============================================================
    assign cam_pwdn = 1'b0;


    // ============================================================
    // Reset synchronizer untuk domain CLK100MHZ
    // ============================================================
    (* ASYNC_REG = "TRUE" *) reg rst_sys_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_sys_sync = 1'b1;

    always @(posedge CLK100MHZ) begin
        rst_sys_meta <= reset_raw_active_high;
        rst_sys_sync <= rst_sys_meta;
    end

    wire rst_sys;
    assign rst_sys = rst_sys_sync;


    // ============================================================
    // SCCB config OV7670
    // Domain: CLK100MHZ
    // ============================================================
    wire cam_config_done;
    wire cam_config_busy;
    wire cam_config_error;

    ov7670_sccb_config #(
        .CLK_FREQ_HZ         (100_000_000),
        .SCCB_FREQ_HZ        (100_000),
        .ENABLE_TEST_PATTERN (1)
    ) u_ov7670_sccb_config (
        .clk     (CLK100MHZ),
        .rst     (rst_sys),
        .start   (1'b1),

        .scl     (cam_scl),
        .sda     (cam_sda),

        .cam_rst (cam_rst),

        .done    (cam_config_done),
        .busy    (cam_config_busy),
        .error   (cam_config_error)
    );


    // ============================================================
    // Sinkronisasi config_done dari CLK100MHZ ke cam_pclk
    // ============================================================
    (* ASYNC_REG = "TRUE" *) reg config_done_meta_pclk = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg config_done_sync_pclk = 1'b0;

    always @(posedge cam_pclk) begin
        config_done_meta_pclk <= cam_config_done;
        config_done_sync_pclk <= config_done_meta_pclk;
    end


    // ============================================================
    // Sinkronisasi reset ke domain cam_pclk
    // ============================================================
    (* ASYNC_REG = "TRUE" *) reg rst_pclk_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_pclk_sync = 1'b1;

    always @(posedge cam_pclk) begin
        rst_pclk_meta <= reset_raw_active_high;
        rst_pclk_sync <= rst_pclk_meta;
    end

    wire cam_capture_rst;
    assign cam_capture_rst = rst_pclk_sync | ~config_done_sync_pclk;


    // ============================================================
    // Capture OV7670 RGB565
    // Domain: cam_pclk
    // ============================================================
    wire [15:0] cam_fifo_din;
    wire        cam_fifo_wr_en;
    wire        cam_frame_start;
    wire [9:0]  cam_x;
    wire [9:0]  cam_y;

    ov7670_rgb565_capture_to_fifo u_cam_capture (
        .pclk             (cam_pclk),
        .rst              (cam_capture_rst),

        .cam_vsync        (cam_vsync),
        .cam_href         (cam_href),
        .cam_d            (cam_d),

        // Untuk debug kamera saja, anggap FIFO selalu siap.
        .fifo_full        (1'b0),
        .fifo_wr_rst_busy (1'b0),

        .fifo_din         (cam_fifo_din),
        .fifo_wr_en       (cam_fifo_wr_en),

        .frame_start      (cam_frame_start),
        .x                (cam_x),
        .y                (cam_y)
    );


    // ============================================================
    // Debug detector di domain cam_pclk
    // ============================================================

    // PCLK alive detector.
    // Kalau cam_pclk hidup, LED6 akan berkedip.
    reg [23:0] pclk_counter = 24'd0;

    always @(posedge cam_pclk) begin
        pclk_counter <= pclk_counter + 1'b1;
    end

    wire pclk_alive_led;
    assign pclk_alive_led = pclk_counter[23];


    // Detector apakah VSYNC/HREF/pixel pernah terlihat.
    reg vsync_seen_pclk = 1'b0;
    reg href_seen_pclk  = 1'b0;
    reg pixel_seen_pclk = 1'b0;

    always @(posedge cam_pclk) begin
        if (cam_capture_rst) begin
            vsync_seen_pclk <= 1'b0;
            href_seen_pclk  <= 1'b0;
            pixel_seen_pclk <= 1'b0;
        end else begin
            if (cam_vsync)
                vsync_seen_pclk <= 1'b1;

            if (cam_href)
                href_seen_pclk <= 1'b1;

            if (cam_fifo_wr_en)
                pixel_seen_pclk <= 1'b1;
        end
    end

    wire activity_seen_pclk;
    assign activity_seen_pclk = vsync_seen_pclk | href_seen_pclk | pixel_seen_pclk;


    // Sinkronisasi activity_seen ke CLK100MHZ untuk LED7.
    (* ASYNC_REG = "TRUE" *) reg activity_seen_meta_sys = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg activity_seen_sync_sys = 1'b0;

    always @(posedge CLK100MHZ) begin
        activity_seen_meta_sys <= activity_seen_pclk;
        activity_seen_sync_sys <= activity_seen_meta_sys;
    end


    // ============================================================
    // LED debug mapping sementara
    // ============================================================
    assign led4 = cam_config_done;
    assign led5 = cam_config_error;
    assign led6 = pclk_alive_led;
    assign led7 = activity_seen_sync_sys;


    // ============================================================
    // MARK_DEBUG signals
    // Ini membantu kalau kamu pakai Set Up Debug dari Vivado.
    // Tetap perlu insert ILA / Set Up Debug agar debug core muncul.
    // ============================================================
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_config_done  = cam_config_done;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_config_busy  = cam_config_busy;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_config_error = cam_config_error;

    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_rst          = cam_rst;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_pwdn         = cam_pwdn;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_scl          = cam_scl;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_sda          = cam_sda;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_xclk         = cam_xclk;

    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_pclk         = cam_pclk;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_vsync        = cam_vsync;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_href         = cam_href;
    (* MARK_DEBUG = "TRUE" *) wire [7:0] dbg_cam_d      = cam_d;

    (* MARK_DEBUG = "TRUE" *) wire [15:0] dbg_fifo_din  = cam_fifo_din;
    (* MARK_DEBUG = "TRUE" *) wire dbg_fifo_wr_en       = cam_fifo_wr_en;
    (* MARK_DEBUG = "TRUE" *) wire dbg_frame_start      = cam_frame_start;
    (* MARK_DEBUG = "TRUE" *) wire [9:0] dbg_cam_x      = cam_x;
    (* MARK_DEBUG = "TRUE" *) wire [9:0] dbg_cam_y      = cam_y;

    (* MARK_DEBUG = "TRUE" *) wire dbg_vsync_seen_pclk  = vsync_seen_pclk;
    (* MARK_DEBUG = "TRUE" *) wire dbg_href_seen_pclk   = href_seen_pclk;
    (* MARK_DEBUG = "TRUE" *) wire dbg_pixel_seen_pclk  = pixel_seen_pclk;

endmodule