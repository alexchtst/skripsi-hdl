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
    wire rst_active_high;
    assign rst_active_high = ~reset;

    // =========================================================
    // CLOCK WIRES FROM DESIGN WRAPPER
    // =========================================================
    wire pxl_clk;
    wire ov7670_xclk;
    wire mig_ui_clk;

    assign cam_xclk = ov7670_xclk;
    assign cam_pwdn = 1'b0;
    assign cam_rst  = reset;

    // =========================================================
    // VGA / FIFO READ WIRES
    // =========================================================
    wire [15:0] vga_pixel;

    wire vga_vblank_start;
    wire vga_frame_start;

    wire async_fifo_read_empty;
    wire async_fifo_read_valid;
    wire async_fifo_read_rd_rst_busy;
    wire async_fifo_read_rd_en;

    // =========================================================
    // FIFO WRITE WIRES
    // =========================================================
    wire [15:0] async_fifo_write_din;
    wire        async_fifo_write_full;
    wire        async_fifo_write_wr_en;
    wire        async_fifo_write_wr_rst_busy;

    // =========================================================
    // BASE ADDRESS CONTROL WIRES
    // =========================================================
    wire write_start_allowed_ui;
    wire read_start_allowed_ui;
    wire write_accept_ready;

    // =========================================================
    // CAMERA CONFIGURATION START DELAY
    // =========================================================
    reg [31:0] cam_conf_cnt     = 32'd0;
    reg        cam_conf_started = 1'b0;
    reg        cam_conf_start   = 1'b0;

    wire cam_conf_done;

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
    wire [15:0] cam_pixel_data;
    wire        cam_pixel_valid;
    wire        cam_frame_done;
    wire        cam_frame_start_pclk;

    wire [9:0] cam_x;
    wire [9:0] cam_y;

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
    // SYNC CAMERA CONFIG DONE TO CAM_PCLK
    // =========================================================
    reg cam_conf_done_meta = 1'b0;
    reg cam_conf_done_pclk = 1'b0;

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
    // SWITCH CDC
    // sw1 = write arm
    // sw0 = read arm
    // =========================================================
    wire sw0_ui;
    wire sw1_ui;
    wire sw1_pclk;

    cdc_bit_sync u_sw0_sync_to_ui (
        .clk      (mig_ui_clk),
        .rst      (rst_active_high),
        .async_in (sw0),
        .sync_out (sw0_ui)
    );

    cdc_bit_sync u_sw1_sync_to_ui (
        .clk      (mig_ui_clk),
        .rst      (rst_active_high),
        .async_in (sw1),
        .sync_out (sw1_ui)
    );

    cdc_bit_sync u_sw1_sync_to_pclk (
        .clk      (cam_pclk),
        .rst      (rst_active_high),
        .async_in (sw1),
        .sync_out (sw1_pclk)
    );

    // =========================================================
    // SYNC WRITE ACCEPT READY TO CAM_PCLK
    // =========================================================
    wire write_accept_ready_pclk;

    cdc_bit_sync u_write_accept_ready_to_pclk (
        .clk      (cam_pclk),
        .rst      (rst_active_high),
        .async_in (write_accept_ready),
        .sync_out (write_accept_ready_pclk)
    );

    // =========================================================
    // STRICT CAMERA CAPTURE CONTROL
    //
    // FIFO mulai diisi hanya saat:
    // - kamera sudah selesai konfigurasi
    // - write arm aktif
    // - base controller siap menerima frame baru
    // - kamera tepat di awal frame
    //
    // accepted_frame_start_pclk digunakan untuk:
    // 1. memulai capture FIFO
    // 2. membuat request write_start_allowed_ui di domain MIG
    // =========================================================
    localparam integer FRAME_PIXELS = 640 * 480;

    reg        capture_active_pclk       = 1'b0;
    reg [18:0] capture_pixel_count_pclk  = 19'd0;
    reg        accepted_frame_start_pclk = 1'b0;

    wire write_arm_pclk;

    // Kalau ingin otomatis tanpa switch, ubah menjadi:
    // assign write_arm_pclk = 1'b1;
    assign write_arm_pclk = sw1_pclk;

    wire capture_start_condition;
    wire capture_enable_now;
    wire fifo_write_fire;

    assign capture_start_condition =
        cam_conf_done_pclk &&
        write_arm_pclk &&
        write_accept_ready_pclk &&
        cam_frame_start_pclk &&
        !capture_active_pclk &&
        !async_fifo_write_full &&
        !async_fifo_write_wr_rst_busy;

    // capture_enable_now dibuat supaya kalau pixel_valid muncul
    // pada cycle yang sama dengan cam_frame_start_pclk,
    // pixel pertama tetap bisa masuk FIFO.
    assign capture_enable_now =
        capture_active_pclk || capture_start_condition;

    assign fifo_write_fire =
        capture_enable_now &&
        cam_pixel_valid &&
        cam_conf_done_pclk &&
        !async_fifo_write_full &&
        !async_fifo_write_wr_rst_busy;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            capture_active_pclk       <= 1'b0;
            capture_pixel_count_pclk  <= 19'd0;
            accepted_frame_start_pclk <= 1'b0;
        end else begin
            // default pulse
            accepted_frame_start_pclk <= 1'b0;

            // Start frame yang diterima.
            // Event ini hanya muncul jika FIFO capture benar-benar dimulai.
            if (capture_start_condition) begin
                accepted_frame_start_pclk <= 1'b1;

                if (!fifo_write_fire) begin
                    capture_active_pclk      <= 1'b1;
                    capture_pixel_count_pclk <= 19'd0;
                end
            end

            // Hitung hanya pixel yang benar-benar masuk FIFO.
            if (fifo_write_fire) begin
                if (capture_pixel_count_pclk == FRAME_PIXELS - 1) begin
                    capture_active_pclk      <= 1'b0;
                    capture_pixel_count_pclk <= 19'd0;
                end else begin
                    capture_active_pclk      <= 1'b1;
                    capture_pixel_count_pclk <= capture_pixel_count_pclk + 1'b1;
                end
            end
        end
    end

    // =========================================================
    // FIFO WRITE DATA
    // =========================================================
    assign async_fifo_write_din   = cam_pixel_data;
    assign async_fifo_write_wr_en = fifo_write_fire;

    // =========================================================
    // DEBUG: FIRST PIXEL WRITTEN TO FIFO
    // Gunakan signal ini di ILA jika ingin memastikan
    // FIFO word pertama adalah cam_x=0, cam_y=0.
    // =========================================================
    reg [9:0] debug_first_fifo_x       = 10'd0;
    reg [9:0] debug_first_fifo_y       = 10'd0;
    reg       debug_first_fifo_latched = 1'b0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            debug_first_fifo_x       <= 10'd0;
            debug_first_fifo_y       <= 10'd0;
            debug_first_fifo_latched <= 1'b0;
        end else begin
            if (accepted_frame_start_pclk) begin
                debug_first_fifo_latched <= 1'b0;
            end else if (fifo_write_fire && !debug_first_fifo_latched) begin
                debug_first_fifo_x       <= cam_x;
                debug_first_fifo_y       <= cam_y;
                debug_first_fifo_latched <= 1'b1;
            end
        end
    end

    // =========================================================
    // CDC ACCEPTED FRAME START TO MIG UI CLOCK
    // =========================================================
    wire accepted_frame_start_ui;

    cdc_event_sync u_accepted_frame_start_to_ui (
        .src_clk    (cam_pclk),
        .src_rst    (rst_active_high),
        .src_signal (accepted_frame_start_pclk),

        .dst_clk    (mig_ui_clk),
        .dst_rst    (rst_active_high),
        .dst_pulse  (accepted_frame_start_ui)
    );

    // =========================================================
    // WRITE START REQUEST LATCH IN MIG UI CLOCK
    //
    // accepted_frame_start_ui hanya pulse 1 clock.
    // Supaya tidak hilang, ditahan sebagai request level.
    // Request dilepas ketika write_accept_ready turun,
    // yang menandakan AXI write sudah mulai busy.
    // =========================================================
    reg write_start_req_ui      = 1'b0;
    reg write_accept_ready_ui_d = 1'b0;

    always @(posedge mig_ui_clk or posedge rst_active_high) begin
        if (rst_active_high) begin
            write_start_req_ui      <= 1'b0;
            write_accept_ready_ui_d <= 1'b0;
        end else begin
            write_accept_ready_ui_d <= write_accept_ready;

            if (accepted_frame_start_ui) begin
                write_start_req_ui <= 1'b1;
            end else if (write_start_req_ui &&
                         write_accept_ready_ui_d &&
                         !write_accept_ready) begin
                write_start_req_ui <= 1'b0;
            end
        end
    end

    assign write_start_allowed_ui = write_start_req_ui;

    // =========================================================
    // VGA VBLANK CDC TO MIG UI CLOCK
    // =========================================================
    wire vga_vblank_start_ui;

    cdc_event_sync u_vga_vblank_start_to_ui (
        .src_clk    (pxl_clk),
        .src_rst    (rst_active_high),
        .src_signal (vga_vblank_start),

        .dst_clk    (mig_ui_clk),
        .dst_rst    (rst_active_high),
        .dst_pulse  (vga_vblank_start_ui)
    );

    // =========================================================
    // READ START ALLOWED
    // =========================================================
    wire read_arm_ui;

    // Kalau ingin otomatis tanpa switch, ubah menjadi:
    // assign read_arm_ui = 1'b1;
    assign read_arm_ui = sw0_ui;

    // Read start hanya boleh saat VGA vblank.
    assign read_start_allowed_ui = read_arm_ui & vga_vblank_start_ui;

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
    // VGA OUTPUT
    // =========================================================
    wire [3:0] class_out;
    assign class_out = 4'd0;

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
    // =========================================================
    assign led4 = cam_conf_done;
    assign led5 = async_fifo_write_full;
    assign led6 = async_fifo_read_empty;
    assign led7 = write_accept_ready;

endmodule