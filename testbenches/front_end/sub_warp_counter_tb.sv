`timescale 1ns/1ps
module sub_warp_counter_tb;
    logic clk, reset;
    logic fetch_valid;
    logic buffer_full;
    logic have_ready;
    logic [1:0] sub_warp_cycle;
    logic sub_warp_valid;

    int errors = 0;

    sub_warp_counter DUT (
        .clk(clk),
        .reset(reset),
        .fetch_valid(fetch_valid),
        .buffer_full(buffer_full),
        .have_ready(have_ready),
        .sub_warp_cycle(sub_warp_cycle),
        .sub_warp_valid(sub_warp_valid)
    );

    always #5 clk = ~clk;

    task automatic check(input string msg, input logic [1:0] exp_cycle, input logic exp_valid);
        $display("%s: cycle = %0d valid = %0b", msg, sub_warp_cycle, sub_warp_valid);
        if (sub_warp_cycle !== exp_cycle || sub_warp_valid !== exp_valid) begin
            errors++;
            $display("FAIL | expected cycle = %0d valid = %0b", exp_cycle, exp_valid);
        end
    endtask

    task automatic tick();
        @(posedge clk); #1;
    endtask

    // Drive inputs on the negedge so they are stable for the next posedge
    task automatic drive(input logic fv, input logic hr, input logic bf);
        @(negedge clk);
        fetch_valid = fv;
        have_ready = hr;
        buffer_full = bf;
    endtask

    initial begin
        clk = 0;
        reset = 1;
        fetch_valid = 0;
        have_ready = 0;
        buffer_full = 0;

        // reset state: sub_warp_cycle is 3 and waiting for an instruction
        tick(); tick();
        check("post-reset", 2'd3, 1'b0);
        reset = 0;

        // waits at 3 until there is both a valid fetch and a ready warp
        drive(0, 1, 0); tick();
        check("hold at 3, fetch_valid = 0", 2'd3, 1'b0);
        drive(1, 0, 0); tick();
        check("hold at 3, have_ready = 0", 2'd3, 1'b0);

        drive(1, 1, 0); tick();
        check("fetch_valid and have_ready => cycle 0", 2'd0, 1'b1);
        drive(0, 0, 0);

        // counts 0 -> 3 freely, regardless of fetch_valid/have_ready
        tick(); check("cycle 1", 2'd1, 1'b1);
        tick(); check("cycle 2", 2'd2, 1'b1);
        tick(); check("cycle 3", 2'd3, 1'b1);

        // after sub-warp 3 executes, the counter spends one cycle waiting at 3
        // even if the next instruction is already available
        drive(1, 1, 0); tick();
        check("one waiting cycle after sub-warp 3, even with next fetch ready", 2'd3, 1'b0);
        tick();
        check("next instruction starts", 2'd0, 1'b1);

        tick(); check("cycle 1", 2'd1, 1'b1);
        tick(); check("cycle 2", 2'd2, 1'b1);
        drive(0, 0, 0); tick();
        check("cycle 3", 2'd3, 1'b1);

        for (int k = 0; k < 4; k++) begin
            tick();
            check("hold at 3 while nothing is ready", 2'd3, 1'b0);
        end

        drive(1, 1, 0); tick();
        check("instruction finally available => cycle 0", 2'd0, 1'b1);
        drive(0, 0, 0);

        // buffer_full mid-span: freeze at cycle 1, invalid, resume at 2
        tick();
        check("cycle 1 before buffer_full", 2'd1, 1'b1);
        drive(0, 0, 1);
        #1;
        check("buffer_full makes the current sub-warp invalid immediately", 2'd1, 1'b0);
        for (int k = 0; k < 4; k++) begin
            tick();
            check("held at cycle 1 (buffer_full)", 2'd1, 1'b0);
        end
        drive(0, 0, 0);
        #1;
        check("buffer_full clears, cycle 1 valid again", 2'd1, 1'b1);
        tick();
        check("resumes to cycle 2 (not restarted)", 2'd2, 1'b1);
        tick();
        check("cycle 3", 2'd3, 1'b1);

        // buffer_full while sub-warp 3 is executing: sub-warp 3 is held, not dropped
        drive(1, 1, 1);
        tick();
        check("buffer_full at sub-warp 3 holds it", 2'd3, 1'b0);
        tick();
        check("still held", 2'd3, 1'b0);
        drive(1, 1, 0);
        #1;
        check("buffer_full clears, sub-warp 3 valid again", 2'd3, 1'b1);
        tick();
        check("then the waiting cycle", 2'd3, 1'b0);
        tick();
        check("next instruction starts", 2'd0, 1'b1);

        // buffer_full while waiting at 3 blocks the restart even if an instruction is ready
        tick(); tick(); tick(); tick();
        check("waiting at 3", 2'd3, 1'b0);
        drive(1, 1, 1);
        tick();
        check("buffer_full blocks the 3 -> 0 restart", 2'd3, 1'b0);
        tick();
        check("still blocked", 2'd3, 1'b0);
        drive(1, 1, 0);
        tick();
        check("buffer_full clears => cycle 0", 2'd0, 1'b1);

        // mid-span reset
        drive(0, 0, 0);
        tick();
        check("cycle 1", 2'd1, 1'b1);
        reset = 1;
        tick();
        check("mid-span reset back to waiting at 3", 2'd3, 1'b0);
        reset = 0;
        tick();
        check("stays waiting after reset", 2'd3, 1'b0);

        if (errors == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "%0d TEST(S) FAILED", errors);

        $finish;
    end
endmodule
