`timescale 1ns / 1ps

module ddr_write_read(
    input wire CLK100MHZ,
    input wire reset,

    output wire cam_scl,
    inout wire cam_sda,

    input wire cam_vsync,
    input wire cam_pclk,
    input wire cam_href,
    input wire [7:0] cam_d,

    output wire cam_xclk,
    output wire cam_rst,
    output wire cam_pwdn,

    output wire [13:0] ddr3_sdram_addr,
    output wire [2:0] ddr3_sdram_ba,
    output wire ddr3_sdram_cas_n,
    output wire [0:0] ddr3_sdram_ck_n,
    output wire [0:0] ddr3_sdram_ck_p,
    output wire [0:0] ddr3_sdram_cke,
    output wire [0:0] ddr3_sdram_cs_n,
    output wire [1:0] ddr3_sdram_dm,
    inout wire [15:0] ddr3_sdram_dq,
    inout wire [1:0] ddr3_sdram_dqs_n,
    inout wire [1:0] ddr3_sdram_dqs_p,
    output wire [0:0] ddr3_sdram_odt,
    output wire ddr3_sdram_ras_n,
    output wire ddr3_sdram_reset_n,
    output wire ddr3_sdram_we_n,

    output wire led4,
    output wire led5,
    output wire led6,
    output wire led7,

    output wire [3:0] vga_r,
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,
    output wire vga_hs,
    output wire vga_vs
);

    localparam integer ENABLE_OV7670_TEST_PATTERN = 1;

    wire rst_active_high;
    assign rst_active_high = ~reset;

    assign cam_pwdn = 1'b0;

    wire [15:0] cam_fifo_din;
    wire cam_fifo_wr_en;
    wire cam_fifo_full;
    wire cam_fifo_wr_rst_busy;

    wire cam_frame_start;
    wire [9:0] cam_x;
    wire [9:0] cam_y;

    wire pxl_clk;
    wire mig_ui_clk;
    wire [15:0] vga_pixel;

    wire async_fifo_read_empty;
    wire async_fifo_read_valid;
    wire async_fifo_read_rd_rst_busy;
    wire async_fifo_read_rd_en;

    wire [0:0] led4_bd;
    wire [0:0] led5_bd;
    wire [0:0] led6_bd;
    wire led7_bd;

    wire cam_config_done;
    wire cam_config_busy;
    wire cam_config_error;

    wire base_address_control_enable;
    wire base_address_control_write_start_allowed;
    wire base_address_control_read_start_allowed;

    (* ASYNC_REG = "TRUE" *) reg config_done_meta_pclk = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg config_done_sync_pclk = 1'b0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            config_done_meta_pclk <= 1'b0;
            config_done_sync_pclk <= 1'b0;
        end else begin
            config_done_meta_pclk <= cam_config_done;
            config_done_sync_pclk <= config_done_meta_pclk;
        end
    end

    wire cam_capture_rst;
    assign cam_capture_rst = rst_active_high | (~config_done_sync_pclk) | cam_fifo_wr_rst_busy;

    reg first_frame_done_pclk = 1'b0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            first_frame_done_pclk <= 1'b0;
        end else begin
            if (cam_fifo_wr_en && cam_x == 10'd639 && cam_y == 10'd479) begin
                first_frame_done_pclk <= 1'b1;
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg config_done_meta_ui = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg config_done_sync_ui = 1'b0;

    (* ASYNC_REG = "TRUE" *) reg first_frame_done_meta_ui = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg first_frame_done_sync_ui = 1'b0;

    (* ASYNC_REG = "TRUE" *) reg rst_meta_ui = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_sync_ui = 1'b1;

    always @(posedge mig_ui_clk or posedge rst_active_high) begin
        if (rst_active_high) begin
            config_done_meta_ui <= 1'b0;
            config_done_sync_ui <= 1'b0;

            first_frame_done_meta_ui <= 1'b0;
            first_frame_done_sync_ui <= 1'b0;

            rst_meta_ui <= 1'b1;
            rst_sync_ui <= 1'b1;
        end else begin
            config_done_meta_ui <= cam_config_done;
            config_done_sync_ui <= config_done_meta_ui;

            first_frame_done_meta_ui <= first_frame_done_pclk;
            first_frame_done_sync_ui <= first_frame_done_meta_ui;

            rst_meta_ui <= 1'b0;
            rst_sync_ui <= rst_meta_ui;
        end
    end

    assign base_address_control_enable = (~rst_sync_ui) & config_done_sync_ui;
    assign base_address_control_write_start_allowed = base_address_control_enable;
    assign base_address_control_read_start_allowed = base_address_control_enable & first_frame_done_sync_ui;

    (* ASYNC_REG = "TRUE" *) reg rst_meta_pxl = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_sync_pxl = 1'b1;

    always @(posedge pxl_clk or posedge rst_active_high) begin
        if (rst_active_high) begin
            rst_meta_pxl <= 1'b1;
            rst_sync_pxl <= 1'b1;
        end else begin
            rst_meta_pxl <= 1'b0;
            rst_sync_pxl <= rst_meta_pxl;
        end
    end

    wire vga_local_rst;
    assign vga_local_rst = rst_sync_pxl | async_fifo_read_rd_rst_busy;

    design_test_write_wrapper u_bd (
        .CLK100MHZ(CLK100MHZ),

        .async_fifo_read_empty(async_fifo_read_empty),
        .async_fifo_read_rd_en(async_fifo_read_rd_en),
        .async_fifo_read_rd_rst_busy(async_fifo_read_rd_rst_busy),
        .async_fifo_read_valid(async_fifo_read_valid),

        .async_fifo_write_din(cam_fifo_din),
        .async_fifo_write_full(cam_fifo_full),
        .async_fifo_write_wr_en(cam_fifo_wr_en),
        .async_fifo_write_wr_rst_busy(cam_fifo_wr_rst_busy),

        .base_address_control_enable(base_address_control_enable),
        .base_address_control_read_start_allowed(base_address_control_read_start_allowed),
        .base_address_control_write_start_allowed(base_address_control_write_start_allowed),

        .cam_pclk(cam_pclk),

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

        .led4(led4_bd),
        .led5(led5_bd),
        .led6(led6_bd),
        .led7(led7_bd),

        .mig_ui_clk(mig_ui_clk),
        .ov7670_xclk(cam_xclk),
        .pxl_clk(pxl_clk),
        .reset(reset),
        .vga_pixel(vga_pixel)
    );

    ov7670_sccb_config #(
        .CLK_FREQ_HZ(100_000_000),
        .SCCB_FREQ_HZ(100_000),
        .ENABLE_TEST_PATTERN(ENABLE_OV7670_TEST_PATTERN)
    ) u_ov7670_sccb_config (
        .clk(CLK100MHZ),
        .rst(rst_active_high),
        .start(1'b1),

        .scl(cam_scl),
        .sda(cam_sda),

        .cam_rst(cam_rst),

        .done(cam_config_done),
        .busy(cam_config_busy),
        .error(cam_config_error)
    );

    ov7670_rgb565_capture_to_fifo u_cam_capture (
        .pclk(cam_pclk),
        .rst(cam_capture_rst),

        .cam_vsync(cam_vsync),
        .cam_href(cam_href),
        .cam_d(cam_d),

        .fifo_full(cam_fifo_full),
        .fifo_wr_rst_busy(cam_fifo_wr_rst_busy),

        .fifo_din(cam_fifo_din),
        .fifo_wr_en(cam_fifo_wr_en),

        .frame_start(cam_frame_start),
        .x(cam_x),
        .y(cam_y)
    );

    vga_from_fifo_rgb565 u_vga_from_fifo_rgb565 (
        .vga_clk(pxl_clk),
        .rst(vga_local_rst),

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

    reg cam_pixel_seen_pclk = 1'b0;

    always @(posedge cam_pclk or posedge rst_active_high) begin
        if (rst_active_high) begin
            cam_pixel_seen_pclk <= 1'b0;
        end else begin
            if (cam_fifo_wr_en) begin
                cam_pixel_seen_pclk <= 1'b1;
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg cam_pixel_seen_meta_sys = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg cam_pixel_seen_sync_sys = 1'b0;

    always @(posedge CLK100MHZ or posedge rst_active_high) begin
        if (rst_active_high) begin
            cam_pixel_seen_meta_sys <= 1'b0;
            cam_pixel_seen_sync_sys <= 1'b0;
        end else begin
            cam_pixel_seen_meta_sys <= cam_pixel_seen_pclk;
            cam_pixel_seen_sync_sys <= cam_pixel_seen_meta_sys;
        end
    end

    assign led4 = cam_config_done;
    assign led5 = cam_config_error;
    assign led6 = cam_pixel_seen_sync_sys;
    assign led7 = led7_bd;

    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_config_done = cam_config_done;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_config_busy = cam_config_busy;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_config_error = cam_config_error;

    (* MARK_DEBUG = "TRUE" *) wire dbg_base_enable = base_address_control_enable;
    (* MARK_DEBUG = "TRUE" *) wire dbg_base_write_allowed = base_address_control_write_start_allowed;
    (* MARK_DEBUG = "TRUE" *) wire dbg_base_read_allowed = base_address_control_read_start_allowed;
    (* MARK_DEBUG = "TRUE" *) wire dbg_first_frame_done_pclk = first_frame_done_pclk;
    (* MARK_DEBUG = "TRUE" *) wire dbg_first_frame_done_sync_ui = first_frame_done_sync_ui;

    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_vsync = cam_vsync;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_href = cam_href;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_pclk = cam_pclk;
    (* MARK_DEBUG = "TRUE" *) wire [7:0] dbg_cam_d = cam_d;

    (* MARK_DEBUG = "TRUE" *) wire [15:0] dbg_cam_fifo_din = cam_fifo_din;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_fifo_wr_en = cam_fifo_wr_en;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_fifo_full = cam_fifo_full;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_fifo_wr_rst_busy = cam_fifo_wr_rst_busy;
    (* MARK_DEBUG = "TRUE" *) wire dbg_cam_frame_start = cam_frame_start;
    (* MARK_DEBUG = "TRUE" *) wire [9:0] dbg_cam_x = cam_x;
    (* MARK_DEBUG = "TRUE" *) wire [9:0] dbg_cam_y = cam_y;

    (* MARK_DEBUG = "TRUE" *) wire [15:0] dbg_vga_pixel = vga_pixel;
    (* MARK_DEBUG = "TRUE" *) wire dbg_fifo_read_empty = async_fifo_read_empty;
    (* MARK_DEBUG = "TRUE" *) wire dbg_fifo_read_valid = async_fifo_read_valid;
    (* MARK_DEBUG = "TRUE" *) wire dbg_fifo_read_rd_en = async_fifo_read_rd_en;

endmodule