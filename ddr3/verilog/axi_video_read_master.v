`timescale 1ns / 1ps

module axi_video_read_master #(
    parameter AXI_ADDR_WIDTH   = 32,
    parameter AXI_DATA_WIDTH   = 64,
    parameter AXI_ID_WIDTH     = 4,

    parameter PIXEL_BITS       = 16,

    parameter FRAME_WIDTH      = 640,
    parameter FRAME_HEIGHT     = 480,

    // Untuk MIG AXI 64-bit, aman pakai burst 8.
    parameter BURST_LEN        = 8,

    // Sesuai FIFO Generator kamu:
    // wr_data_count width = 10-bit
    parameter FIFO_COUNT_WIDTH = 10,

    // FIFO depth efektif untuk count 10-bit.
    // Walaupun di GUI kamu tulis 1028, count 10-bit praktis dipakai sebagai 1024 level.
    parameter FIFO_DEPTH_WORDS = 1024,

    // Margin supaya tidak terlalu dekat full.
    parameter FIFO_SAFE_MARGIN = 8,

    parameter AXI_ID_VALUE     = 0
)(
    input  wire                         clk,
    input  wire                         rst,          // active-high, sync to clk

    input  wire                         enable,
    input  wire                         frame_start,  // pulse 1 clock
    input  wire [AXI_ADDR_WIDTH-1:0]    frame_base_addr,

    // ============================================================
    // FIFO write side
    // FIFO FWFT 16-bit
    // wr_clk harus sama dengan clk AXI, yaitu MIG ui_clk
    // ============================================================
    output reg  [PIXEL_BITS-1:0]        fifo_din,
    output reg                          fifo_wr_en,
    input  wire                         fifo_full,
    input  wire                         fifo_almost_full,
    input  wire [FIFO_COUNT_WIDTH-1:0]  fifo_wr_data_count,
    input  wire                         fifo_wr_rst_busy,

    // ============================================================
    // AXI4 Read Address Channel
    // ============================================================
    output wire [AXI_ID_WIDTH-1:0]      m_axi_arid,
    output reg  [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]                   m_axi_arlen,
    output wire [2:0]                   m_axi_arsize,
    output wire [1:0]                   m_axi_arburst,
    output wire                         m_axi_arlock,
    output wire [3:0]                   m_axi_arcache,
    output wire [2:0]                   m_axi_arprot,
    output wire [3:0]                   m_axi_arqos,
    output reg                          m_axi_arvalid,
    input  wire                         m_axi_arready,

    // ============================================================
    // AXI4 Read Data Channel
    // ============================================================
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rlast,
    input  wire                         m_axi_rvalid,
    output reg                          m_axi_rready,

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

    localparam integer FIFO_START_LEVEL  =
        FIFO_DEPTH_WORDS - PIXELS_PER_BURST - FIFO_SAFE_MARGIN;

    // Untuk konfigurasi sekarang:
    // AXI_DATA_WIDTH   = 64
    // BYTES_PER_BEAT   = 8
    // PIXELS_PER_BEAT  = 4
    // BURST_LEN        = 8
    // PIXELS_PER_BURST = 32
    // ADDR_STEP_BURST  = 64 byte

    // ============================================================
    // AXI size encoder
    // AXI ARSIZE:
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
        S_IDLE        = 4'd0,
        S_WAIT_SPACE  = 4'd1,
        S_AR          = 4'd2,
        S_R           = 4'd3,
        S_UNPACK      = 4'd4,
        S_DONE        = 4'd5,
        S_ERROR       = 4'd6;

    reg [3:0] state;

    reg [AXI_ADDR_WIDTH-1:0] addr_reg;

    reg [31:0] pixel_count;
    reg [31:0] beat_count_total;
    reg [31:0] burst_count_total;

    reg [7:0]  beat_index_in_burst;
    reg [3:0]  unpack_index;

    reg [AXI_DATA_WIDTH-1:0] read_data_reg;
    reg                      read_last_reg;

    wire [31:0] fifo_used_words;
    wire        fifo_has_space_for_burst;

    assign fifo_used_words = fifo_wr_data_count;

    assign fifo_has_space_for_burst =
        (!fifo_full) &&
        (!fifo_almost_full) &&
        (!fifo_wr_rst_busy) &&
        (fifo_used_words <= FIFO_START_LEVEL);

    // ============================================================
    // AXI constant signals
    // ============================================================
    assign m_axi_arid    = AXI_ID_VALUE;
    assign m_axi_arlen   = BURST_LEN - 1;
    assign m_axi_arsize  = axi_size_from_bytes(BYTES_PER_BEAT);
    assign m_axi_arburst = 2'b01;        // INCR burst
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;

    // ============================================================
    // Main FSM
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            state                <= S_IDLE;

            fifo_din             <= {PIXEL_BITS{1'b0}};
            fifo_wr_en           <= 1'b0;

            m_axi_araddr         <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_arvalid        <= 1'b0;
            m_axi_rready         <= 1'b0;

            busy                 <= 1'b0;
            done                 <= 1'b0;
            error                <= 1'b0;
            debug_state          <= S_IDLE;

            addr_reg             <= {AXI_ADDR_WIDTH{1'b0}};

            pixel_count          <= 32'd0;
            beat_count_total     <= 32'd0;
            burst_count_total    <= 32'd0;

            beat_index_in_burst  <= 8'd0;
            unpack_index         <= 4'd0;

            read_data_reg        <= {AXI_DATA_WIDTH{1'b0}};
            read_last_reg        <= 1'b0;

            debug_pixel_count    <= 32'd0;
            debug_beat_count     <= 32'd0;
            debug_burst_count    <= 32'd0;
            debug_current_addr   <= {AXI_ADDR_WIDTH{1'b0}};
        end else begin
            // Default pulse
            fifo_wr_en  <= 1'b0;
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

                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b0;

                    fifo_wr_en    <= 1'b0;

                    if (enable && frame_start && !fifo_wr_rst_busy) begin
                        busy                 <= 1'b1;

                        addr_reg             <= frame_base_addr;
                        m_axi_araddr         <= frame_base_addr;
                        debug_current_addr   <= frame_base_addr;

                        pixel_count          <= 32'd0;
                        beat_count_total     <= 32'd0;
                        burst_count_total    <= 32'd0;

                        beat_index_in_burst  <= 8'd0;
                        unpack_index         <= 4'd0;

                        read_data_reg        <= {AXI_DATA_WIDTH{1'b0}};
                        read_last_reg        <= 1'b0;

                        debug_pixel_count    <= 32'd0;
                        debug_beat_count     <= 32'd0;
                        debug_burst_count    <= 32'd0;

                        state                <= S_WAIT_SPACE;
                    end
                end

                // ====================================================
                // WAIT SPACE
                // Tunggu FIFO punya ruang cukup untuk 1 burst.
                //
                // Dengan AXI 64-bit:
                // 1 beat  = 4 pixel
                // 1 burst = 8 beat = 32 pixel
                // ====================================================
                S_WAIT_SPACE: begin
                    m_axi_rready <= 1'b0;

                    if (!enable) begin
                        state <= S_IDLE;
                    end else if (beat_count_total >= FRAME_BEATS) begin
                        state <= S_DONE;
                    end else if (fifo_has_space_for_burst) begin
                        m_axi_araddr   <= addr_reg;
                        m_axi_arvalid  <= 1'b1;
                        debug_current_addr <= addr_reg;
                        state          <= S_AR;
                    end
                end

                // ====================================================
                // AR CHANNEL
                // Kirim alamat awal burst read.
                // ====================================================
                S_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid       <= 1'b0;

                        beat_index_in_burst <= 8'd0;
                        unpack_index        <= 4'd0;

                        // Siap menerima data read dari AXI.
                        m_axi_rready        <= 1'b1;

                        state               <= S_R;
                    end else if (!enable) begin
                        // Belum handshake, jadi aman batal.
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b0;
                        busy          <= 1'b0;
                        state         <= S_IDLE;
                    end
                end

                // ====================================================
                // R CHANNEL
                // Ambil 1 beat 64-bit dari AXI.
                // Setelah 1 beat diterima, pecah menjadi 4 pixel 16-bit.
                // ====================================================
                S_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready  <= 1'b0;

                        read_data_reg <= m_axi_rdata;
                        read_last_reg <= m_axi_rlast;

                        if (m_axi_rresp != 2'b00) begin
                            error <= 1'b1;
                            state <= S_ERROR;
                        end else begin
                            unpack_index <= 4'd0;
                            state        <= S_UNPACK;
                        end
                    end
                end

                // ====================================================
                // UNPACK
                // AXI 64-bit berisi 4 pixel RGB565:
                //
                // pixel0 = bits [15:0]
                // pixel1 = bits [31:16]
                // pixel2 = bits [47:32]
                // pixel3 = bits [63:48]
                //
                // Tulis ke async_fifo_read satu pixel per clock.
                // ====================================================
                S_UNPACK: begin
                    if (!fifo_full && !fifo_wr_rst_busy) begin
                        fifo_din   <= read_data_reg[unpack_index*PIXEL_BITS +: PIXEL_BITS];
                        fifo_wr_en <= 1'b1;

                        pixel_count <= pixel_count + 32'd1;

                        if (unpack_index == PIXELS_PER_BEAT - 1) begin
                            unpack_index     <= 4'd0;
                            beat_count_total <= beat_count_total + 32'd1;

                            // Cek RLAST:
                            // RLAST harus muncul hanya pada beat terakhir burst.
                            if ((read_last_reg && (beat_index_in_burst != BURST_LEN - 1)) ||
                                (!read_last_reg && (beat_index_in_burst == BURST_LEN - 1))) begin
                                error <= 1'b1;
                                state <= S_ERROR;
                            end else begin
                                if (beat_index_in_burst == BURST_LEN - 1) begin
                                    // Satu burst selesai.
                                    burst_count_total <= burst_count_total + 32'd1;

                                    addr_reg <= addr_reg + ADDR_STEP_BURST;
                                    debug_current_addr <= addr_reg + ADDR_STEP_BURST;

                                    beat_index_in_burst <= 8'd0;
                                    m_axi_rready        <= 1'b0;

                                    if ((beat_count_total + 32'd1) >= FRAME_BEATS) begin
                                        state <= S_DONE;
                                    end else begin
                                        state <= S_WAIT_SPACE;
                                    end
                                end else begin
                                    // Masih ada beat berikutnya dalam burst ini.
                                    beat_index_in_burst <= beat_index_in_burst + 8'd1;

                                    // Siap menerima beat AXI berikutnya.
                                    m_axi_rready <= 1'b1;
                                    state        <= S_R;
                                end
                            end
                        end else begin
                            unpack_index <= unpack_index + 4'd1;
                        end
                    end
                end

                // ====================================================
                // DONE
                // Satu frame selesai dibaca dari DDR3 dan dimasukkan FIFO.
                // done hanya pulse 1 clock.
                // ====================================================
                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;

                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b0;
                    fifo_wr_en    <= 1'b0;

                    debug_pixel_count <= pixel_count;
                    debug_beat_count  <= beat_count_total;
                    debug_burst_count <= burst_count_total;

                    state <= S_IDLE;
                end

                // ====================================================
                // ERROR
                // Berhenti jika RRESP error atau RLAST tidak sesuai.
                // ====================================================
                S_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b0;

                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b0;
                    fifo_wr_en    <= 1'b0;

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

