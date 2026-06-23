`timescale 1ns / 1ps

module elastic_fifo #(
    parameter DATA_WIDTH = 256,
    parameter DEPTH = 5
)(
    input wire clk,
    input wire rst,

    // =========================================================
    // INPUT SIDE / PRODUCER
    // dari block1
    // =========================================================
    input wire valid_in,
    output wire ready_out,
    input wire [DATA_WIDTH-1:0] din,

    // =========================================================
    // OUTPUT SIDE / CONSUMER
    // ke block2 kernel
    // =========================================================
    output wire valid_out,
    input wire ready_in,
    output wire [DATA_WIDTH-1:0] dout,

    // optional debug
    output wire full,
    output wire empty,
    output wire [$clog2(DEPTH+1)-1:0] level
);

    localparam PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

    (* ram_style = "auto" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;

    reg [$clog2(DEPTH+1)-1:0] count;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    assign ready_out = !full;
    assign valid_out = !empty;

    assign dout  = mem[rd_ptr];
    assign level = count;

    wire push_fire;
    wire pop_fire;

    assign push_fire = valid_in  && ready_out;
    assign pop_fire  = valid_out && ready_in;

    function [PTR_WIDTH-1:0] inc_ptr;
        input [PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == DEPTH - 1)
                inc_ptr = 0;
            else
                inc_ptr = ptr + 1'b1;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
        end

        else begin

            // tulis data baru dari block1
            if (push_fire) begin
                mem[wr_ptr] <= din;
                wr_ptr <= inc_ptr(wr_ptr);
            end

            // keluarkan data ke block2
            if (pop_fire) begin
                rd_ptr <= inc_ptr(rd_ptr);
            end

            case ({push_fire, pop_fire})
                2'b10: count <= count + 1'b1; // push only
                2'b01: count <= count - 1'b1; // pop only
                default: count <= count;       // sama-sama atau diam
            endcase
        end
    end

endmodule