`timescale 1ns / 1ps

module block1(

    input wire clk,
    input wire rst,

    // dari kernel window 3x3
    input wire valid_in,

    input wire [7:0]
        din0, din1, din2,
        din3, din4, din5,
        din6, din7, din8,

    // ready dari block setelah block1
    input wire ready_in,

    // ready balik ke kernel
    output wire ready_out,

    // output 8 channel setelah conv + relu + pool
    output wire [31:0] dout_ch0,
    output wire [31:0] dout_ch1,
    output wire [31:0] dout_ch2,
    output wire [31:0] dout_ch3,
    output wire [31:0] dout_ch4,
    output wire [31:0] dout_ch5,
    output wire [31:0] dout_ch6,
    output wire [31:0] dout_ch7,

    // valid masing-masing channel
    output wire [7:0] valid_channel,

    // valid gabungan untuk 8 channel
    output wire valid_out
);

    wire ready_ch0;
    wire ready_ch1;
    wire ready_ch2;
    wire ready_ch3;
    wire ready_ch4;
    wire ready_ch5;
    wire ready_ch6;
    wire ready_ch7;

    wire valid_ch0;
    wire valid_ch1;
    wire valid_ch2;
    wire valid_ch3;
    wire valid_ch4;
    wire valid_ch5;
    wire valid_ch6;
    wire valid_ch7;

    assign ready_out =
        ready_ch0 &
        ready_ch1 &
        ready_ch2 &
        ready_ch3 &
        ready_ch4 &
        ready_ch5 &
        ready_ch6 &
        ready_ch7;

    assign valid_channel = {
        valid_ch7,
        valid_ch6,
        valid_ch5,
        valid_ch4,
        valid_ch3,
        valid_ch2,
        valid_ch1,
        valid_ch0
    };

    assign valid_out =
        valid_ch0 &
        valid_ch1 &
        valid_ch2 &
        valid_ch3 &
        valid_ch4 &
        valid_ch5 &
        valid_ch6 &
        valid_ch7;

    block1_channel_unit ch0 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd0),

        .ready_out(ready_ch0),
        .dout(dout_ch0),
        .valid_out(valid_ch0)
    );

    block1_channel_unit ch1 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd1),

        .ready_out(ready_ch1),
        .dout(dout_ch1),
        .valid_out(valid_ch1)
    );

    block1_channel_unit ch2 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd2),

        .ready_out(ready_ch2),
        .dout(dout_ch2),
        .valid_out(valid_ch2)
    );

    block1_channel_unit ch3 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd3),

        .ready_out(ready_ch3),
        .dout(dout_ch3),
        .valid_out(valid_ch3)
    );

    block1_channel_unit ch4 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd4),

        .ready_out(ready_ch4),
        .dout(dout_ch4),
        .valid_out(valid_ch4)
    );

    block1_channel_unit ch5 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd5),

        .ready_out(ready_ch5),
        .dout(dout_ch5),
        .valid_out(valid_ch5)
    );

    block1_channel_unit ch6 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd6),

        .ready_out(ready_ch6),
        .dout(dout_ch6),
        .valid_out(valid_ch6)
    );

    block1_channel_unit ch7 (
        .clk(clk),
        .rst(rst),

        .ready_in(ready_in),
        .valid_in(valid_in),

        .din0(din0), .din1(din1), .din2(din2),
        .din3(din3), .din4(din4), .din5(din5),
        .din6(din6), .din7(din7), .din8(din8),

        .channel_idx(3'd7),

        .ready_out(ready_ch7),
        .dout(dout_ch7),
        .valid_out(valid_ch7)
    );

endmodule