`timescale 1ns/1ps
module warp_scheduler_tb;
    localparam int NUM_WARPS = 8;
    localparam int COMMIT_LATENCY = 6; // cycles from consume to commit_done/store_done/push2_done

    logic clk, reset;
    logic kernel_start;
    logic [3:0] num_warps;
    logic [7:0] commit_done, store_done;
    logic [NUM_WARPS-1:0] push2_done;
    logic have_ready;
    logic consume, fetch_allowed, fetch_valid;
    logic [1:0] sub_warp_cycle;
    logic sub_warp_valid;
    logic buffer_full;
    logic done_detect, flush_done;

    logic [2:0] curr_warp, next_warp;
    logic issue_valid, warps_done, kernel_done;

    int errors = 0;

    // Same glue as sm_top, with the prefetch buffer always holding an instruction
    assign fetch_valid = issue_valid && fetch_allowed;
    assign consume = issue_valid && ~|sub_warp_cycle && sub_warp_valid && !buffer_full;

    sub_warp_counter u_sub_warp_counter (
        .clk(clk),
        .reset(reset),
        .fetch_valid(fetch_valid),
        .buffer_full(buffer_full),
        .have_ready(have_ready),
        .sub_warp_cycle(sub_warp_cycle),
        .sub_warp_valid(sub_warp_valid)
    );

    warp_scheduler #(.NUM_WARPS(NUM_WARPS)) dut (
        .clk(clk),
        .reset(reset),
        .kernel_start(kernel_start),
        .num_warps(num_warps),
        .commit_done(commit_done),
        .store_done(store_done),
        .push2_done(push2_done),
        .have_ready(have_ready),
        .consume(consume),
        .fetch_allowed(fetch_allowed),
        .sub_warp_cycle(sub_warp_cycle),
        .sub_warp_valid(sub_warp_valid),
        .buffer_full(buffer_full),
        .done_detect(done_detect),
        .flush_done(flush_done),
        .curr_warp(curr_warp),
        .next_warp(next_warp),
        .issue_valid(issue_valid),
        .warps_done(warps_done),
        .kernel_done(kernel_done)
    );

    always #5 clk = ~clk;

    // warp w runs prog_len[w] instructions followed by DONE.
    // Every non-DONE instruction releases its warp COMMIT_LATENCY cycles after consumption
    // through commit_done, store_done or push2_done in rotation (ALU/FMA result, store, branch).
    
    logic model_en;
    int prog_len [NUM_WARPS];
    int issued [NUM_WARPS];
    int release_at [NUM_WARPS];
    int release_kind [NUM_WARPS];
    int cycle_count;
    logic done_pending;
    logic flush_en;
    int flush_delay;

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        commit_done <= '0;
        store_done <= '0;
        push2_done <= '0;
        done_detect <= 1'b0;

        if (model_en) begin
            // decode sees the consumed instruction the cycle after consume
            if (consume) begin
                if (issued[next_warp] == prog_len[next_warp]) begin
                    done_detect <= 1'b1;
                end else begin
                    release_at[next_warp] <= cycle_count + COMMIT_LATENCY;
                    release_kind[next_warp] <= issued[next_warp] % 3;
                end
                issued[next_warp] <= issued[next_warp] + 1;
            end

            for (int w = 0; w < NUM_WARPS; w++) begin
                if (release_at[w] == cycle_count) begin
                    case (release_kind[w])
                        0: commit_done[w] <= 1'b1;
                        1: store_done[w] <= 1'b1;
                        default: push2_done[w] <= 1'b1;
                    endcase
                    release_at[w] <= -1;
                end
            end
        end
    end

    // Data cache flush: flush_done pulses flush_delay cycles after warps_done rises
    int flush_count;
    always @(posedge clk) begin
        flush_done <= 1'b0;
        if (!flush_en || !warps_done || kernel_done)
            flush_count <= 0;
        else if (flush_count == flush_delay)
            flush_done <= 1'b1;
        else
            flush_count <= flush_count + 1;
    end

    // Issue gaps: consecutive consumes are normally 5 cycles apart (4 sub-warps + the waiting cycle
    // at sub-warp 3). A longer gap means issue stalled waiting for a warp to finish.
    // Only counted while every launched warp is still running, so the tail of a kernel is excluded
    int last_consume;
    int issued_count;
    int stall_gaps;
    always @(posedge clk) begin
        if (reset || kernel_start) begin
            last_consume <= -1;
            issued_count <= 0;
            stall_gaps <= 0;
        end else if (consume) begin
            if (last_consume >= 0 && cycle_count - last_consume > 5 && dut.finished == 8'(~((8'b1 << num_warps) - 8'd1)))
                stall_gaps <= stall_gaps + 1;
            last_consume <= cycle_count;
            issued_count <= issued_count + 1;
        end
    end

    always @(posedge clk) begin
        if (model_en && !reset) begin
            if (consume && !fetch_valid) begin
                $display("FAIL | consumed warp %0d without a valid fetch", next_warp);
                errors++;
            end
            if (consume && dut.instr_busy[next_warp]) begin
                $display("FAIL | consumed warp %0d while it still had an instruction in flight", next_warp);
                errors++;
            end
            if (consume && next_warp >= num_warps) begin
                $display("FAIL | consumed warp %0d outside the launched range (num_warps = %0d)", next_warp, num_warps);
                errors++;
            end
            if (consume && issued[next_warp] > prog_len[next_warp]) begin
                $display("FAIL | warp %0d issued again after DONE", next_warp);
                errors++;
            end
        end
    end

    task automatic tick();
        @(posedge clk);
        #1;
    endtask

    task automatic check_eq(input string msg, input logic [31:0] actual, input logic [31:0] expected);
        if (actual === expected) begin
            $display("PASS | %s = %0d", msg, actual);
        end else begin
            $display("FAIL | %s = %0d, expected %0d", msg, actual, expected);
            errors++;
        end
    endtask

    task automatic do_reset();
        reset = 1'b1;
        kernel_start = 1'b0;
        num_warps = 4'd0;
        buffer_full = 1'b0;
        model_en = 1'b0;
        flush_en = 1'b0;
        flush_delay = 3;
        foreach (issued[w]) begin
            issued[w] = 0;
            prog_len[w] = 0;
            release_at[w] = -1;
            release_kind[w] = 0;
        end
        tick();
        tick();
        reset = 1'b0;
    endtask

    task automatic launch(input logic [3:0] n);
        @(negedge clk);
        num_warps = n;
        kernel_start = 1'b1;
        @(negedge clk);
        kernel_start = 1'b0;
    endtask

    task automatic run_kernel(input logic [3:0] n, input int max_cycles);
        int start;
        model_en = 1'b1;
        flush_en = 1'b1;
        launch(n);
        start = cycle_count;
        while (!kernel_done && cycle_count - start < max_cycles)
            tick();
        if (!kernel_done) begin
            $display("FAIL | kernel with %0d warps did not finish within %0d cycles", n, max_cycles);
            errors++;
        end else begin
            $display("kernel with %0d warps finished after %0d cycles", n, cycle_count - start);
        end
    endtask

    initial begin
        clk = 0;
        cycle_count = 0;
        do_reset();

        // 1. Reset state
        $display("\nTest 1: reset state");
        check_eq("curr_warp", curr_warp, 0);
        check_eq("next_warp", next_warp, 0);
        check_eq("issue_valid", issue_valid, 0);
        check_eq("kernel_done", kernel_done, 0);
        check_eq("have_ready", have_ready, 0);

        // 2. Launch: warps 0-3 ready, 4-7 permanently finished
        $display("\nTest 2: launch 4 warps");
        launch(4);
        check_eq("ready", dut.ready, 8'b0000_1111);
        check_eq("finished", dut.finished, 8'b1111_0000);
        check_eq("issue_valid", issue_valid, 1);
        check_eq("have_ready", have_ready, 1);
        check_eq("warps_done", warps_done, 0);
        check_eq("kernel_done", kernel_done, 0);

        // 3. First consume marks warp 0 busy and blocks its next fetch. With a single warp there is
        //    nothing else to issue, so issue waits at sub-warp 3 until warp 0 is released
        $display("\nTest 3: consume blocks a warp until its instruction completes");
        do_reset();
        launch(1);
        while (!consume) tick();
        check_eq("consumed warp", next_warp, 0);
        tick();
        check_eq("instr_busy[0]", dut.instr_busy[0], 1);
        repeat (6) tick();
        check_eq("still waiting at sub-warp 3 while warp 0 is busy", sub_warp_cycle, 3);
        check_eq("sub_warp_valid", sub_warp_valid, 0);

        // 4-6. Each completion path releases the warp
        $display("\nTest 4: commit_done releases the warp");
        @(negedge clk);
        commit_done[0] = 1'b1;
        @(negedge clk);
        commit_done[0] = 1'b0;
        check_eq("instr_busy[0]", dut.instr_busy[0], 0);
        while (!consume) tick();
        $display("PASS | warp %0d issued again after commit_done", next_warp);
        tick();

        $display("\nTest 5: store_done releases the warp");
        repeat (6) tick();
        check_eq("instr_busy[0]", dut.instr_busy[0], 1);
        @(negedge clk);
        store_done[0] = 1'b1;
        @(negedge clk);
        store_done[0] = 1'b0;
        check_eq("instr_busy[0]", dut.instr_busy[0], 0);
        while (!consume) tick();
        tick();

        $display("\nTest 6: push2_done (branch resolved) releases the warp");
        repeat (6) tick();
        check_eq("instr_busy[0]", dut.instr_busy[0], 1);
        @(negedge clk);
        push2_done[0] = 1'b1;
        @(negedge clk);
        push2_done[0] = 1'b0;
        check_eq("instr_busy[0]", dut.instr_busy[0], 0);

        // 7. buffer_full freezes the counter and the scheduler's decision
        $display("\nTest 7: buffer_full stalls issue");
        do_reset();
        launch(3);
        while (sub_warp_cycle != 2'd1) tick();
        @(negedge clk);
        buffer_full = 1'b1;
        repeat (4) tick();
        check_eq("sub_warp_cycle frozen", sub_warp_cycle, 1);
        check_eq("sub_warp_valid", sub_warp_valid, 0);
        check_eq("curr_warp unchanged", curr_warp, 0);
        check_eq("issue_valid unchanged", issue_valid, 1);
        @(negedge clk);
        buffer_full = 1'b0;
        tick();
        check_eq("resumes at sub_warp_cycle", sub_warp_cycle, 2);

        // 8. done_detect finishes the current warp and moves on to the next ready warp
        $display("\nTest 8: done_detect retires the current warp");
        do_reset();
        launch(2);
        while (!consume) tick();
        tick();
        @(negedge clk);
        done_detect = 1'b1;   // warp 0's instruction was DONE
        #1;
        check_eq("ready_mask[curr_warp] cleared the same cycle", dut.ready_mask[curr_warp], 0);
        @(negedge clk);
        done_detect = 1'b0;
        check_eq("finished[0]", dut.finished[0], 1);
        while (!consume) tick();
        check_eq("next warp issued", next_warp, 1);

        // 9. kernel_done waits for the data cache flush
        $display("\nTest 9: kernel_done only after warps_done and flush_done");
        tick();
        @(negedge clk);
        done_detect = 1'b1;   // warp 1's instruction was DONE
        @(negedge clk);
        done_detect = 1'b0;
        check_eq("warps_done", warps_done, 1);
        check_eq("issue_valid", issue_valid, 0);
        repeat (5) tick();
        check_eq("kernel_done before flush_done", kernel_done, 0);
        @(negedge clk);
        flush_done = 1'b1;
        @(negedge clk);
        flush_done = 1'b0;
        check_eq("kernel_done after flush_done", kernel_done, 1);
        repeat (3) tick();
        check_eq("kernel_done stays high", kernel_done, 1);

        // 10. Full kernels against the program model, for several warp counts
        $display("\nTest 10: full kernels");
        for (int n = 1; n <= 8; n *= 2) begin
            do_reset();
            for (int w = 0; w < NUM_WARPS; w++)
                prog_len[w] = 3 + w;
            run_kernel(n[3:0], 2000);
            for (int w = 0; w < NUM_WARPS; w++)
                check_eq($sformatf("warp %0d instructions issued (incl. DONE)", w),
                         issued[w], (w < n) ? prog_len[w] + 1 : 0);
            check_eq("warps_done", warps_done, 1);
            check_eq("issue_valid", issue_valid, 0);
        end

        // 11. Back-to-back kernels: kernel_start clears the previous kernel's state
        $display("\nTest 11: second kernel after the first finished");
        foreach (issued[w]) issued[w] = 0;
        run_kernel(4'd3, 2000);
        for (int w = 0; w < 3; w++)
            check_eq($sformatf("warp %0d instructions issued (incl. DONE)", w), issued[w], prog_len[w] + 1);

        // 12. Launching zero warps finishes immediately after the flush
        $display("\nTest 12: num_warps = 0");
        do_reset();
        run_kernel(4'd0, 50);
        check_eq("no instruction issued", issued[0], 0);

        // 13. Latency hiding: with one warp, every instruction's commit latency stalls issue.
        //     With four warps, other warps issue while one waits, so issue never stalls
        //     while all four are still running
        $display("\nTest 13: warps interleave to hide commit latency");
        do_reset();
        foreach (prog_len[w]) prog_len[w] = 12;
        run_kernel(4'd1, 2000);
        $display("1 warp: %0d stalled issue gaps", stall_gaps);
        check_eq("single warp stalls on its own commit latency", stall_gaps > 0, 1);

        do_reset();
        foreach (prog_len[w]) prog_len[w] = 12;
        run_kernel(4'd4, 2000);
        $display("4 warps: %0d stalled issue gaps over %0d instructions", stall_gaps, issued_count);
        check_eq("no stalled issue gaps while all 4 warps are running", stall_gaps, 0);
        for (int w = 0; w < 4; w++)
            check_eq($sformatf("warp %0d instructions issued (incl. DONE)", w), issued[w], prog_len[w] + 1);

        if (errors == 0)
            $display("\nALL TESTS PASSED");
        else
            $fatal(1, "\n%0d TEST(S) FAILED", errors);

        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "FAIL | testbench timeout");
    end
endmodule
