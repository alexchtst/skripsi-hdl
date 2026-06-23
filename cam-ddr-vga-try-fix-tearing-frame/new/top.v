`timescale 1ns / 1ps

module top(

    input  wire CLK100MHZ,
    input  wire reset,

    // DDR3 SDRAM
    output wire [13:0] ddr3_sdram_addr,
    output wire [2:0]  ddr3_sdram_ba,
    output wire        ddr3_sdram_cas_n,
    output wire [0:0]  ddr3_sdram_ck_n,
    output wire [0:0]  ddr3_sdram_ck_p,
    output wire [0:0]  ddr3_sdram_cke,
    output wire [0:0]  ddr3_sdram_cs_n,
    output wire [1:0]  ddr3_sdram_dm,
    inout  wire [15:0] ddr3_sdram_dq,
    inout  wire [1:0]  ddr3_sdram_dqs_n,
    inout  wire [1:0]  ddr3_sdram_dqs_p,
    output wire [0:0]  ddr3_sdram_odt,
    output wire        ddr3_sdram_ras_n,
    output wire        ddr3_sdram_reset_n,
    output wire        ddr3_sdram_we_n,

    // LED debug
    output wire led4,
    output wire led5,
    output wire led6,
    output wire led7,

    input  wire sw0,
    input  wire sw1,

    // OV7670
    output wire cam_scl,
    inout  wire cam_sda,
    input  wire cam_vsync,
    input  wire cam_href,
    input  wire cam_pclk,
    output wire cam_xclk,
    output wire cam_pwdn,
    output wire cam_rst,
    input  wire [7:0] cam_d,

    // VGA
    output wire [3:0] vga_r,
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,
    output wire       vga_hs,
    output wire       vga_vs
);

    // =========================================================
    // RESET
    // =========================================================
    (* mark_debug = "true" *) wire rst_active_high;
    assign rst_active_high = ~reset;

    // =========================================================
    // CLOCK WIRES FROM DESIGN WRAPPER
    // =========================================================
    (* mark_debug = "true" *) wire pxl_clk;
    (* mark_debug = "true" *) wire ov7670_xclk;
    (* mark_debug = "true" *) wire mig_ui_clk;

    assign cam_xclk = ov7670_xclk;
    assign cam_pwdn = 1'b0;
    assign cam_rst  = reset;

    // =========================================================
    // DEBUG CAMERA RAW INPUTS
    // =========================================================
    (* mark_debug = "true" *) wire dbg_cam_vsync;
    (* mark_debug = "true" *) wire dbg_cam_href;

    assign dbg_cam_vsync = cam_vsync;
    assign dbg_cam_href  = cam_href;

    // =========================================================
    // VGA / FIFO WIRES
    // =========================================================
    (* mark_debug = "true" *) wire [15:0] vga_pixel;

    (* mark_debug = "true" *) wire vga_vblank_start;
    (* mark_debug = "true" *) wire vga_frame_start;

    (* mark_debug = "true" *) wire async_fifo_read_empty;
    (* mark_debug = "true" *) wire async_fifo_read_valid;
    (* mark_debug = "true" *) wire async_fifo_read_rd_rst_busy;
    (* mark_debug = "true" *) wire async_fifo_read_rd_en;

    (* mark_debug = "true" *) wire [15:0] async_fifo_write_din;
    (* mark_debug = "true" *) wire        async_fifo_write_full;
    (* mark_debug = "true" *) wire        async_fifo_write_wr_en;
    (* mark_debug = "true" *) wire        async_fifo_write_wr_rst_busy;

    // =========================================================
    // CAMERA CONFIG
    // =========================================================
    reg [31:0] cam_conf_cnt     = 32'd0;
    reg        cam_conf_started = 1'b0;
    reg        cam_conf_start   = 1'b0;

    (* mark_debug = "true" *) wire cam_conf_done;

    localparam integer CAM_CONF_DELAY_CYCLES = 32'd5_000_000; // 50 ms @ 100 MHz

    always @(posedge CLK100MHZ) begin
        if (rst_active_high) begin
            cam_conf_cnt     <= 32'd0;
            cam_conf_started <= 1'b0;
            cam_conf_start   <= 1'b0;
        end else begin
            cam_conf_start <= 1'b0;

            if (!cam_conf_started) begin
                if (cam_conf_cnt == CAM_CONF_DELAY_CYCLES - 1) begin
                    cam_conf_start   <= 1'b1;
                    cam_conf_started <= 1'b1;
                end else begin
                    cam_conf_cnt <= cam_conf_cnt + 1'b1;
                end
            end
        end
    end

    camera_configure #(
        .CLK_FREQ(100_000_000)
    ) u_ov7670_conf (
        .clk   (CLK100MHZ),
        .start (cam_conf_start),
        .sioc  (cam_scl),
        .siod  (cam_sda),
        .done  (cam_conf_done)
    );

    // =========================================================
    // CAMERA READ
    // =========================================================
    (* mark_debug = "true" *) wire [15:0] cam_pixel_data;
    (* mark_debug = "true" *) wire        cam_pixel_valid;
    (* mark_debug = "true" *) wire        cam_frame_done;
    (* mark_debug = "true" *) wire        cam_frame_start_pclk;

    (* mark_debug = "true" *) wire [9:0] cam_x;
    (* mark_debug = "true" *) wire [9:0] cam_y;

    camera_read u_camera_read (
        .p_clock     (cam_pclk),
        .vsync       (cam_vsync),
        .href        (cam_href),
        .p_data      (cam_d),

        .pixel_data  (cam_pixel_data),
        .pixel_valid (cam_pixel_valid),
        .frame_done  (cam_frame_done),

        .cam_x       (cam_x),
        .cam_y       (cam_y),
        .frame_start (cam_frame_start_pclk)
    );

    // =========================================================
    // SYNC CAMERA CONFIG DONE TO cam_pclk
    // =========================================================
    reg cam_conf_done_meta = 1'b0;
    (* mark_debug = "true" *) reg cam_conf_done_pclk = 1'b0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            cam_conf_done_meta <= 1'b0;
            cam_conf_done_pclk <= 1'b0;
        end else begin
            cam_conf_done_meta <= cam_conf_done;
            cam_conf_done_pclk <= cam_conf_done_meta;
        end
    end

    // =========================================================
    // UI CONTROL WIRES
    // =========================================================
    (* mark_debug = "true" *) wire sw0_ui;
    (* mark_debug = "true" *) wire sw1_ui;

    (* mark_debug = "true" *) wire write_start_allowed_ui;
    (* mark_debug = "true" *) wire read_start_allowed_ui;
    (* mark_debug = "true" *) wire write_accept_ready;

    (* mark_debug = "true" *) wire vga_vblank_start_ui;

    // accepted frame start:
    // Ini menggantikan raw cam_frame_start_ui untuk start AXI write.
    (* mark_debug = "true" *) wire accepted_frame_start_ui;

    // write_accept_ready dari MIG/UI domain ke camera domain.
    (* mark_debug = "true" *) wire write_accept_ready_pclk;

    // =========================================================
    // SYNC SWITCH TO mig_ui_clk
    // =========================================================
    cdc_bit_sync u_sw0_sync (
        .clk      (mig_ui_clk),
        .rst      (rst_active_high),
        .async_in (sw0),
        .sync_out (sw0_ui)
    );

    cdc_bit_sync u_sw1_sync (
        .clk      (mig_ui_clk),
        .rst      (rst_active_high),
        .async_in (sw1),
        .sync_out (sw1_ui)
    );

    // =========================================================
    // SYNC write_accept_ready: mig_ui_clk -> cam_pclk
    // =========================================================
    cdc_bit_sync u_write_accept_ready_to_pclk (
        .clk      (cam_pclk),
        .rst      (rst_active_high),
        .async_in (write_accept_ready),
        .sync_out (write_accept_ready_pclk)
    );

    // =========================================================
    // CAMERA FRAME CAPTURE GATE
    //
    // write_accept_ready hanya dicek saat cam_frame_start_pclk.
    // Setelah frame diterima, capture_frame_active tetap 1
    // sampai cam_frame_done.
    //
    // Ini mencegah FIFO terisi oleh potongan frame ketika AXI
    // belum siap menerima frame baru.
    // =========================================================
    (* mark_debug = "true" *) reg capture_frame_active      = 1'b0;
    (* mark_debug = "true" *) reg accepted_frame_start_pclk = 1'b0;
    (* mark_debug = "true" *) reg capture_overflow_pclk     = 1'b0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            capture_frame_active      <= 1'b0;
            accepted_frame_start_pclk <= 1'b0;
            capture_overflow_pclk     <= 1'b0;
        end else begin
            // default pulse
            accepted_frame_start_pclk <= 1'b0;

            // Awal frame kamera:
            // Di sini kita putuskan frame diterima atau dibuang.
            if (cam_frame_start_pclk) begin
                capture_overflow_pclk <= 1'b0;

                if (write_accept_ready_pclk && cam_conf_done_pclk) begin
                    capture_frame_active      <= 1'b1;
                    accepted_frame_start_pclk <= 1'b1;
                end else begin
                    capture_frame_active <= 1'b0; // drop frame
                end
            end

            // Akhir frame kamera:
            // Stop memasukkan pixel kamera ke FIFO.
            if (cam_frame_done) begin
                capture_frame_active <= 1'b0;
            end

            // Debug:
            // Kalau full saat capture aktif, berarti frame ini berisiko rusak.
            if (capture_frame_active && cam_pixel_valid && async_fifo_write_full) begin
                capture_overflow_pclk <= 1'b1;
            end
        end
    end

    // =========================================================
    // CAMERA PIXEL COUNTERS FOR DEBUG
    //
    // raw  : jumlah cam_pixel_valid dalam 1 frame kamera,
    //        tanpa peduli frame diterima atau tidak.
    //
    // cap  : jumlah pixel yang benar-benar masuk saat capture aktif.
    //
    // Target untuk 640x480 adalah 307200 pixel.
    // =========================================================
    (* mark_debug = "true" *) reg [31:0] cam_pixel_count_raw_active  = 32'd0;
    (* mark_debug = "true" *) reg [31:0] cam_pixel_count_raw_latched = 32'd0;

    (* mark_debug = "true" *) reg [31:0] cam_pixel_count_cap_active  = 32'd0;
    (* mark_debug = "true" *) reg [31:0] cam_pixel_count_cap_latched = 32'd0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            cam_pixel_count_raw_active  <= 32'd0;
            cam_pixel_count_raw_latched <= 32'd0;

            cam_pixel_count_cap_active  <= 32'd0;
            cam_pixel_count_cap_latched <= 32'd0;
        end else begin

            // Counter raw per frame kamera.
            if (cam_frame_start_pclk) begin
                cam_pixel_count_raw_active <= 32'd0;
            end else if (cam_pixel_valid) begin
                cam_pixel_count_raw_active <= cam_pixel_count_raw_active + 32'd1;
            end

            if (cam_frame_done) begin
                cam_pixel_count_raw_latched <= cam_pixel_count_raw_active;
            end

            // Counter capture accepted frame.
            if (accepted_frame_start_pclk) begin
                cam_pixel_count_cap_active <= 32'd0;
            end else if (capture_frame_active &&
                         cam_pixel_valid &&
                         !async_fifo_write_full &&
                         !async_fifo_write_wr_rst_busy) begin
                cam_pixel_count_cap_active <= cam_pixel_count_cap_active + 32'd1;
            end

            if (cam_frame_done) begin
                cam_pixel_count_cap_latched <= cam_pixel_count_cap_active;
            end
        end
    end

    // =========================================================
    // CAMERA FIFO WRITE
    // =========================================================
    assign async_fifo_write_din = cam_pixel_data;

    assign async_fifo_write_wr_en =
        capture_frame_active &&
        cam_pixel_valid &&
        cam_conf_done_pclk &&
        !async_fifo_write_full &&
        !async_fifo_write_wr_rst_busy;

    // =========================================================
    // CDC: accepted camera frame start -> mig_ui_clk
    //
    // Ini dipakai untuk start AXI write.
    // Jangan pakai raw cam_frame_start_pclk langsung.
    // =========================================================
    cdc_event_sync u_accepted_frame_start_to_ui (
        .src_clk    (cam_pclk),
        .src_rst    (rst_active_high),
        .src_signal (accepted_frame_start_pclk),

        .dst_clk    (mig_ui_clk),
        .dst_rst    (rst_active_high),
        .dst_pulse  (accepted_frame_start_ui)
    );

    // =========================================================
    // CDC: VGA vblank start -> mig_ui_clk
    // =========================================================
    cdc_event_sync u_vga_vblank_start_to_ui (
        .src_clk    (pxl_clk),
        .src_rst    (rst_active_high),
        .src_signal (vga_vblank_start),

        .dst_clk    (mig_ui_clk),
        .dst_rst    (rst_active_high),
        .dst_pulse  (vga_vblank_start_ui)
    );

    // =========================================================
    // START ALLOWED SIGNALS
    //
    // WRITE:
    // AXI write hanya start kalau frame kamera benar-benar diterima.
    //
    // READ:
    // AXI read tetap start saat VGA vblank.
    // =========================================================
    assign write_start_allowed_ui = sw1_ui & accepted_frame_start_ui;
    assign read_start_allowed_ui  = sw0_ui & vga_vblank_start_ui;

    // =========================================================
    // DDR / AXI / FIFO DESIGN WRAPPER
    // =========================================================
    design_test_write_wrapper design_test_write_i (
        .CLK100MHZ(CLK100MHZ),
        .mig_ui_clk(mig_ui_clk),

        .cam_pclk(cam_pclk),

        .async_fifo_read_empty(async_fifo_read_empty),
        .async_fifo_read_rd_en(async_fifo_read_rd_en),
        .async_fifo_read_rd_rst_busy(async_fifo_read_rd_rst_busy),
        .async_fifo_read_valid(async_fifo_read_valid),

        .async_fifo_write_din(async_fifo_write_din),
        .async_fifo_write_full(async_fifo_write_full),
        .async_fifo_write_wr_en(async_fifo_write_wr_en),
        .async_fifo_write_wr_rst_busy(async_fifo_write_wr_rst_busy),

        .ddr3_sdram_addr(ddr3_sdram_addr),
        .ddr3_sdram_ba(ddr3_sdram_ba),
        .ddr3_sdram_cas_n(ddr3_sdram_cas_n),
        .ddr3_sdram_ck_n(ddr3_sdram_ck_n),
        .ddr3_sdram_ck_p(ddr3_sdram_ck_p),
        .ddr3_sdram_cke(ddr3_sdram_cke),
        .ddr3_sdram_cs_n(ddr3_sdram_cs_n),
        .ddr3_sdram_dm(ddr3_sdram_dm),
        .ddr3_sdram_dq(ddr3_sdram_dq),
        .ddr3_sdram_dqs_n(ddr3_sdram_dqs_n),
        .ddr3_sdram_dqs_p(ddr3_sdram_dqs_p),
        .ddr3_sdram_odt(ddr3_sdram_odt),
        .ddr3_sdram_ras_n(ddr3_sdram_ras_n),
        .ddr3_sdram_reset_n(ddr3_sdram_reset_n),
        .ddr3_sdram_we_n(ddr3_sdram_we_n),

        .read_start_allowed(read_start_allowed_ui),
        .write_start_allowed(write_start_allowed_ui),
        .write_accept_ready(write_accept_ready),

        .pxl_clk(pxl_clk),
        .reset(reset),
        .vga_pixel(vga_pixel),
        .ov7670_xclk(ov7670_xclk)
    );

    // =========================================================
    // CNN CLASS OUT PLACEHOLDER
    // =========================================================
    wire [3:0] class_out;
    assign class_out = 4'd0;

    // =========================================================
    // VGA
    // =========================================================
    vga_from_fifo_rgb565 u_vga_from_fifo_rgb565 (
        .vga_clk(pxl_clk),

        .rst(rst_active_high | async_fifo_read_rd_rst_busy),

        .fifo_dout(vga_pixel),
        .fifo_empty(async_fifo_read_empty),
        .fifo_valid(async_fifo_read_valid),
        .fifo_rd_rst_busy(async_fifo_read_rd_rst_busy),
        .fifo_rd_en(async_fifo_read_rd_en),

        .class_out(class_out),

        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .vga_hs(vga_hs),
        .vga_vs(vga_vs),

        .vga_vblank_start(vga_vblank_start),
        .vga_frame_start(vga_frame_start)
    );

    // =========================================================
    // LED DEBUG
    //
    // led4: camera config done
    // led5: sedang menerima frame kamera ke FIFO
    // led6: FIFO write pernah full saat capture aktif
    // led7: sistem siap menerima frame baru di domain kamera
    // =========================================================
    assign led4 = cam_conf_done;
    assign led5 = capture_frame_active;
    assign led6 = capture_overflow_pclk;
    assign led7 = write_accept_ready_pclk;

endmodule