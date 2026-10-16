`timescale 1ns/1ps
module commit_tracker_tb;
    logic clk, reset;
    logic consume;
    logic [2:0] ws_next_warp;
    logic [7:0][31:0] recon_top_mask_arr;
    logic [7:0] rf_write_enable;
    logic [7:0][9:0] rf_write_addr;
    logic [7:0] commit_done;

    int errors = 0;

    commit_tracker DUT (
        .clk(clk),
        .reset(reset),
        .consume(consume),
        .ws_next_warp(ws_next_warp),
        .recon_top_mask_arr(recon_top_mask_arr),
        .rf_write_enable(rf_write_enable),
        .rf_write_addr(rf_write_addr),
        .commit_done(commit_done)
    );

    always #5 clk = ~clk;

    task automatic check(input logic [7:0] actual, input logic [7:0] expected);
        if (actual !== expected) begin
            $display("FAIL | commit_done = %b, expected %b", actual, expected);
            errors++;
        end else begin
            $display("PASS | commit_done = %b", actual);
        end
    endtask

    // The warp scheduler consumes an instruction for `warp` whose active mask is `mask`
    task automatic issue(input logic [2:0] warp, input logic [31:0] mask);
        @(negedge clk);
        recon_top_mask_arr[warp] = mask;
        ws_next_warp = warp;
        consume = 1'b1;
        @(negedge clk);
        consume = 1'b0;
    endtask

    // One cycle of register-file writes: lane l writes {warp, sub_warp, R1} when lanes[l] = 1
    task automatic write_lanes(input logic [2:0] warp, input logic [1:0] sub_warp, input logic [7:0] lanes);
        @(negedge clk);
        for (int l = 0; l < 8; l++) begin
            rf_write_enable[l] = lanes[l];
            rf_write_addr[l] = {warp, sub_warp, 5'd1};
        end
        @(posedge clk);
        #1;
        rf_write_enable = '0;
    endtask

    // A full instruction worth of writes: every sub-warp, every lane in `mask`
    task automatic write_instr(input logic [2:0] warp, input logic [31:0] mask);
        for (int sw = 0; sw < 4; sw++)
            if (|mask[sw*8 +: 8])
                write_lanes(warp, sw[1:0], mask[sw*8 +: 8]);
    endtask

    task automatic idle(input int n);
        repeat (n) @(posedge clk);
        #1;
    endtask

    initial begin
        clk = 0;
        reset = 1;
        consume = 0;
        ws_next_warp = 3'd0;
        recon_top_mask_arr = '0;
        rf_write_enable = '0;
        rf_write_addr = '0;

        repeat (2) @(posedge clk);
        reset = 0;
        idle(1);
        $display("post-reset");
        check(commit_done, 8'b0);

        // 1. Full warp: done only after all 32 threads write back
        $display("\nTest 1: full warp 2");
        issue(3'd2, 32'hFFFF_FFFF);
        write_lanes(3'd2, 2'd0, 8'hFF);
        check(commit_done, 8'b0);
        write_lanes(3'd2, 2'd1, 8'hFF);
        check(commit_done, 8'b0);
        write_lanes(3'd2, 2'd2, 8'hFF);
        check(commit_done, 8'b0);
        write_lanes(3'd2, 2'd3, 8'hFF);
        $display("commit_done[2] set after sub-warp 3 writes back");
        check(commit_done, 8'b0000_0100);
        idle(1);
        $display("commit_done is a single-cycle pulse");
        check(commit_done, 8'b0);

        // 2. Divergent warp: only the active threads need to write back
        $display("\nTest 2: warp 5 with only threads 4-7 and 24-25 active");
        issue(3'd5, 32'h0300_00F0);
        write_lanes(3'd5, 2'd0, 8'hF0);
        check(commit_done, 8'b0);
        write_lanes(3'd5, 2'd3, 8'h03);
        check(commit_done, 8'b0010_0000);

        // 3. Lanes of a sub-warp trickle in over several cycles (buffered in the writeback FIFO)
        $display("\nTest 3: warp 6 writebacks spread across cycles with gaps");
        issue(3'd6, 32'h0000_00FF);
        write_lanes(3'd6, 2'd0, 8'h0F);
        idle(3);
        check(commit_done, 8'b0);
        write_lanes(3'd6, 2'd0, 8'h30);
        check(commit_done, 8'b0);
        write_lanes(3'd6, 2'd0, 8'hC0);
        check(commit_done, 8'b0100_0000);

        // 4. Interleaved warps complete independently, including in the same cycle
        $display("\nTest 4: warps 1 and 3 interleaved, finishing on the same cycle");
        issue(3'd1, 32'hFFFF_FFFF);
        issue(3'd3, 32'hFFFF_FFFF);
        for (int sw = 0; sw < 3; sw++) begin
            write_lanes(3'd1, sw[1:0], 8'hFF);
            write_lanes(3'd3, sw[1:0], 8'hFF);
        end
        check(commit_done, 8'b0);
        // last sub-warp: lanes 0-3 write for warp 1, lanes 4-7 write for warp 3 in the same cycle,
        // then the other halves together
        @(negedge clk);
        for (int l = 0; l < 8; l++) begin
            rf_write_enable[l] = 1'b1;
            rf_write_addr[l] = (l < 4) ? {3'd1, 2'd3, 5'd1} : {3'd3, 2'd3, 5'd1};
        end
        @(posedge clk); #1;
        check(commit_done, 8'b0);
        @(negedge clk);
        for (int l = 0; l < 8; l++)
            rf_write_addr[l] = (l < 4) ? {3'd3, 2'd3, 5'd1} : {3'd1, 2'd3, 5'd1};
        @(posedge clk); #1;
        rf_write_enable = '0;
        check(commit_done, 8'b0000_1010);

        // 5. Writebacks with no pending instruction never signal a commit
        $display("\nTest 5: writes for warp 7 with nothing pending");
        write_instr(3'd7, 32'hFFFF_FFFF);
        idle(1);
        check(commit_done, 8'b0);

        // 6. consume clears any stale writeback bits from before the instruction was issued
        $display("\nTest 6: consume clears stale writeback bits for warp 7");
        issue(3'd7, 32'h0000_FFFF);
        write_lanes(3'd7, 2'd0, 8'hFF);
        check(commit_done, 8'b0);
        write_lanes(3'd7, 2'd1, 8'hFF);
        check(commit_done, 8'b1000_0000);

        // 7. A new instruction for the same warp needs a fresh set of writebacks
        $display("\nTest 7: back-to-back instructions on warp 0");
        issue(3'd0, 32'h0000_00FF);
        write_lanes(3'd0, 2'd0, 8'hFF);
        check(commit_done, 8'b0000_0001);
        issue(3'd0, 32'h0000_FF00);
        write_lanes(3'd0, 2'd0, 8'hFF); // stale: wrong sub-warp for this instruction
        check(commit_done, 8'b0);
        write_lanes(3'd0, 2'd1, 8'hFF);
        check(commit_done, 8'b0000_0001);

        // 8. Reset mid-instruction clears pending state
        $display("\nTest 8: reset with warp 4 half written back");
        issue(3'd4, 32'h0000_FFFF);
        write_lanes(3'd4, 2'd0, 8'hFF);
        reset = 1;
        idle(2);
        reset = 0;
        write_lanes(3'd4, 2'd1, 8'hFF);
        check(commit_done, 8'b0);
        idle(1);
        check(commit_done, 8'b0);

        if (errors == 0) $display("\nALL TESTS PASSED");
        else $fatal(1, "\n%0d TEST(S) FAILED", errors);

        $finish;
    end
endmodule
