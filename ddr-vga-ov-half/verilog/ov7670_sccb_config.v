`timescale 1ns / 1ps

module ov7670_sccb_config #(
    parameter integer CLK_FREQ_HZ          = 100_000_000,
    parameter integer SCCB_FREQ_HZ         = 100_000,

    // Mengikuti konsep repo: tunggu power-up dulu sebelum reset/config.
    parameter integer POWERUP_DELAY_MS     = 600,
    parameter integer RESET_LOW_MS         = 10,
    parameter integer RESET_RELEASE_MS     = 10,
    parameter integer COM7_RESET_DELAY_MS  = 10,
    parameter integer INTER_REG_DELAY_MS   = 1,

    // Untuk debug kamera.
    // 0 = gambar normal
    // 1 = coba test pattern/color bar
    parameter integer ENABLE_TEST_PATTERN  = 0
)(
    input  wire clk,
    input  wire rst,      // active-high reset internal FPGA
    input  wire start,

    output reg  scl,
    inout  wire sda,

    // OV7670 reset pin.
    // OV7670 reset biasanya active-low.
    // cam_rst = 0 -> reset camera
    // cam_rst = 1 -> camera normal run
    output reg  cam_rst,

    output reg  done,
    output reg  busy,
    output reg  error
);

    // ============================================================
    // SCCB/I2C basic constants
    // ============================================================
    localparam [7:0] OV7670_SCCB_ADDR_WR = 8'h42;

    // Tick 4x dari target SCCB.
    // Dengan SCCB_FREQ_HZ = 100 kHz, tick sekitar 400 kHz.
    localparam integer TICK_DIV =
        (CLK_FREQ_HZ / (SCCB_FREQ_HZ * 4));

    localparam integer TICKS_PER_MS =
        ((SCCB_FREQ_HZ * 4) / 1000);

    localparam integer POWERUP_DELAY_TICKS =
        POWERUP_DELAY_MS * TICKS_PER_MS;

    localparam integer RESET_LOW_TICKS =
        RESET_LOW_MS * TICKS_PER_MS;

    localparam integer RESET_RELEASE_TICKS =
        RESET_RELEASE_MS * TICKS_PER_MS;

    localparam integer COM7_RESET_DELAY_TICKS =
        COM7_RESET_DELAY_MS * TICKS_PER_MS;

    localparam integer INTER_REG_DELAY_TICKS =
        INTER_REG_DELAY_MS * TICKS_PER_MS;

    // ============================================================
    // Tick generator
    // ============================================================
    reg [31:0] div_cnt = 32'd0;
    reg        tick    = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            div_cnt <= 32'd0;
            tick    <= 1'b0;
        end else begin
            if (div_cnt == TICK_DIV - 1) begin
                div_cnt <= 32'd0;
                tick    <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 1'b1;
                tick    <= 1'b0;
            end
        end
    end

    // ============================================================
    // Open-drain SDA
    //
    // sda_drive_low = 1 -> FPGA tarik SDA ke 0
    // sda_drive_low = 0 -> FPGA release SDA, pull-up membuat 1
    // ============================================================
    reg sda_drive_low = 1'b0;

    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // ============================================================
    // Register table OV7670
    //
    // Disesuaikan untuk project kamu:
    // - RGB565 dipakai
    // - RGB444 dimatikan
    // - COM10 = 0x00 supaya PCLK free running
    // - test pattern optional
    // ============================================================
    localparam integer REG_COUNT = 77;

    reg [15:0] reg_table [0:REG_COUNT-1];

    initial begin
        // --------------------------------------------------------
        // Software reset OV7670
        // --------------------------------------------------------
        reg_table[0]  = 16'h1280; // COM7 reset

        // --------------------------------------------------------
        // Output format / pixel clock / RGB565
        // --------------------------------------------------------
        reg_table[1]  = 16'h1204; // COM7: RGB output

        // PERBAIKAN PENTING:
        // Dulu: 16'h1520 -> PCLK tidak toggle saat horizontal blank.
        // Sekarang: 16'h1500 -> PCLK free running.
        // Ini penting karena capture kamu memakai cam_pclk sebagai clock.
        reg_table[2]  = 16'h1500; // COM10: PCLK free running

        reg_table[3]  = 16'h40D0; // COM15: RGB565, full output range

        // Penting untuk project kita:
        // RGB444 harus dimatikan karena pipeline kamu pakai RGB565 16-bit.
        reg_table[4]  = 16'h8C00; // RGB444 disabled

        reg_table[5]  = 16'h1101; // CLKRC: clock divider
        reg_table[6]  = 16'h6B4A; // DBLV/PLL control

        // --------------------------------------------------------
        // Basic mode / scaling / data sequence
        // --------------------------------------------------------
        reg_table[7]  = 16'h0C00; // COM3: default, no scaling
        reg_table[8]  = 16'h3E00; // COM14: no scaling, normal PCLK
        reg_table[9]  = 16'h0400; // COM1: disable CCIR656
        reg_table[10] = 16'h3A04; // TSLB: output data sequence

        // --------------------------------------------------------
        // Gain / color matrix / gamma related
        // --------------------------------------------------------
        reg_table[11] = 16'h1418; // COM9: gain limit
        reg_table[12] = 16'h4FB3; // MTX1
        reg_table[13] = 16'h50B3; // MTX2
        reg_table[14] = 16'h5100; // MTX3
        reg_table[15] = 16'h523D; // MTX4
        reg_table[16] = 16'h53A7; // MTX5
        reg_table[17] = 16'h54E4; // MTX6
        reg_table[18] = 16'h589E; // MTXS
        reg_table[19] = 16'h3DC0; // COM13: gamma enable, UV saturation

        // --------------------------------------------------------
        // Windowing VGA
        // --------------------------------------------------------
        reg_table[20] = 16'h1714; // HSTART
        reg_table[21] = 16'h1802; // HSTOP
        reg_table[22] = 16'h3280; // HREF
        reg_table[23] = 16'h1903; // VSTART
        reg_table[24] = 16'h1A7B; // VSTOP
        reg_table[25] = 16'h030A; // VREF

        // --------------------------------------------------------
        // Timing / misc
        // --------------------------------------------------------
        reg_table[26] = 16'h0F41; // COM6
        reg_table[27] = 16'h1E00; // MVFP: no mirror / no flip
        reg_table[28] = 16'h330B; // CHLF
        reg_table[29] = 16'h3C78; // COM12
        reg_table[30] = 16'h6900; // GFIX
        reg_table[31] = 16'h7400; // REG74
        reg_table[32] = 16'hB084; // reserved magic
        reg_table[33] = 16'hB10C; // ABLC1
        reg_table[34] = 16'hB20E; // reserved
        reg_table[35] = 16'hB380; // THL_ST

        // --------------------------------------------------------
        // Scaling / test pattern area
        // --------------------------------------------------------
        reg_table[36] = 16'h703A;

        if (ENABLE_TEST_PATTERN != 0)
            reg_table[37] = 16'h71B5; // test pattern / color bar candidate
        else
            reg_table[37] = 16'h7135; // normal mode

        reg_table[38] = 16'h7211;
        reg_table[39] = 16'h73F0;
        reg_table[40] = 16'hA202;

        // --------------------------------------------------------
        // Gamma curve
        // --------------------------------------------------------
        reg_table[41] = 16'h7A20;
        reg_table[42] = 16'h7B10;
        reg_table[43] = 16'h7C1E;
        reg_table[44] = 16'h7D35;
        reg_table[45] = 16'h7E5A;
        reg_table[46] = 16'h7F69;
        reg_table[47] = 16'h8076;
        reg_table[48] = 16'h8180;
        reg_table[49] = 16'h8288;
        reg_table[50] = 16'h838F;
        reg_table[51] = 16'h8496;
        reg_table[52] = 16'h85A3;
        reg_table[53] = 16'h86AF;
        reg_table[54] = 16'h87C4;
        reg_table[55] = 16'h88D7;
        reg_table[56] = 16'h89E8;

        // --------------------------------------------------------
        // AGC/AEC sequence
        // --------------------------------------------------------
        reg_table[57] = 16'h13E0; // COM8: disable AGC/AEC sementara
        reg_table[58] = 16'h0000; // GAIN
        reg_table[59] = 16'h1000; // AECH
        reg_table[60] = 16'h0D40; // COM4
        reg_table[61] = 16'h1418; // COM9
        reg_table[62] = 16'hA505; // BD50MAX
        reg_table[63] = 16'hAB07; // DB60MAX
        reg_table[64] = 16'h2495; // AGC upper limit
        reg_table[65] = 16'h2533; // AGC lower limit
        reg_table[66] = 16'h26E3; // AGC/AEC fast mode region
        reg_table[67] = 16'h9F78; // HAECC1
        reg_table[68] = 16'hA068; // HAECC2
        reg_table[69] = 16'hA103;
        reg_table[70] = 16'hA6D8; // HAECC3
        reg_table[71] = 16'hA7D8; // HAECC4
        reg_table[72] = 16'hA8F0; // HAECC5
        reg_table[73] = 16'hA990; // HAECC6
        reg_table[74] = 16'hAA94; // HAECC7

        // Enable kembali AGC/AEC/AWB.
        reg_table[75] = 16'h13E5; // COM8: enable AGC/AEC/AWB
        reg_table[76] = 16'h6906; // RGB gain
    end

    // ============================================================
    // FSM states
    // ============================================================
    localparam ST_IDLE              = 5'd0;
    localparam ST_POWERUP_WAIT      = 5'd1;
    localparam ST_RESET_LOW         = 5'd2;
    localparam ST_RESET_RELEASE     = 5'd3;
    localparam ST_LOAD_REG          = 5'd4;
    localparam ST_START_0           = 5'd5;
    localparam ST_START_1           = 5'd6;
    localparam ST_START_2           = 5'd7;
    localparam ST_SEND_BIT_0        = 5'd8;
    localparam ST_SEND_BIT_1        = 5'd9;
    localparam ST_SEND_BIT_2        = 5'd10;
    localparam ST_ACK_0             = 5'd11;
    localparam ST_ACK_1             = 5'd12;
    localparam ST_ACK_2             = 5'd13;
    localparam ST_ACK_3             = 5'd14;
    localparam ST_STOP_0            = 5'd15;
    localparam ST_STOP_1            = 5'd16;
    localparam ST_STOP_2            = 5'd17;
    localparam ST_DELAY_BETWEEN     = 5'd18;
    localparam ST_DONE              = 5'd19;

    reg [4:0]  state = ST_IDLE;

    reg [31:0] delay_cnt    = 32'd0;
    reg [31:0] delay_target = 32'd0;

    reg [7:0]  reg_index    = 8'd0;
    reg [15:0] current_pair = 16'd0;

    reg [7:0]  byte_to_send = 8'd0;
    reg [1:0]  byte_index   = 2'd0;
    reg [2:0]  bit_index    = 3'd7;

    // ============================================================
    // Main FSM
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            state         <= ST_IDLE;

            scl           <= 1'b1;
            sda_drive_low <= 1'b0;

            cam_rst       <= 1'b0; // hold camera reset while FPGA reset
            done          <= 1'b0;
            busy          <= 1'b0;
            error         <= 1'b0;

            delay_cnt     <= 32'd0;
            delay_target  <= 32'd0;

            reg_index     <= 8'd0;
            current_pair  <= 16'd0;

            byte_to_send  <= 8'd0;
            byte_index    <= 2'd0;
            bit_index     <= 3'd7;
        end else begin
            if (tick) begin
                case (state)

                    // ------------------------------------------------
                    // Idle
                    // ------------------------------------------------
                    ST_IDLE: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;

                        cam_rst       <= 1'b0;
                        done          <= 1'b0;
                        busy          <= 1'b0;
                        error         <= 1'b0;

                        delay_cnt     <= 32'd0;
                        reg_index     <= 8'd0;

                        if (start) begin
                            busy         <= 1'b1;
                            cam_rst      <= 1'b1; // release dulu, tunggu power-up
                            delay_target <= POWERUP_DELAY_TICKS;
                            delay_cnt    <= 32'd0;
                            state        <= ST_POWERUP_WAIT;
                        end
                    end

                    // ------------------------------------------------
                    // Wait power-up dengan XCLK sudah berjalan
                    // ------------------------------------------------
                    ST_POWERUP_WAIT: begin
                        busy    <= 1'b1;
                        cam_rst <= 1'b1;

                        if (delay_cnt >= delay_target) begin
                            delay_cnt    <= 32'd0;
                            delay_target <= RESET_LOW_TICKS;
                            cam_rst      <= 1'b0; // active-low reset
                            state        <= ST_RESET_LOW;
                        end else begin
                            delay_cnt <= delay_cnt + 1'b1;
                        end
                    end

                    // ------------------------------------------------
                    // Assert reset low
                    // ------------------------------------------------
                    ST_RESET_LOW: begin
                        busy    <= 1'b1;
                        cam_rst <= 1'b0;

                        if (delay_cnt >= delay_target) begin
                            delay_cnt    <= 32'd0;
                            delay_target <= RESET_RELEASE_TICKS;
                            cam_rst      <= 1'b1;
                            state        <= ST_RESET_RELEASE;
                        end else begin
                            delay_cnt <= delay_cnt + 1'b1;
                        end
                    end

                    // ------------------------------------------------
                    // Wait after reset release
                    // ------------------------------------------------
                    ST_RESET_RELEASE: begin
                        busy    <= 1'b1;
                        cam_rst <= 1'b1;

                        if (delay_cnt >= delay_target) begin
                            delay_cnt <= 32'd0;
                            reg_index <= 8'd0;
                            state     <= ST_LOAD_REG;
                        end else begin
                            delay_cnt <= delay_cnt + 1'b1;
                        end
                    end

                    // ------------------------------------------------
                    // Load current register pair
                    // Transaction format:
                    // START + 0x42 + reg_addr + reg_value + STOP
                    // ------------------------------------------------
                    ST_LOAD_REG: begin
                        busy          <= 1'b1;
                        cam_rst       <= 1'b1;

                        current_pair  <= reg_table[reg_index];

                        byte_index    <= 2'd0;
                        byte_to_send  <= OV7670_SCCB_ADDR_WR;
                        bit_index     <= 3'd7;

                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;

                        state         <= ST_START_0;
                    end

                    // ------------------------------------------------
                    // START condition
                    // SDA turun saat SCL high
                    // ------------------------------------------------
                    ST_START_0: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;
                        state         <= ST_START_1;
                    end

                    ST_START_1: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state         <= ST_START_2;
                    end

                    ST_START_2: begin
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b1;
                        bit_index     <= 3'd7;
                        state         <= ST_SEND_BIT_0;
                    end

                    // ------------------------------------------------
                    // Send one bit
                    // ------------------------------------------------
                    ST_SEND_BIT_0: begin
                        scl <= 1'b0;

                        // open-drain style:
                        // bit 0 -> drive low
                        // bit 1 -> release high
                        if (byte_to_send[bit_index] == 1'b0)
                            sda_drive_low <= 1'b1;
                        else
                            sda_drive_low <= 1'b0;

                        state <= ST_SEND_BIT_1;
                    end

                    ST_SEND_BIT_1: begin
                        scl   <= 1'b1;
                        state <= ST_SEND_BIT_2;
                    end

                    ST_SEND_BIT_2: begin
                        scl <= 1'b0;

                        if (bit_index == 3'd0) begin
                            sda_drive_low <= 1'b0; // release untuk ACK
                            state         <= ST_ACK_0;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            state     <= ST_SEND_BIT_0;
                        end
                    end

                    // ------------------------------------------------
                    // ACK cycle
                    // ACK = SDA low dari camera.
                    //
                    // Perbaikan:
                    // ACK tidak dicek langsung saat SCL baru dinaikkan.
                    // Kita beri 1 tick dulu supaya SDA stabil.
                    // ------------------------------------------------
                    ST_ACK_0: begin
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b0; // release SDA
                        state         <= ST_ACK_1;
                    end

                    ST_ACK_1: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;
                        state         <= ST_ACK_2;
                    end

                    ST_ACK_2: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;

                        // Jika SDA tetap 1 saat ACK, berarti NACK.
                        // Untuk SCCB, kita latch sebagai error debug,
                        // tapi tetap lanjut supaya tidak stuck.
                        if (sda == 1'b1)
                            error <= 1'b1;

                        state <= ST_ACK_3;
                    end

                    ST_ACK_3: begin
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b0;

                        if (byte_index == 2'd0) begin
                            byte_index   <= 2'd1;
                            byte_to_send <= current_pair[15:8]; // register address
                            bit_index    <= 3'd7;
                            state        <= ST_SEND_BIT_0;
                        end else if (byte_index == 2'd1) begin
                            byte_index   <= 2'd2;
                            byte_to_send <= current_pair[7:0]; // register value
                            bit_index    <= 3'd7;
                            state        <= ST_SEND_BIT_0;
                        end else begin
                            state <= ST_STOP_0;
                        end
                    end

                    // ------------------------------------------------
                    // STOP condition
                    // SDA naik saat SCL high
                    // ------------------------------------------------
                    ST_STOP_0: begin
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b1;
                        state         <= ST_STOP_1;
                    end

                    ST_STOP_1: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state         <= ST_STOP_2;
                    end

                    ST_STOP_2: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0; // release SDA high

                        delay_cnt <= 32'd0;

                        // Setelah software reset COM7, beri delay lebih panjang.
                        if (current_pair == 16'h1280)
                            delay_target <= COM7_RESET_DELAY_TICKS;
                        else
                            delay_target <= INTER_REG_DELAY_TICKS;

                        state <= ST_DELAY_BETWEEN;
                    end

                    // ------------------------------------------------
                    // Delay antar register
                    // ------------------------------------------------
                    ST_DELAY_BETWEEN: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;

                        if (delay_cnt >= delay_target) begin
                            delay_cnt <= 32'd0;

                            if (reg_index == REG_COUNT - 1) begin
                                state <= ST_DONE;
                            end else begin
                                reg_index <= reg_index + 1'b1;
                                state     <= ST_LOAD_REG;
                            end
                        end else begin
                            delay_cnt <= delay_cnt + 1'b1;
                        end
                    end

                    // ------------------------------------------------
                    // Done
                    // ------------------------------------------------
                    ST_DONE: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;
                        cam_rst       <= 1'b1;

                        busy          <= 1'b0;
                        done          <= 1'b1;

                        // Tetap di DONE sampai reset FPGA.
                        state         <= ST_DONE;
                    end

                    default: begin
                        state <= ST_IDLE;
                    end

                endcase
            end
        end
    end

endmodule