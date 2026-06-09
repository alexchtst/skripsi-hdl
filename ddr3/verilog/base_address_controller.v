`timescale 1ns / 1ps

module base_address_controller #(
    parameter ADDR_WIDTH = 32,

    // Untuk MIG AXI address width 28-bit.
    // AXI address adalah byte address.
    parameter [ADDR_WIDTH-1:0] BUFFER0_BASE_ADDR = 32'h8000_0000,
    parameter [ADDR_WIDTH-1:0] BUFFER1_BASE_ADDR = 32'h8010_0000,

    // 640 x 480 x 2 byte = 614400 byte = 0x96000.
    // Parameter ini dipakai untuk dokumentasi/debug.
    parameter [31:0] FRAME_BYTES = 32'd614400
)(
    input  wire                   clk,   // ui_clk dari MIG
    input  wire                   rst,   // active-high reset, contoh: peripheral_reset

    input  wire                   enable,
    input  wire                   init_calib_complete,

    // Optional start gate.
    // Untuk test awal, tie ke 1'b1.
    // Nanti bisa dipakai untuk menunggu FIFO/camera/VGA siap.
    input  wire                   write_start_allowed,
    input  wire                   read_start_allowed,

    // Status dari AXI write master
    input  wire                   axi_write_busy,
    input  wire                   axi_write_done,
    input  wire                   axi_write_error,

    // Status dari AXI read master
    input  wire                   axi_read_busy,
    input  wire                   axi_read_done,
    input  wire                   axi_read_error,

    // Control ke AXI write master
    output wire                   axi_write_enable,
    output reg                    axi_write_frame_start,
    output reg  [ADDR_WIDTH-1:0]  axi_write_frame_base_addr,

    // Control ke AXI read master
    output wire                   axi_read_enable,
    output reg                    axi_read_frame_start,
    output reg  [ADDR_WIDTH-1:0]  axi_read_frame_base_addr,

    // Debug
    output reg  [3:0]             debug_state,
    output reg                    debug_write_buffer_index,
    output reg                    debug_read_buffer_index,
    output reg                    debug_first_frame_valid,
    output reg                    debug_error_latched,
    output reg  [31:0]            debug_write_frame_count,
    output reg  [31:0]            debug_read_frame_count
);

    // ============================================================
    // State encoding
    // ============================================================
    localparam S_IDLE              = 4'd0;
    localparam S_START_FIRST_WRITE = 4'd1;
    localparam S_WAIT_FIRST_WRITE  = 4'd2;
    localparam S_START_BOTH        = 4'd3;
    localparam S_WAIT_BOTH         = 4'd4;
    localparam S_ERROR             = 4'd15;

    // ============================================================
    // Buffer index
    // 0 = buffer0
    // 1 = buffer1
    // ============================================================
    reg write_buf;
    reg read_buf;

    // ============================================================
    // Done edge detection
    // ============================================================
    reg axi_write_done_d;
    reg axi_read_done_d;

    wire axi_write_done_pulse;
    wire axi_read_done_pulse;

    assign axi_write_done_pulse = axi_write_done & ~axi_write_done_d;
    assign axi_read_done_pulse  = axi_read_done  & ~axi_read_done_d;

    // ============================================================
    // Wait flags for ping-pong operation
    // ============================================================
    reg write_done_seen;
    reg read_done_seen;

    // ============================================================
    // AXI enable
    // ============================================================
    assign axi_write_enable =
        enable &&
        init_calib_complete &&
        !debug_error_latched;

    assign axi_read_enable =
        enable &&
        init_calib_complete &&
        debug_first_frame_valid &&
        !debug_error_latched;

    // ============================================================
    // Buffer base address function
    // ============================================================
    function [ADDR_WIDTH-1:0] buffer_base_addr;
        input buffer_index;
        begin
            if (buffer_index == 1'b0)
                buffer_base_addr = BUFFER0_BASE_ADDR;
            else
                buffer_base_addr = BUFFER1_BASE_ADDR;
        end
    endfunction

    // ============================================================
    // Main FSM
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            debug_state                 <= S_IDLE;

            write_buf                   <= 1'b0;
            read_buf                    <= 1'b0;

            axi_write_frame_start       <= 1'b0;
            axi_read_frame_start        <= 1'b0;

            axi_write_frame_base_addr   <= BUFFER0_BASE_ADDR;
            axi_read_frame_base_addr    <= BUFFER0_BASE_ADDR;

            axi_write_done_d            <= 1'b0;
            axi_read_done_d             <= 1'b0;

            write_done_seen             <= 1'b0;
            read_done_seen              <= 1'b0;

            debug_write_buffer_index    <= 1'b0;
            debug_read_buffer_index     <= 1'b0;
            debug_first_frame_valid     <= 1'b0;
            debug_error_latched         <= 1'b0;
            debug_write_frame_count     <= 32'd0;
            debug_read_frame_count      <= 32'd0;
        end else begin
            // Default: frame_start hanya pulse 1 clock
            axi_write_frame_start <= 1'b0;
            axi_read_frame_start  <= 1'b0;

            // Register previous done
            axi_write_done_d <= axi_write_done;
            axi_read_done_d  <= axi_read_done;

            // Kalau enable/calibration belum siap, tahan di IDLE
            if (!enable || !init_calib_complete) begin
                debug_state                 <= S_IDLE;

                write_buf                   <= 1'b0;
                read_buf                    <= 1'b0;

                axi_write_frame_base_addr   <= BUFFER0_BASE_ADDR;
                axi_read_frame_base_addr    <= BUFFER0_BASE_ADDR;

                write_done_seen             <= 1'b0;
                read_done_seen              <= 1'b0;

                debug_write_buffer_index    <= 1'b0;
                debug_read_buffer_index     <= 1'b0;
                debug_first_frame_valid     <= 1'b0;
                debug_error_latched         <= 1'b0;
            end else begin

                // Error latch
                if (axi_write_error || axi_read_error) begin
                    debug_error_latched <= 1'b1;
                    debug_state         <= S_ERROR;
                end else begin
                    case (debug_state)

                        // ====================================================
                        // IDLE
                        // ====================================================
                        S_IDLE: begin
                            write_buf                <= 1'b0;
                            read_buf                 <= 1'b0;

                            debug_write_buffer_index <= 1'b0;
                            debug_read_buffer_index  <= 1'b0;

                            write_done_seen          <= 1'b0;
                            read_done_seen           <= 1'b0;

                            axi_write_frame_base_addr <= BUFFER0_BASE_ADDR;
                            axi_read_frame_base_addr  <= BUFFER0_BASE_ADDR;

                            debug_state <= S_START_FIRST_WRITE;
                        end

                        // ====================================================
                        // Start first write to buffer 0
                        // ====================================================
                        S_START_FIRST_WRITE: begin
                            axi_write_frame_base_addr <= buffer_base_addr(write_buf);

                            if (!axi_write_busy && write_start_allowed) begin
                                axi_write_frame_start <= 1'b1;
                                debug_state           <= S_WAIT_FIRST_WRITE;
                            end
                        end

                        // ====================================================
                        // Wait until first frame written
                        // ====================================================
                        S_WAIT_FIRST_WRITE: begin
                            if (axi_write_done_pulse) begin
                                debug_write_frame_count <= debug_write_frame_count + 32'd1;

                                // First valid frame now exists in write_buf
                                debug_first_frame_valid <= 1'b1;

                                // Read the buffer that was just written
                                read_buf <= write_buf;

                                // Write next frame to the other buffer
                                write_buf <= ~write_buf;

                                write_done_seen <= 1'b0;
                                read_done_seen  <= 1'b0;

                                debug_state <= S_START_BOTH;
                            end
                        end

                        // ====================================================
                        // Start write and read together
                        // ====================================================
                        S_START_BOTH: begin
                            axi_write_frame_base_addr <= buffer_base_addr(write_buf);
                            axi_read_frame_base_addr  <= buffer_base_addr(read_buf);

                            debug_write_buffer_index  <= write_buf;
                            debug_read_buffer_index   <= read_buf;

                            if (!axi_write_busy &&
                                !axi_read_busy  &&
                                write_start_allowed &&
                                read_start_allowed) begin

                                axi_write_frame_start <= 1'b1;
                                axi_read_frame_start  <= 1'b1;

                                write_done_seen <= 1'b0;
                                read_done_seen  <= 1'b0;

                                debug_state <= S_WAIT_BOTH;
                            end
                        end

                        // ====================================================
                        // Wait until both write and read frame complete
                        // ====================================================
                        S_WAIT_BOTH: begin
                            if (axi_write_done_pulse) begin
                                write_done_seen <= 1'b1;
                                debug_write_frame_count <= debug_write_frame_count + 32'd1;
                            end

                            if (axi_read_done_pulse) begin
                                read_done_seen <= 1'b1;
                                debug_read_frame_count <= debug_read_frame_count + 32'd1;
                            end

                            // Kalau write dan read sudah selesai, swap buffer
                            if ((write_done_seen || axi_write_done_pulse) &&
                                (read_done_seen  || axi_read_done_pulse)) begin

                                // Buffer yang baru selesai ditulis menjadi buffer baca berikutnya.
                                // Buffer yang baru selesai dibaca menjadi buffer tulis berikutnya.
                                read_buf  <= write_buf;
                                write_buf <= read_buf;

                                write_done_seen <= 1'b0;
                                read_done_seen  <= 1'b0;

                                debug_state <= S_START_BOTH;
                            end
                        end

                        // ====================================================
                        // ERROR
                        // ====================================================
                        S_ERROR: begin
                            axi_write_frame_start <= 1'b0;
                            axi_read_frame_start  <= 1'b0;
                            debug_error_latched   <= 1'b1;
                            debug_state           <= S_ERROR;
                        end

                        default: begin
                            debug_state <= S_IDLE;
                        end

                    endcase
                end
            end
        end
    end

endmodule