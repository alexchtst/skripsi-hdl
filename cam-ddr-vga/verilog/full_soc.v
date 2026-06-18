`timescale 1ns / 1ps

module full_soc(
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

    // OV7670
    output wire        cam_scl,
    inout  wire        cam_sda,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire        cam_pclk,
    output wire        cam_xclk,
    output wire        cam_pwdn,
    output wire        cam_rst,
    input  wire [7:0]  cam_d,

    // VGA
    output wire [3:0] vga_r,
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,
    output wire       vga_hs,
    output wire       vga_vs
);

    // ============================================================
    // Reset assumption:
    // reset board active-low
    // internal reset active-high = ~reset
    // ============================================================
    wire rst_active_high;
    assign rst_active_high = ~reset;

    // ============================================================
    // Wires from block design
    // ============================================================
    wire        pxl_clk;
    wire        ov7670_xclk;
    wire        mig_ui_clk;

    wire [15:0] vga_pixel;

    wire        async_fifo_read_empty;
    wire        async_fifo_read_valid;
    wire        async_fifo_read_rd_rst_busy;
    wire        async_fifo_read_rd_en;

    wire [15:0] async_fifo_write_din;
    wire        async_fifo_write_full;
    wire        async_fifo_write_wr_en;
    wire        async_fifo_write_wr_rst_busy;

    // ============================================================
    // OV7670 fixed control pins
    // ============================================================
    assign cam_xclk = ov7670_xclk;

    // OV7670 normal mode
    assign cam_pwdn = 1'b0;

    // Untuk modul OV7670 umum, RESET active-low.
    // Karena reset board kamu active-low, ini cocok:
    // reset = 0 -> camera reset
    // reset = 1 -> camera normal
    assign cam_rst = reset;

    // ============================================================
    // Camera SCCB configuration
    // ============================================================
    reg [31:0] cam_conf_cnt     = 32'd0;
    reg        cam_conf_started = 1'b0;
    reg        cam_conf_start   = 1'b0;

    wire       cam_conf_done;

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
                    cam_conf_start   <= 1'b1; // pulse 1 clock
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

    // ============================================================
    // Camera pixel capture
    // ============================================================
    wire [15:0] cam_pixel_data;
    wire        cam_pixel_valid;
    wire        cam_frame_done;

    camera_read u_camera_read (
        .p_clock     (cam_pclk),
        .vsync       (cam_vsync),
        .href        (cam_href),
        .p_data      (cam_d),

        .pixel_data  (cam_pixel_data),
        .pixel_valid (cam_pixel_valid),
        .frame_done  (cam_frame_done)
    );

    // ============================================================
    // Sync config_done from CLK100MHZ domain to cam_pclk domain
    // ============================================================
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

    // ============================================================
    // Camera -> async FIFO write
    // This replaces VIO probe_out4/probe_out5
    // ============================================================
    assign async_fifo_write_din = cam_pixel_data;

    assign async_fifo_write_wr_en = cam_pixel_valid
                                  & cam_conf_done_pclk
                                  & ~async_fifo_write_full
                                  & ~async_fifo_write_wr_rst_busy;

    // ============================================================
    // Block design wrapper
    // ============================================================
    design_test_write_wrapper design_test_write_i (
        .CLK100MHZ(CLK100MHZ),
        .mig_ui_clk(mig_ui_clk),

        // WAJIB:
        // cam_pclk harus masuk ke async_fifo_write.wr_clk di block design.
        // Kalau port ini belum ada di wrapper kamu, expose cam_pclk dari BD.
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

        .led4(led4),
        .led5(led5),
        .led6(led6),
        .led7(led7),

        .pxl_clk(pxl_clk),
        .reset(reset),
        .vga_pixel(vga_pixel),
        .ov7670_xclk(ov7670_xclk)
    );

    // ============================================================
    // VGA reader from DDR/FIFO RGB565
    // ============================================================
    vga_from_fifo_rgb565 u_vga_from_fifo_rgb565 (
        .vga_clk(pxl_clk),

        .rst(rst_active_high | async_fifo_read_rd_rst_busy),

        .fifo_dout(vga_pixel),
        .fifo_empty(async_fifo_read_empty),
        .fifo_valid(async_fifo_read_valid),
        .fifo_rd_rst_busy(async_fifo_read_rd_rst_busy),
        .fifo_rd_en(async_fifo_read_rd_en),

        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .vga_hs(vga_hs),
        .vga_vs(vga_vs)
    );

endmodule