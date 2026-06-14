`timescale 1ns / 1ps

module conv3_time_mux_32 #(
    parameter TOTAL_IN_CHANNELS = 16,
    parameter GROUP_CHANNELS    = 8,
    parameter KERNEL_SIZE       = 9,
    parameter DATA_SIZE         = 32,
    parameter ACT_SIZE          = 24,
    parameter WEIGHT_SIZE       = 16,
    parameter PARTIAL_WIDTH     = 48,
    parameter OUT_WIDTH         = 32,
    parameter OUT_CHANNELS      = 32,
    parameter ACT_SHIFT         = 0,
    parameter FRAC_BITS         = 14
)(
    input wire clk,
    input wire rst,

    input wire valid_in,
    output wire ready_out,
    input wire [TOTAL_IN_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] din,

    input wire ready_in,

    output reg valid_out,
    output reg [OUT_CHANNELS*OUT_WIDTH-1:0] dout,

    output wire busy,
    output reg [5:0] launch_step,
    output reg [5:0] collect_step
);

    localparam S_IDLE  = 2'd0;
    localparam S_RUN   = 2'd1;
    localparam S_DRAIN = 2'd2;

    // 32 output channel x 2 groups: group0=input ch0..7, group1=input ch8..15
    localparam LAUNCH_TOTAL = OUT_CHANNELS * 2;

    reg [1:0] state;

    reg [TOTAL_IN_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] window_reg;

    wire output_can_advance;
    assign output_can_advance = (!valid_out) || ready_in;

    assign ready_out = (state == S_IDLE) && output_can_advance;
    assign busy      = (state != S_IDLE) || valid_out;

    wire fire_in;
    assign fire_in = valid_in && ready_out;

    wire partial_valid_in;
    wire partial_ready_out;
    wire partial_ready_in;
    wire partial_valid_out;
    wire signed [PARTIAL_WIDTH-1:0] partial_dout;

    assign partial_ready_in = output_can_advance;

    assign partial_valid_in =
        output_can_advance &&
        (state == S_RUN) &&
        (launch_step < LAUNCH_TOTAL);

    wire [4:0] launch_out_channel;
    wire launch_group;

    assign launch_out_channel = launch_step[5:1];
    assign launch_group       = launch_step[0];

    reg [GROUP_CHANNELS*KERNEL_SIZE*DATA_SIZE-1:0] partial_din;

    integer ch, tap;
    always @(*) begin
        partial_din = 0;
        for (ch = 0; ch < GROUP_CHANNELS; ch = ch + 1) begin
            for (tap = 0; tap < KERNEL_SIZE; tap = tap + 1) begin
                partial_din[(ch*KERNEL_SIZE + tap)*DATA_SIZE +: DATA_SIZE] =
                    window_reg[((launch_group*GROUP_CHANNELS + ch)*KERNEL_SIZE + tap)*DATA_SIZE +: DATA_SIZE];
            end
        end
    end

    conv3_partial_8ch #(
        .IN_CHANNELS(GROUP_CHANNELS),
        .TOTAL_IN_CHANNELS(TOTAL_IN_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .DATA_SIZE(DATA_SIZE),
        .ACT_SIZE(ACT_SIZE),
        .WEIGHT_SIZE(WEIGHT_SIZE),
        .OUT_WIDTH(PARTIAL_WIDTH),
        .ACT_SHIFT(ACT_SHIFT),
        .OUT_CHANNELS(OUT_CHANNELS)
    ) u_conv3_partial_8ch (
        .clk(clk),
        .rst(rst),

        .valid_in(partial_valid_in),
        .ready_out(partial_ready_out),
        .ready_in(partial_ready_in),

        .out_channel_idx(launch_out_channel),
        .group_idx(launch_group),

        .din(partial_din),

        .dout(partial_dout),
        .valid_out(partial_valid_out)
    );

    // group0 partial untuk output channel yang sedang dikumpulkan.
    // Ini masih signed Q28 jika input activation Q14 dan weight Q14.
    reg signed [PARTIAL_WIDTH-1:0] partial_sum_group0;

    wire [4:0] collect_out_channel;
    wire collect_group;

    assign collect_out_channel = collect_step[5:1];
    assign collect_group       = collect_step[0];

    // Bias conv3 disimpan sebagai signed Q14.
    reg signed [WEIGHT_SIZE-1:0] B [0:OUT_CHANNELS-1];

    initial begin
        $readmemh("conv3_b.mem", B);
    end

    // =========================================================
    // Fixed-point scaling yang benar untuk conv3:
    // partial_sum_group0 : Q28
    // partial_dout       : Q28
    // B                  : Q14
    // bias_q28           : B <<< 14
    // final_q28          : partial0 + partial1 + bias_q28
    // final_q14          : final_q28 >>> 14
    // ReLU/saturasi      : dilakukan setelah final_q14
    // =========================================================
    wire signed [PARTIAL_WIDTH:0] partial0_ext;
    wire signed [PARTIAL_WIDTH:0] partial1_ext;
    wire signed [PARTIAL_WIDTH:0] bias_q28;
    wire signed [PARTIAL_WIDTH:0] final_q28;
    wire signed [PARTIAL_WIDTH:0] final_q14;

    assign partial0_ext = {partial_sum_group0[PARTIAL_WIDTH-1], partial_sum_group0};
    assign partial1_ext = {partial_dout[PARTIAL_WIDTH-1], partial_dout};

    assign bias_q28 =
        ({{(PARTIAL_WIDTH+1-WEIGHT_SIZE){B[collect_out_channel][WEIGHT_SIZE-1]}}, B[collect_out_channel]})
        <<< FRAC_BITS;

    assign final_q28 = partial0_ext + partial1_ext + bias_q28;
    assign final_q14 = final_q28 >>> FRAC_BITS;

    localparam signed [PARTIAL_WIDTH:0] OUT_MAX_Q14 =
        {{(PARTIAL_WIDTH+1-OUT_WIDTH){1'b0}}, {OUT_WIDTH{1'b1}}};

    function [OUT_WIDTH-1:0] relu_saturate_q14;
        input signed [PARTIAL_WIDTH:0] val_q14;
        begin
            if (val_q14[PARTIAL_WIDTH]) begin
                relu_saturate_q14 = {OUT_WIDTH{1'b0}};
            end
            else if (val_q14 > OUT_MAX_Q14) begin
                relu_saturate_q14 = {OUT_WIDTH{1'b1}};
            end
            else begin
                relu_saturate_q14 = val_q14[OUT_WIDTH-1:0];
            end
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state              <= S_IDLE;
            window_reg         <= 0;
            valid_out          <= 0;
            dout               <= 0;
            launch_step        <= 0;
            collect_step       <= 0;
            partial_sum_group0 <= 0;
        end

        else begin
            if (valid_out && ready_in) begin
                valid_out <= 1'b0;
            end

            if (output_can_advance) begin
                if (state == S_IDLE) begin
                    if (fire_in) begin
                        window_reg         <= din;
                        launch_step        <= 0;
                        collect_step       <= 0;
                        partial_sum_group0 <= 0;
                        state              <= S_RUN;
                    end
                end

                else if (state == S_RUN) begin
                    if (launch_step == LAUNCH_TOTAL-1) begin
                        // launch_step 6-bit akan wrap ke 0, tapi state sudah DRAIN
                        // sehingga partial_valid_in berhenti.
                        launch_step <= launch_step + 1'b1;
                        state       <= S_DRAIN;
                    end
                    else begin
                        launch_step <= launch_step + 1'b1;
                    end
                end

                else if (state == S_DRAIN) begin
                    state <= S_DRAIN;
                end

                if (partial_valid_out) begin
                    if (!collect_group) begin
                        // group0: simpan partial signed Q28, jangan ReLU, jangan bias.
                        partial_sum_group0 <= partial_dout;
                    end
                    else begin
                        // group1: baru jumlahkan group0 + group1 + bias,
                        // shift Q28 -> Q14, lalu ReLU/saturasi.
                        dout[collect_out_channel*OUT_WIDTH +: OUT_WIDTH] <= relu_saturate_q14(final_q14);
                    end

                    if (collect_step == LAUNCH_TOTAL-1) begin
                        valid_out          <= 1'b1;
                        state              <= S_IDLE;
                        launch_step        <= 0;
                        collect_step       <= 0;
                        partial_sum_group0 <= 0;
                    end
                    else begin
                        collect_step <= collect_step + 1'b1;
                    end
                end
            end
        end
    end

endmodule