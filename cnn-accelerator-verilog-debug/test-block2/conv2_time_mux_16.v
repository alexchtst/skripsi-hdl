`timescale 1ns / 1ps

module conv2_time_mux_16 #(
    parameter IN_CHANNELS  = 8,
    parameter KERNEL_SIZE  = 9,
    parameter DATA_SIZE    = 32,
    parameter ACT_SIZE     = 18,  // ganti ke 18 kalau ingin input multiplier lebih kecil
    parameter WEIGHT_SIZE  = 16,
    parameter OUT_WIDTH    = 32,
    parameter OUT_CHANNELS = 16,
    parameter ACT_SHIFT    = 0
)(
    input wire clk,
    input wire rst,

    // input dari block2_fifo_shift_register_kernel
    input wire valid_in,
    output wire ready_out,
    input wire [IN_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] din,

    // ready dari block setelah conv2_time_mux_16, misalnya pool block2
    input wire ready_in,

    // output 16 channel lengkap untuk 1 posisi spasial conv2
    // ch0 di bit [0 +: OUT_WIDTH], ch1 di bit [OUT_WIDTH +: OUT_WIDTH], dst.
    output reg valid_out,
    output reg [OUT_CHANNELS*OUT_WIDTH-1:0] dout,

    // debug optional
    output wire busy,
    output reg [4:0] launch_channel,
    output reg [4:0] collected_channel
);

    localparam S_IDLE  = 2'd0;
    localparam S_RUN   = 2'd1;
    localparam S_DRAIN = 2'd2;

    reg [1:0] state;

    reg [IN_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] window_reg;

    wire output_can_advance;
    assign output_can_advance = (!valid_out) || ready_in;

    assign ready_out = (state == S_IDLE) && output_can_advance;
    assign busy      = (state != S_IDLE) || valid_out;

    wire fire_in;
    assign fire_in = valid_in && ready_out;

    // =========================================================
    // conv2_partial memakai 72 DSP untuk 1 output-channel.
    // Module ini menjalankan channel_idx 0..15 secara time-multiplex.
    // =========================================================
    wire partial_ready_out;
    wire partial_ready_in;
    wire partial_valid_in;
    wire partial_valid_out;
    wire [OUT_WIDTH-1:0] partial_dout;

    assign partial_ready_in = output_can_advance;

    assign partial_valid_in =
        output_can_advance &&
        (state == S_RUN) &&
        (launch_channel < OUT_CHANNELS);

    conv2_partial #(
        .IN_CHANNELS(IN_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .DATA_SIZE(DATA_SIZE),
        .ACT_SIZE(ACT_SIZE),
        .WEIGHT_SIZE(WEIGHT_SIZE),
        .OUT_WIDTH(OUT_WIDTH),
        .ACT_SHIFT(ACT_SHIFT)
    ) u_conv2_partial (
        .clk(clk),
        .rst(rst),

        .valid_in(partial_valid_in),
        .ready_out(partial_ready_out),
        .ready_in(partial_ready_in),

        .channel_idx(launch_channel),
        .din(window_reg),

        .dout(partial_dout),
        .valid_out(partial_valid_out)
    );

    always @(posedge clk) begin
        if (rst) begin
            state             <= S_IDLE;
            window_reg        <= {(IN_CHANNELS*KERNEL_SIZE*DATA_SIZE){1'b0}};
            valid_out         <= 1'b0;
            dout              <= {(OUT_CHANNELS*OUT_WIDTH){1'b0}};
            launch_channel    <= 5'd0;
            collected_channel <= 5'd0;
        end

        else begin
            // Jika output vector sudah diterima downstream, kosongkan valid_out.
            if (valid_out && ready_in) begin
                valid_out <= 1'b0;
            end

            if (output_can_advance) begin

                // =================================================
                // Terima window baru dari block2 kernel
                // =================================================
                if (state == S_IDLE) begin
                    if (fire_in) begin
                        window_reg        <= din;
                        launch_channel    <= 5'd0;
                        collected_channel <= 5'd0;
                        state             <= S_RUN;
                    end
                end

                // =================================================
                // Launch 16 output-channel: 0..15
                // Setiap cycle mengirim window yang sama ke conv2_partial,
                // hanya channel_idx yang berubah.
                // =================================================
                else if (state == S_RUN) begin
                    if (launch_channel == OUT_CHANNELS-1) begin
                        launch_channel <= launch_channel + 1'b1;
                        state          <= S_DRAIN;
                    end
                    else begin
                        launch_channel <= launch_channel + 1'b1;
                    end
                end

                // =================================================
                // S_DRAIN: semua channel sudah di-launch,
                // tinggal menunggu output pipeline conv2_partial selesai.
                // =================================================
                else if (state == S_DRAIN) begin
                    state <= S_DRAIN;
                end

                // =================================================
                // Collect output conv2_partial.
                // Output keluar berurutan: ch0, ch1, ..., ch15.
                // =================================================
                if (partial_valid_out) begin
                    dout[collected_channel*OUT_WIDTH +: OUT_WIDTH] <= partial_dout;

                    if (collected_channel == OUT_CHANNELS-1) begin
                        valid_out         <= 1'b1;
                        state             <= S_IDLE;
                        collected_channel <= 5'd0;
                        launch_channel    <= 5'd0;
                    end
                    else begin
                        collected_channel <= collected_channel + 1'b1;
                    end
                end
            end

            // Jika output_can_advance = 0:
            // output vector sedang valid tapi downstream belum ready.
            // state, counter, window_reg, dan conv2_partial ditahan.
        end
    end

endmodule