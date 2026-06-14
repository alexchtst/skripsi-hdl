`timescale 1ns / 1ps

module argmax10_u32(
    input  wire [10*32-1:0] din,
    output reg  [3:0]      argmax,
    output reg  [31:0]     max_value
);

    integer i;
    reg [31:0] current_value;

    always @(*) begin
        argmax    = 4'd0;
        max_value = din[0*32 +: 32];

        for (i = 1; i < 10; i = i + 1) begin
            current_value = din[i*32 +: 32];

            // Pakai '>' bukan '>=' supaya tie-break sama seperti np.argmax:
            // kalau nilainya sama, index paling kecil yang dipilih.
            if (current_value > max_value) begin
                max_value = current_value;
                argmax    = i[3:0];
            end
        end
    end

endmodule