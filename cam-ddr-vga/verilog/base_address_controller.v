`timescale 1ns / 1ps

module base_address_controller #(
    parameter ADDR_WIDTH = 32,

    parameter [ADDR_WIDTH-1:0] BUFFER0_BASE_ADDR = 32'h8000_0000,
    parameter [ADDR_WIDTH-1:0] BUFFER1_BASE_ADDR = 32'h8010_0000,

    parameter [31:0] FRAME_BYTES = 32'd614400
)(
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   enable,
    input  wire                   init_calib_complete,

    // PENTING:
    // write_start_allowed = pulse 1 clock ui_clk dari awal frame kamera
    // read_start_allowed  = pulse 1 clock ui_clk dari awal frame VGA / vblank
    input  wire                   write_start_allowed,
    input  wire                   read_start_allowed,

    input  wire                   axi_write_busy,
    input  wire                   axi_write_done,
    input  wire                   axi_write_error,

    input  wire                   axi_read_busy,
    input  wire                   axi_read_done,
    input  wire                   axi_read_error,

    output wire                   axi_write_enable,
    output reg                    axi_write_frame_start,
    output reg  [ADDR_WIDTH-1:0]  axi_write_frame_base_addr,

    output wire                   axi_read_enable,
    output reg                    axi_read_frame_start,
    output reg  [ADDR_WIDTH-1:0]  axi_read_frame_base_addr,

    output reg  [3:0]             debug_state,
    output reg                    debug_write_buffer_index,
    output reg                    debug_read_buffer_index,
    output reg                    debug_first_frame_valid,
    output reg                    debug_error_latched,
    output reg  [31:0]            debug_write_frame_count,
    output reg  [31:0]            debug_read_frame_count
);

    localparam S_IDLE  = 4'd0;
    localparam S_RUN   = 4'd1;
    localparam S_ERROR = 4'd15;

    // 0 = buffer0, 1 = buffer1
    reg write_buf;
    reg read_buf;

    // Buffer yang sudah selesai ditulis, tapi belum boleh ditampilkan
    reg pending_swap;
    reg pending_buf;

    reg axi_write_done_d;
    reg axi_read_done_d;

    wire axi_write_done_pulse;
    wire axi_read_done_pulse;

    assign axi_write_done_pulse = axi_write_done & ~axi_write_done_d;
    assign axi_read_done_pulse  = axi_read_done  & ~axi_read_done_d;

    assign axi_write_enable =
        enable &&
        init_calib_complete &&
        !debug_error_latched;

    assign axi_read_enable =
        enable &&
        init_calib_complete &&
        debug_first_frame_valid &&
        !debug_error_latched;

    function [ADDR_WIDTH-1:0] buffer_base_addr;
        input buffer_index;
        begin
            if (buffer_index == 1'b0)
                buffer_base_addr = BUFFER0_BASE_ADDR;
            else
                buffer_base_addr = BUFFER1_BASE_ADDR;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            debug_state               <= S_IDLE;

            write_buf                 <= 1'b0;
            read_buf                  <= 1'b0;

            pending_swap              <= 1'b0;
            pending_buf               <= 1'b0;

            axi_write_frame_start     <= 1'b0;
            axi_read_frame_start      <= 1'b0;

            axi_write_frame_base_addr <= BUFFER0_BASE_ADDR;
            axi_read_frame_base_addr  <= BUFFER0_BASE_ADDR;

            axi_write_done_d          <= 1'b0;
            axi_read_done_d           <= 1'b0;

            debug_write_buffer_index  <= 1'b0;
            debug_read_buffer_index   <= 1'b0;
            debug_first_frame_valid   <= 1'b0;
            debug_error_latched       <= 1'b0;
            debug_write_frame_count   <= 32'd0;
            debug_read_frame_count    <= 32'd0;
        end else begin
            axi_write_frame_start <= 1'b0;
            axi_read_frame_start  <= 1'b0;

            axi_write_done_d <= axi_write_done;
            axi_read_done_d  <= axi_read_done;

            if (!enable || !init_calib_complete) begin
                debug_state               <= S_IDLE;

                write_buf                 <= 1'b0;
                read_buf                  <= 1'b0;

                pending_swap              <= 1'b0;
                pending_buf               <= 1'b0;

                axi_write_frame_base_addr <= BUFFER0_BASE_ADDR;
                axi_read_frame_base_addr  <= BUFFER0_BASE_ADDR;

                debug_write_buffer_index  <= 1'b0;
                debug_read_buffer_index   <= 1'b0;
                debug_first_frame_valid   <= 1'b0;
                debug_error_latched       <= 1'b0;
            end else begin
                if (axi_write_error || axi_read_error) begin
                    debug_error_latched <= 1'b1;
                    debug_state         <= S_ERROR;
                end else begin
                    case (debug_state)

                        S_IDLE: begin
                            write_buf                 <= 1'b0;
                            read_buf                  <= 1'b0;

                            pending_swap              <= 1'b0;
                            pending_buf               <= 1'b0;

                            axi_write_frame_base_addr <= BUFFER0_BASE_ADDR;
                            axi_read_frame_base_addr  <= BUFFER0_BASE_ADDR;

                            debug_write_buffer_index  <= 1'b0;
                            debug_read_buffer_index   <= 1'b0;
                            debug_first_frame_valid   <= 1'b0;

                            debug_state <= S_RUN;
                        end

                        S_RUN: begin
                            // =================================================
                            // WRITE SIDE
                            // Start write hanya saat awal frame kamera.
                            // Kalau pending_swap masih 1, berarti frame baru
                            // belum sempat diambil oleh VGA, jadi jangan overwrite.
                            // =================================================
                            if (write_start_allowed &&
                                !axi_write_busy &&
                                !pending_swap) begin

                                axi_write_frame_base_addr <= buffer_base_addr(write_buf);
                                axi_write_frame_start     <= 1'b1;
                            end

                            // Write selesai:
                            // frame baru sudah siap, tapi BELUM swap.
                            // Swap harus menunggu awal frame VGA.
                            if (axi_write_done_pulse) begin
                                pending_swap            <= 1'b1;
                                pending_buf             <= write_buf;
                                debug_first_frame_valid <= 1'b1;
                                debug_write_frame_count <= debug_write_frame_count + 32'd1;
                            end

                            // =================================================
                            // READ SIDE
                            // Start read hanya saat awal frame VGA.
                            // Di sinilah waktu aman untuk ganti frame.
                            // =================================================
                            if (read_start_allowed &&
                                !axi_read_busy &&
                                debug_first_frame_valid) begin

                                if (pending_swap) begin
                                    // Ambil buffer yang baru selesai ditulis
                                    read_buf <= pending_buf;

                                    axi_read_frame_base_addr <= buffer_base_addr(pending_buf);
                                    axi_read_frame_start     <= 1'b1;

                                    // Setelah buffer pending dipakai untuk read,
                                    // buffer satunya menjadi target write berikutnya.
                                    write_buf <= ~pending_buf;

                                    pending_swap <= 1'b0;
                                end else begin
                                    // Tidak ada frame baru.
                                    // Ulangi frame lama supaya VGA tetap stabil.
                                    axi_read_frame_base_addr <= buffer_base_addr(read_buf);
                                    axi_read_frame_start     <= 1'b1;
                                end
                            end

                            if (axi_read_done_pulse) begin
                                debug_read_frame_count <= debug_read_frame_count + 32'd1;
                            end

                            debug_write_buffer_index <= write_buf;
                            debug_read_buffer_index  <= read_buf;
                        end

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