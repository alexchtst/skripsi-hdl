`timescale 1ns / 1ps

module stream_safe_28x28 #(
    parameter WIDTH  = 28,
    parameter HEIGHT = 28,
    parameter ADDR_W = 10
)(
    input  wire clk,
    input  wire rst,

    input  wire frame_ready,
    input  wire ready_in,

    output reg  valid_out,
    output reg [7:0] pixel_out,
    output reg [4:0] x,
    output reg [4:0] y,
    output reg frame_start,
    output reg frame_done
);

    reg [7:0] frame_mem [0:783];
    reg [ADDR_W-1:0] addr;

    initial begin
        $readmemh("mnist_img_2.mem", frame_mem);
    end

    wire fire;
    assign fire = valid_out && ready_in;

    always @(posedge clk) begin
        if (rst) begin
            addr        <= 0;
            x           <= 0;
            y           <= 0;
            pixel_out   <= 0;
            valid_out   <= 0;
            frame_start <= 0;
            frame_done  <= 0;
        end else begin
            frame_start <= 0;
            frame_done  <= 0;

            // start frame
            if (!valid_out && frame_ready) begin
                addr        <= 0;
                x           <= 0;
                y           <= 0;
                pixel_out   <= frame_mem[0];
                valid_out   <= 1;
                frame_start <= 1;
            end

            // transfer terjadi
            else if (fire) begin
                if (addr == WIDTH*HEIGHT - 1) begin
                    frame_done <= 1;
                    valid_out  <= 0;
                    addr       <= 0;
                    x          <= 0;
                    y          <= 0;
                end else begin
                    addr      <= addr + 1;
                    pixel_out <= frame_mem[addr + 1];

                    if (x == WIDTH-1) begin
                        x <= 0;
                        y <= y + 1;
                    end else begin
                        x <= x + 1;
                    end
                end
            end

            // kalau ready_in = 0, tidak ada else
            // artinya pixel_out, valid_out, addr, x, y semuanya HOLD
        end
    end

endmodule