`timescale 1ns / 1ps
`default_nettype none

module double_buffer_28x28 #(
    parameter FRAME_WIDTH  = 640,
    parameter FRAME_HEIGHT = 480,

    parameter ROI_WIDTH    = 280,
    parameter ROI_HEIGHT   = 280,

    parameter OUT_W        = 28,
    parameter OUT_H        = 28,

    parameter SCALE        = 10,

    parameter X_BITS       = 10,
    parameter Y_BITS       = 10
)(
    input  wire        clk,
    input  wire        rst,

    // ============================================================
    // WRITE SIDE: pixel stream dari kamera / VGA timing domain
    // ============================================================
    input  wire        pixel_valid,
    input  wire [15:0] pixel_rgb565,
    input  wire [X_BITS-1:0] pixel_x,
    input  wire [Y_BITS-1:0] pixel_y,

    output reg         done_write,
    output reg         dropped_frame,
    output wire        active_roi,
    output wire        write_busy,

    // ============================================================
    // READ SIDE: stream 28x28 menuju CNN
    // ============================================================
    input  wire        start_read,
    input  wire        read_ready,
    input  wire        done_process_read,

    output wire        read_valid,
    output wire [7:0]  read_pixel,
    output reg  [4:0]  read_x,
    output reg  [4:0]  read_y,
    output wire        read_frame_sent,

    // ============================================================
    // STATUS / DEBUG
    // ============================================================
    output wire        frame_available,
    output wire        buffer_full,
    output wire [1:0]  buffer_status,
    output wire        debug_write_buf,
    output wire        debug_read_buf
);

    localparam integer OUT_PIXELS = OUT_W * OUT_H;

    localparam integer ROI_X0 = (FRAME_WIDTH  - ROI_WIDTH)  / 2;
    localparam integer ROI_Y0 = (FRAME_HEIGHT - ROI_HEIGHT) / 2;

    localparam integer ROI_X1 = ROI_X0 + ROI_WIDTH  - 1;
    localparam integer ROI_Y1 = ROI_Y0 + ROI_HEIGHT - 1;

    localparam [X_BITS-1:0] ROI_X0_C = ROI_X0;
    localparam [X_BITS-1:0] ROI_X1_C = ROI_X1;
    localparam [Y_BITS-1:0] ROI_Y0_C = ROI_Y0;
    localparam [Y_BITS-1:0] ROI_Y1_C = ROI_Y1;

    // ============================================================
    // BUFFER MEMORY
    // 2 buffer, masing-masing 28x28 grayscale 8-bit
    // ============================================================

    (* ram_style = "distributed" *) reg [7:0] buffer0 [0:OUT_PIXELS-1];
    (* ram_style = "distributed" *) reg [7:0] buffer1 [0:OUT_PIXELS-1];

    reg [1:0] buf_ready;

    reg       write_buf;
    reg       read_buf;

    reg       write_active;
    reg       read_busy_reg;
    reg       read_stream_done;

    reg [9:0] read_addr;

    assign debug_write_buf = write_buf;
    assign debug_read_buf  = read_buf;
    assign buffer_status   = buf_ready;
    assign write_busy      = write_active;

    // ============================================================
    // BUFFER AVAILABILITY
    // ============================================================

    wire buf0_locked_read = read_busy_reg && (read_buf == 1'b0);
    wire buf1_locked_read = read_busy_reg && (read_buf == 1'b1);

    wire buf0_available_for_read = buf_ready[0] && !buf0_locked_read;
    wire buf1_available_for_read = buf_ready[1] && !buf1_locked_read;

    assign frame_available = buf0_available_for_read | buf1_available_for_read;

    wire buf0_free_for_write = !buf_ready[0] && !buf0_locked_read;
    wire buf1_free_for_write = !buf_ready[1] && !buf1_locked_read;

    wire current_write_free =
        (write_buf == 1'b0) ? buf0_free_for_write : buf1_free_for_write;

    wire other_write_free =
        (write_buf == 1'b0) ? buf1_free_for_write : buf0_free_for_write;

    assign buffer_full = !buf0_free_for_write && !buf1_free_for_write;

    // ============================================================
    // ROI DETECTION
    // Optimasi: tidak memakai pembagian, modulo, atau perkalian alamat.
    // out_x/out_y/sub_x/sub_y diganti counter incremental.
    // ============================================================

    wire x_in_roi = (pixel_x >= ROI_X0_C) && (pixel_x <= ROI_X1_C);
    wire y_in_roi = (pixel_y >= ROI_Y0_C) && (pixel_y <= ROI_Y1_C);

    assign active_roi = pixel_valid && x_in_roi && y_in_roi;

    wire new_frame =
        pixel_valid &&
        (pixel_x == {X_BITS{1'b0}}) &&
        (pixel_y == {Y_BITS{1'b0}});

    wire roi_line_end =
        pixel_valid &&
        (pixel_x == ROI_X1_C) &&
        y_in_roi;

    wire [5:0] green6 = pixel_rgb565[10:5];
    wire [7:0] gray8  = {green6, green6[5:4]};

    // ============================================================
    // ACCUMULATOR 10x10
    // row_sum[col] mengumpulkan 10x10 pixel untuk kolom output tertentu.
    // ============================================================

    reg [15:0] row_sum [0:OUT_W-1];

    reg [4:0] wr_out_x;
    reg [4:0] wr_out_y;
    reg [3:0] wr_sub_x;
    reg [3:0] wr_sub_y;
    reg [9:0] wr_addr;

    wire write_pixel_fire = active_roi && write_active;

    wire cell_done_now =
        write_pixel_fire &&
        (wr_sub_x == SCALE-1) &&
        (wr_sub_y == SCALE-1);

    wire last_cell_now = cell_done_now && (wr_addr == OUT_PIXELS-1);

    wire [15:0] sum_with_current = row_sum[wr_out_x] + {8'd0, gray8};

    // ============================================================
    // Fast exact divide-by-100 untuk range 0..25500:
    // round(value / 100) = floor((value + 50) / 100)
    //                    = ((value + 50) * 5243) >> 19
    // Formula ini exact untuk range accumulator 10x10.
    // Lebih timing-friendly daripada operator '/' langsung di jalur critical.
    // ============================================================

    function [7:0] div100_fast_round;
        input [15:0] value;
        reg   [31:0] product;
        begin
            product = ({16'd0, value} + 32'd50) * 32'd5243;
            div100_fast_round = product[26:19];
        end
    endfunction

    // Pipeline untuk memutus jalur:
    // row_sum -> sum -> div100 -> buffer write
    reg        avg_s1_valid;
    reg [15:0] avg_s1_sum;
    reg [9:0]  avg_s1_addr;
    reg        avg_s1_buf;
    reg        avg_s1_last;

    reg        avg_s2_valid;
    reg [7:0]  avg_s2_pixel;
    reg [9:0]  avg_s2_addr;
    reg        avg_s2_buf;
    reg        avg_s2_last;

    // Clear row_sum satu per satu saat frame baru.
    // Ini menghindari fanout dan mux besar dari for-loop clear pada new_frame.
    reg        clear_active;
    reg [4:0]  clear_idx;

    integer i;

    // ============================================================
    // WRITE LOGIC
    // ============================================================

    always @(posedge clk) begin
        if (rst) begin
            write_buf     <= 1'b0;
            write_active  <= 1'b0;
            done_write    <= 1'b0;
            dropped_frame <= 1'b0;
            buf_ready     <= 2'b00;

            wr_out_x <= 5'd0;
            wr_out_y <= 5'd0;
            wr_sub_x <= 4'd0;
            wr_sub_y <= 4'd0;
            wr_addr  <= 10'd0;

            avg_s1_valid <= 1'b0;
            avg_s1_sum   <= 16'd0;
            avg_s1_addr  <= 10'd0;
            avg_s1_buf   <= 1'b0;
            avg_s1_last  <= 1'b0;

            avg_s2_valid <= 1'b0;
            avg_s2_pixel <= 8'd0;
            avg_s2_addr  <= 10'd0;
            avg_s2_buf   <= 1'b0;
            avg_s2_last  <= 1'b0;

            clear_active <= 1'b0;
            clear_idx    <= 5'd0;

            for (i = 0; i < OUT_W; i = i + 1) begin
                row_sum[i] <= 16'd0;
            end
        end else begin
            done_write    <= 1'b0;
            dropped_frame <= 1'b0;

            // Default pipeline valid bergeser setiap clock.
            avg_s1_valid <= 1'b0;

            avg_s2_valid <= avg_s1_valid;
            avg_s2_pixel <= div100_fast_round(avg_s1_sum);
            avg_s2_addr  <= avg_s1_addr;
            avg_s2_buf   <= avg_s1_buf;
            avg_s2_last  <= avg_s1_last;

            // Tulis hasil average ke buffer satu cycle setelah cell_done.
            if (avg_s2_valid) begin
                if (avg_s2_buf == 1'b0) begin
                    buffer0[avg_s2_addr] <= avg_s2_pixel;
                end else begin
                    buffer1[avg_s2_addr] <= avg_s2_pixel;
                end

                if (avg_s2_last) begin
                    buf_ready[avg_s2_buf] <= 1'b1;
                    done_write            <= 1'b1;
                    write_active          <= 1'b0;
                end
            end

            // Buffer read baru dilepas kalau CNN sudah selesai proses.
            if (done_process_read && read_busy_reg && read_stream_done) begin
                buf_ready[read_buf] <= 1'b0;
            end

            // Start frame baru dan pilih buffer kosong.
            if (new_frame) begin
                wr_out_x <= 5'd0;
                wr_out_y <= 5'd0;
                wr_sub_x <= 4'd0;
                wr_sub_y <= 4'd0;
                wr_addr  <= 10'd0;

                clear_active <= 1'b1;
                clear_idx    <= 5'd0;

                if (current_write_free) begin
                    write_active <= 1'b1;
                end else if (other_write_free) begin
                    write_buf    <= ~write_buf;
                    write_active <= 1'b1;
                end else begin
                    write_active  <= 1'b0;
                    dropped_frame <= 1'b1;
                end
            end

            // Clear row_sum bertahap. Untuk ROI tengah 280x280, ada ribuan clock
            // sebelum ROI dimulai, jadi 28-cycle clear ini aman.
            if (clear_active) begin
                row_sum[clear_idx] <= 16'd0;

                if (clear_idx == OUT_W-1) begin
                    clear_active <= 1'b0;
                end else begin
                    clear_idx <= clear_idx + 5'd1;
                end
            end

            // Proses resize hanya dilakukan pada ROI dan setelah clear selesai.
            if (write_pixel_fire && !clear_active) begin
                if (cell_done_now) begin
                    // Capture hasil sum. Average dan write buffer dipipeline.
                    avg_s1_valid <= 1'b1;
                    avg_s1_sum   <= sum_with_current;
                    avg_s1_addr  <= wr_addr;
                    avg_s1_buf   <= write_buf;
                    avg_s1_last  <= last_cell_now;

                    // Setelah satu blok 10x10 selesai, accumulator kolom itu dikosongkan.
                    row_sum[wr_out_x] <= 16'd0;

                    if (!last_cell_now) begin
                        wr_addr <= wr_addr + 10'd1;
                    end
                end else begin
                    row_sum[wr_out_x] <= sum_with_current;
                end

                // Update counter mapping ROI -> 28x28.
                // Counter ini menggantikan roi_x/SCALE, roi_y/SCALE, %, dan out_y*OUT_W.
                if (roi_line_end) begin
                    wr_sub_x <= 4'd0;
                    wr_out_x <= 5'd0;

                    if (wr_sub_y == SCALE-1) begin
                        wr_sub_y <= 4'd0;
                        if (wr_out_y == OUT_H-1) begin
                            wr_out_y <= 5'd0;
                        end else begin
                            wr_out_y <= wr_out_y + 5'd1;
                        end
                    end else begin
                        wr_sub_y <= wr_sub_y + 4'd1;
                    end
                end else begin
                    if (wr_sub_x == SCALE-1) begin
                        wr_sub_x <= 4'd0;
                        wr_out_x <= wr_out_x + 5'd1;
                    end else begin
                        wr_sub_x <= wr_sub_x + 4'd1;
                    end
                end
            end
        end
    end

    // ============================================================
    // READ LOGIC
    // CNN membaca isi buffer 28x28 sebagai stream 784 pixel.
    // Buffer tidak dilepas hanya karena 784 pixel sudah terkirim.
    // Buffer dilepas setelah done_process_read.
    // ============================================================

    assign read_valid      = read_busy_reg && !read_stream_done;
    assign read_frame_sent = read_stream_done;

    assign read_pixel =
        (read_buf == 1'b0) ? buffer0[read_addr] :
                             buffer1[read_addr];

    always @(posedge clk) begin
        if (rst) begin
            read_buf         <= 1'b0;
            read_busy_reg    <= 1'b0;
            read_stream_done <= 1'b0;
            read_addr        <= 10'd0;
            read_x           <= 5'd0;
            read_y           <= 5'd0;
        end else begin
            // Start baca frame ketika CNN siap mengambil frame baru.
            if (start_read && !read_busy_reg) begin
                if (buf0_available_for_read) begin
                    read_buf         <= 1'b0;
                    read_busy_reg    <= 1'b1;
                    read_stream_done <= 1'b0;
                    read_addr        <= 10'd0;
                    read_x           <= 5'd0;
                    read_y           <= 5'd0;
                end else if (buf1_available_for_read) begin
                    read_buf         <= 1'b1;
                    read_busy_reg    <= 1'b1;
                    read_stream_done <= 1'b0;
                    read_addr        <= 10'd0;
                    read_x           <= 5'd0;
                    read_y           <= 5'd0;
                end
            end

            // Stream pixel 28x28 keluar ke CNN.
            if (read_valid && read_ready) begin
                if (read_addr == OUT_PIXELS-1) begin
                    read_stream_done <= 1'b1;
                end else begin
                    read_addr <= read_addr + 10'd1;

                    if (read_x == OUT_W-1) begin
                        read_x <= 5'd0;
                        read_y <= read_y + 5'd1;
                    end else begin
                        read_x <= read_x + 5'd1;
                    end
                end
            end

            // CNN memberi tanda bahwa frame sudah benar-benar selesai diproses.
            if (done_process_read && read_busy_reg && read_stream_done) begin
                read_busy_reg    <= 1'b0;
                read_stream_done <= 1'b0;
                read_addr        <= 10'd0;
                read_x           <= 5'd0;
                read_y           <= 5'd0;
            end
        end
    end

endmodule

`default_nettype wire