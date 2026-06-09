`timescale 1ns / 1ps

module top_tb;

    // =========================================================
    // Clock 100 MHz
    // Period = 10 ns
    // =========================================================
    localparam CLK_PERIOD_NS = 10;

    reg clk;
    reg rst;

    wire led0;
    wire led1;
    wire led2;
    wire led3;

    // =========================================================
    // DUT
    // =========================================================
    top uut (
        .clk(clk),
        .rst(rst),
        .led0(led0),
        .led1(led1),
        .led2(led2),
        .led3(led3)
    );

    // =========================================================
    // Clock generator
    // =========================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS/2) clk = ~clk;
    end

    // =========================================================
    // Cycle counter
    // =========================================================
    integer cycle_count;
    integer cycle_start;
    integer cycle_pred;

    always @(posedge clk) begin
        if (rst)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // =========================================================
    // Time record
    // =========================================================
    time t_start;
    time t_frame_done;
    time t_block1;
    time t_block2;
    time t_block3;
    time t_dense;
    time t_pred;

    reg got_frame_done;
    reg got_block1;
    reg got_block2;
    reg got_block3;
    reg got_dense;

    // =========================================================
    // Monitor internal valid signal
    //
    // Catatan:
    // Ini memakai hierarchical reference ke sinyal internal top:
    // uut.frame_done
    // uut.block1_valid
    // uut.block2_valid
    // uut.block3_valid
    // uut.dense_valid
    // uut.predicted_class
    //
    // Untuk behavioral simulation ini aman dan sangat membantu debug.
    // =========================================================
    always @(posedge clk) begin
        #1;

        if (!rst) begin

            if (!got_frame_done && uut.frame_done) begin
                got_frame_done = 1'b1;
                t_frame_done = $time;

                $display("[FRAME DONE] time = %0t ns, elapsed = %0t ns, cycle = %0d",
                         t_frame_done,
                         t_frame_done - t_start,
                         cycle_count - cycle_start);
            end

            if (!got_block1 && uut.block1_valid) begin
                got_block1 = 1'b1;
                t_block1 = $time;

                $display("[BLOCK1 OUT] time = %0t ns, elapsed = %0t ns, cycle = %0d",
                         t_block1,
                         t_block1 - t_start,
                         cycle_count - cycle_start);
            end

            if (!got_block2 && uut.block2_valid) begin
                got_block2 = 1'b1;
                t_block2 = $time;

                $display("[BLOCK2 OUT] time = %0t ns, elapsed = %0t ns, cycle = %0d",
                         t_block2,
                         t_block2 - t_start,
                         cycle_count - cycle_start);
            end

            if (!got_block3 && uut.block3_valid) begin
                got_block3 = 1'b1;
                t_block3 = $time;

                $display("[BLOCK3 OUT] time = %0t ns, elapsed = %0t ns, cycle = %0d",
                         t_block3,
                         t_block3 - t_start,
                         cycle_count - cycle_start);
            end

            if (!got_dense && uut.dense_valid) begin
                got_dense = 1'b1;
                t_dense = $time;

                $display("[DENSE OUT] time = %0t ns, elapsed = %0t ns, cycle = %0d",
                         t_dense,
                         t_dense - t_start,
                         cycle_count - cycle_start);
            end

        end
    end

    // =========================================================
    // Main simulation
    // =========================================================
    initial begin
        // -----------------------------------------------------
        // Init
        // -----------------------------------------------------
        rst = 1'b1;

        cycle_count = 0;
        cycle_start = 0;
        cycle_pred  = 0;

        got_frame_done = 1'b0;
        got_block1     = 1'b0;
        got_block2     = 1'b0;
        got_block3     = 1'b0;
        got_dense      = 1'b0;

        t_start      = 0;
        t_frame_done = 0;
        t_block1     = 0;
        t_block2     = 0;
        t_block3     = 0;
        t_dense      = 0;
        t_pred       = 0;

        $display("==============================================");
        $display(" CNN FPGA TOP BEHAVIORAL SIMULATION");
        $display(" Clock Frequency = 100 MHz");
        $display(" Clock Period    = 10 ns");
        $display("==============================================");

        // -----------------------------------------------------
        // Reset beberapa cycle
        // -----------------------------------------------------
        repeat (10) @(posedge clk);
        #1;

        rst = 1'b0;
        t_start = $time;
        cycle_start = cycle_count;

        $display("[RESET RELEASE] time = %0t ns", t_start);

        // -----------------------------------------------------
        // Tunggu dense_valid keluar
        // -----------------------------------------------------
        wait (uut.dense_valid === 1'b1);

        // Karena argmax versi pipeline butuh beberapa cycle.
        // Kalau argmax kamu versi lama, ini tetap aman karena class_out
        // akan tetap menyimpan hasil terakhir.
        repeat (5) @(posedge clk);
        #1;

        t_pred = $time;
        cycle_pred = cycle_count - cycle_start;

        $display("==============================================");
        $display("[PREDICTION READY]");
        $display("time absolute       = %0t ns", t_pred);
        $display("time from reset off = %0t ns", t_pred - t_start);
        $display("cycle from start    = %0d cycle", cycle_pred);
        $display("predicted_class     = %0d", uut.predicted_class);
        $display("LED binary          = %b%b%b%b", led3, led2, led1, led0);
        $display("==============================================");

        repeat (20) @(posedge clk);

        $finish;
    end

    // =========================================================
    // Timeout guard
    // Supaya simulasi tidak jalan selamanya kalau valid tidak keluar.
    // 200000 cycle @ 100MHz = 2 ms simulation time.
    // =========================================================
    initial begin
        repeat (200000) @(posedge clk);
        #1;

        $display("==============================================");
        $display("[TIMEOUT]");
        $display("Prediction did not finish.");
        $display("time = %0t ns", $time);
        $display("cycle = %0d", cycle_count);
        $display("==============================================");

        $finish;
    end

endmodule