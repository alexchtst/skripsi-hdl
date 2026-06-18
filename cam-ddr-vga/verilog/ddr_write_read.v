`timescale 1ns / 1ps

module ddr3_to_vga(
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

    // LED debug dari block design
    output wire led4,
    output wire led5,
    output wire led6,
    output wire led7,

    // Pmod VGA Digilent
    output wire [3:0] vga_r,
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,
    output wire       vga_hs,
    output wire       vga_vs
);

    wire        pxl_clk;
    wire [15:0] vga_pixel;

    wire        async_fifo_read_empty;
    wire        async_fifo_read_valid;
    wire        async_fifo_read_rd_rst_busy;
    wire        async_fifo_read_rd_en;

    wire [0:0] led4_bd;
    wire [0:0] led5_bd;
    wire [0:0] led6_bd;
    wire       led7_bd;

    assign led4 = led4_bd[0];
    assign led5 = led5_bd[0];
    assign led6 = led6_bd[0];
    assign led7 = led7_bd;

    // ============================================================
    // Block design wrapper
    // ============================================================
    design_test_write_wrapper u_design_test_write_wrapper (
        .CLK100MHZ(CLK100MHZ),

        .async_fifo_read_empty(async_fifo_read_empty),
        .async_fifo_read_rd_en(async_fifo_read_rd_en),
        .async_fifo_read_rd_rst_busy(async_fifo_read_rd_rst_busy),
        .async_fifo_read_valid(async_fifo_read_valid),

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

        .pxl_clk(pxl_clk),
        .reset(reset),
        .vga_pixel(vga_pixel)
    );

    // ============================================================
    // VGA reader dari FIFO RGB565
    // ============================================================
    vga_from_fifo_rgb565 u_vga_from_fifo_rgb565 (
        .vga_clk(pxl_clk),

        // Catatan:
        // Kalau reset board kamu active-low, maka ini benar.
        // Kalau reset kamu active-high, ubah menjadi:
        // .rst(reset | async_fifo_read_rd_rst_busy)
        .rst((~reset) | async_fifo_read_rd_rst_busy),

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
