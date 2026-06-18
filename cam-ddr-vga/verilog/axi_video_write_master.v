`timescale 1ns / 1ps

module axi_video_write_master #(
    parameter AXI_ADDR_WIDTH   = 32,
    parameter AXI_DATA_WIDTH   = 64,
    parameter AXI_ID_WIDTH     = 4,

    parameter PIXEL_BITS       = 16,

    parameter FRAME_WIDTH      = 640,
    parameter FRAME_HEIGHT     = 480,

    // Untuk MIG AXI 64-bit, aman pakai burst 8.
    parameter BURST_LEN        = 8,

    // Sesuai FIFO Generator kamu:
    // rd_data_count width = 10-bit
    parameter FIFO_COUNT_WIDTH = 10,

    parameter AXI_ID_VALUE     = 0
)(
    input  wire                         clk,
    input  wire                         rst,          // active-high, sync to clk

    input  wire                         enable,
    input  wire                         frame_start,  // pulse 1 clock
    input  wire [AXI_ADDR_WIDTH-1:0]    frame_base_addr,

    // ============================================================
    // FIFO read side
    // FIFO FWFT 16-bit
    // rd_clk harus sama dengan clk AXI, yaitu MIG ui_clk
    // ============================================================
    input  wire [PIXEL_BITS-1:0]        fifo_dout,
    input  wire                         fifo_empty,
    input  wire                         fifo_valid,
    input  wire [FIFO_COUNT_WIDTH-1:0]  fifo_rd_data_count,
    input  wire                         fifo_rd_rst_busy,
    output reg                          fifo_rd_en,

    // ============================================================
    // AXI4 Write Address Channel
    // ============================================================
    output wire [AXI_ID_WIDTH-1:0]      m_axi_awid,
    output reg  [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]                   m_axi_awlen,
    output wire [2:0]                   m_axi_awsize,
    output wire [1:0]                   m_axi_awburst,
    output wire                         m_axi_awlock,
    output wire [3:0]                   m_axi_awcache,
    output wire [2:0]                   m_axi_awprot,
    output wire [3:0]                   m_axi_awqos,
    output reg                          m_axi_awvalid,
    input  wire                         m_axi_awready,

    // ============================================================
    // AXI4 Write Data Channel
    // ============================================================
    output reg  [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0]  m_axi_wstrb,
    output reg                          m_axi_wlast,
    output reg                          m_axi_wvalid,
    input  wire                         m_axi_wready,

    // ============================================================
    // AXI4 Write Response Channel
    // ============================================================
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_bid,
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output reg                          m_axi_bready,

    // ============================================================
    // Status / debug
    // ============================================================
    output reg                          busy,
    output reg                          done,
    output reg                          error,
    output reg  [3:0]                   debug_state,
    output reg  [31:0]                  debug_pixel_count,
    output reg  [31:0]                  debug_beat_count,
    output reg  [31:0]                  debug_burst_count,
    output reg  [AXI_ADDR_WIDTH-1:0]    debug_current_addr
);

    // ============================================================
    // Local parameters
    // ============================================================
    localparam integer BYTES_PER_BEAT    = AXI_DATA_WIDTH / 8;
    localparam integer PIXELS_PER_BEAT   = AXI_DATA_WIDTH / PIXEL_BITS;
    localparam integer FRAME_PIXELS      = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_BEATS       = FRAME_PIXELS / PIXELS_PER_BEAT;
    localparam integer PIXELS_PER_BURST  = BURST_LEN * PIXELS_PER_BEAT;
    localparam integer ADDR_STEP_BURST   = BURST_LEN * BYTES_PER_BEAT;

    // Untuk konfigurasi sekarang:
    // AXI_DATA_WIDTH   = 64
    // BYTES_PER_BEAT   = 8
    // PIXELS_PER_BEAT  = 4
    // BURST_LEN        = 8
    // PIXELS_PER_BURST = 32
    // ADDR_STEP_BURST  = 64 byte

    // ============================================================
    // AXI size encoder
    // AXI AWSIZE:
    // 000 = 1 byte
    // 001 = 2 byte
    // 010 = 4 byte
    // 011 = 8 byte  -> 64-bit
    // 100 = 16 byte -> 128-bit
    // ============================================================
    function [2:0] axi_size_from_bytes;
        input integer bytes;
        begin
            case (bytes)
                1:   axi_size_from_bytes = 3'b000;
                2:   axi_size_from_bytes = 3'b001;
                4:   axi_size_from_bytes = 3'b010;
                8:   axi_size_from_bytes = 3'b011;
                16:  axi_size_from_bytes = 3'b100;
                32:  axi_size_from_bytes = 3'b101;
                64:  axi_size_from_bytes = 3'b110;
                128: axi_size_from_bytes = 3'b111;
                default: axi_size_from_bytes = 3'b000;
            endcase
        end
    endfunction

    // ============================================================
    // State encoding
    // ============================================================
    localparam [3:0]
        S_IDLE       = 4'd0,
        S_WAIT_FIFO  = 4'd1,
        S_AW         = 4'd2,
        S_PACK       = 4'd3,
        S_W          = 4'd4,
        S_B          = 4'd5,
        S_DONE       = 4'd6,
        S_ERROR      = 4'd7;

    reg [3:0] state;

    reg [AXI_ADDR_WIDTH-1:0] addr_reg;

    reg [31:0] pixel_count;
    reg [31:0] beat_count_total;
    reg [31:0] burst_count_total;

    reg [7:0]  beat_index_in_burst;
    reg [3:0]  pack_index;

    reg [AXI_DATA_WIDTH-1:0] pack_reg;

    // ============================================================
    // AXI constant signals
    // ============================================================
    assign m_axi_awid    = AXI_ID_VALUE;
    assign m_axi_awlen   = BURST_LEN - 1;
    assign m_axi_awsize  = axi_size_from_bytes(BYTES_PER_BEAT);
    assign m_axi_awburst = 2'b01;        // INCR burst
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'b0000;

    assign m_axi_wstrb   = {BYTES_PER_BEAT{1'b1}};

    // ============================================================
    // Main FSM
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            state                 <= S_IDLE;

            fifo_rd_en            <= 1'b0;

            m_axi_awaddr          <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awvalid         <= 1'b0;

            m_axi_wdata           <= {AXI_DATA_WIDTH{1'b0}};
            m_axi_wlast           <= 1'b0;
            m_axi_wvalid          <= 1'b0;

            m_axi_bready          <= 1'b0;

            busy                  <= 1'b0;
            done                  <= 1'b0;
            error                 <= 1'b0;
            debug_state           <= S_IDLE;

            addr_reg              <= {AXI_ADDR_WIDTH{1'b0}};

            pixel_count           <= 32'd0;
            beat_count_total      <= 32'd0;
            burst_count_total     <= 32'd0;

            beat_index_in_burst   <= 8'd0;
            pack_index            <= 4'd0;
            pack_reg              <= {AXI_DATA_WIDTH{1'b0}};

            debug_pixel_count     <= 32'd0;
            debug_beat_count      <= 32'd0;
            debug_burst_count     <= 32'd0;
            debug_current_addr    <= {AXI_ADDR_WIDTH{1'b0}};
        end else begin
            // Default pulse
            fifo_rd_en  <= 1'b0;
            done        <= 1'b0;
            debug_state <= state;

            case (state)

                // ====================================================
                // IDLE
                // Menunggu frame_start dari base_address_controller.
                // ====================================================
                S_IDLE: begin
                    busy          <= 1'b0;
                    error         <= 1'b0;

                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;

                    fifo_rd_en    <= 1'b0;

                    if (enable && frame_start && !fifo_rd_rst_busy) begin
                        busy                  <= 1'b1;

                        addr_reg              <= frame_base_addr;
                        m_axi_awaddr          <= frame_base_addr;
                        debug_current_addr    <= frame_base_addr;

                        pixel_count           <= 32'd0;
                        beat_count_total      <= 32'd0;
                        burst_count_total     <= 32'd0;

                        beat_index_in_burst   <= 8'd0;
                        pack_index            <= 4'd0;
                        pack_reg              <= {AXI_DATA_WIDTH{1'b0}};

                        debug_pixel_count     <= 32'd0;
                        debug_beat_count      <= 32'd0;
                        debug_burst_count     <= 32'd0;

                        state                 <= S_WAIT_FIFO;
                    end
                end

                // ====================================================
                // WAIT FIFO
                // Tunggu FIFO punya cukup pixel untuk 1 burst.
                //
                // Dengan 64-bit AXI:
                // 1 beat  = 4 pixel
                // 1 burst = 8 beat = 32 pixel
                // ====================================================
                S_WAIT_FIFO: begin
                    if (!enable) begin
                        state <= S_IDLE;
                    end else if (fifo_rd_rst_busy) begin
                        state <= S_WAIT_FIFO;
                    end else if (beat_count_total >= FRAME_BEATS) begin
                        state <= S_DONE;
                    end else if (fifo_rd_data_count >= PIXELS_PER_BURST) begin
                        m_axi_awaddr      <= addr_reg;
                        debug_current_addr <= addr_reg;
                        m_axi_awvalid     <= 1'b1;
                        state             <= S_AW;
                    end
                end

                // ====================================================
                // AW CHANNEL
                // Kirim alamat awal burst.
                // ====================================================
                S_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid       <= 1'b0;

                        beat_index_in_burst <= 8'd0;
                        pack_index          <= 4'd0;
                        pack_reg            <= {AXI_DATA_WIDTH{1'b0}};

                        state               <= S_PACK;
                    end
                end

                // ====================================================
                // PACK
                // FIFO FWFT:
                // - fifo_valid = 1 berarti fifo_dout sudah valid
                // - fifo_rd_en = 1 consume pixel sekarang
                //
                // Untuk AXI 64-bit:
                // - ambil 4 pixel 16-bit
                // - susun menjadi 1 beat 64-bit
                //
                // Urutan packing:
                // pixel0 -> bit [15:0]
                // pixel1 -> bit [31:16]
                // pixel2 -> bit [47:32]
                // pixel3 -> bit [63:48]
                // ====================================================
                S_PACK: begin
                    if (!enable) begin
                        state <= S_IDLE;
                    end else if (fifo_valid && !fifo_empty && !fifo_rd_rst_busy) begin
                        fifo_rd_en <= 1'b1;

                        pack_reg[pack_index*PIXEL_BITS +: PIXEL_BITS] <= fifo_dout;
                        pixel_count <= pixel_count + 32'd1;

                        if (pack_index == PIXELS_PER_BEAT - 1) begin
                            // Kirim beat yang sudah lengkap.
                            // Karena assignment non-blocking, slice terakhir
                            // ditulis langsung juga ke m_axi_wdata.
                            m_axi_wdata <= pack_reg;
                            m_axi_wdata[pack_index*PIXEL_BITS +: PIXEL_BITS] <= fifo_dout;

                            m_axi_wvalid <= 1'b1;
                            m_axi_wlast  <= (beat_index_in_burst == BURST_LEN - 1);

                            pack_index   <= 4'd0;
                            state        <= S_W;
                        end else begin
                            pack_index <= pack_index + 4'd1;
                        end
                    end
                end

                // ====================================================
                // W CHANNEL
                // Kirim 1 beat data ke MIG/SmartConnect.
                // ====================================================
                S_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast  <= 1'b0;

                        beat_count_total <= beat_count_total + 32'd1;

                        if (beat_index_in_burst == BURST_LEN - 1) begin
                            beat_index_in_burst <= 8'd0;
                            m_axi_bready        <= 1'b1;
                            state               <= S_B;
                        end else begin
                            beat_index_in_burst <= beat_index_in_burst + 8'd1;
                            pack_reg            <= {AXI_DATA_WIDTH{1'b0}};
                            pack_index          <= 4'd0;
                            state               <= S_PACK;
                        end
                    end
                end

                // ====================================================
                // B RESPONSE
                // Tunggu respons write dari MIG/SmartConnect.
                //
                // BRESP:
                // 00 = OKAY
                // selain itu dianggap error.
                // ====================================================
                S_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;

                        if (m_axi_bresp != 2'b00) begin
                            error <= 1'b1;
                            state <= S_ERROR;
                        end else begin
                            burst_count_total <= burst_count_total + 32'd1;
                            addr_reg          <= addr_reg + ADDR_STEP_BURST;
                            debug_current_addr <= addr_reg + ADDR_STEP_BURST;

                            if (beat_count_total >= FRAME_BEATS) begin
                                state <= S_DONE;
                            end else begin
                                state <= S_WAIT_FIFO;
                            end
                        end
                    end
                end

                // ====================================================
                // DONE
                // Satu frame selesai ditulis ke DDR3.
                // done hanya pulse 1 clock.
                // ====================================================
                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;

                    debug_pixel_count <= pixel_count;
                    debug_beat_count  <= beat_count_total;
                    debug_burst_count <= burst_count_total;

                    state <= S_IDLE;
                end

                // ====================================================
                // ERROR
                // Berhenti jika BRESP error.
                // ====================================================
                S_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b0;

                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    fifo_rd_en    <= 1'b0;

                    debug_pixel_count <= pixel_count;
                    debug_beat_count  <= beat_count_total;
                    debug_burst_count <= burst_count_total;

                    // Tetap di error sampai reset.
                    state <= S_ERROR;
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
