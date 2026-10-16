`timescale 1ns/1ps
module instruction_latch_tb;
    logic clk, reset;
    logic consume;
    logic [1:0] sub_warp_cycle;
    logic [2:0] next_warp, curr_warp;
    logic [31:0] buf_instr, buf_instr_pc;

    logic [31:0] instr_q, instr_pc_q;
    logic [9:0] src1_addr, src2_addr, src3_addr;

    int errors;

    instruction_latch dut (
        .clk(clk), .reset(reset),
        .consume(consume),
        .sub_warp_cycle(sub_warp_cycle),
        .next_warp(next_warp),
        .curr_warp(curr_warp),
        .buf_instr(buf_instr),
        .buf_instr_pc(buf_instr_pc),
        .instr_q(instr_q),
        .instr_pc_q(instr_pc_q),
        .src1_addr(src1_addr),
        .src2_addr(src2_addr),
        .src3_addr(src3_addr)
    );

    always #5 clk = ~clk;

    task check_eq(input [63:0] actual, input [63:0] expected, string name);
        if (actual !== expected) begin
            $display("FAIL %s | expected %0d, got %0d", name, expected, actual);
            errors = errors + 1;
        end else begin
            $display("PASS %s", name);
        end
    endtask

    // drive one cycle's worth of inputs, advance clock, let outputs settle
    task run_cycle(
        input        t_consume,
        input [1:0]  t_sub_warp_cycle,
        input [2:0]  t_next_warp,
        input [2:0]  t_curr_warp,
        input [31:0] t_buf_instr,
        input [31:0] t_buf_instr_pc
    );
        consume        = t_consume;
        sub_warp_cycle = t_sub_warp_cycle;
        next_warp      = t_next_warp;
        curr_warp      = t_curr_warp;
        buf_instr      = t_buf_instr;
        buf_instr_pc   = t_buf_instr_pc;
        @(posedge clk);
        #1; // settle
    endtask

    initial begin
        errors = 0;
        clk = 1'b0;
        reset = 1'b1;
        consume = 1'b0;
        sub_warp_cycle = 2'b0;
        next_warp = 3'b0;
        curr_warp = 3'b0;
        buf_instr = 32'b0;
        buf_instr_pc = 32'b0;

        @(posedge clk); #1;
        @(posedge clk); #1;

        // 1. reset clears everything
        check_eq(instr_q, 32'b0, "reset: instr_q");
        check_eq(instr_pc_q, 32'b0, "reset: instr_pc_q");
        check_eq(src1_addr, 10'b0, "reset: src1_addr");
        check_eq(src2_addr, 10'b0, "reset: src2_addr");
        check_eq(src3_addr, 10'b0, "reset: src3_addr");

        reset = 1'b0;

        // 2. load cycle (consume = 1), sub_warp_cycle = 0, next_warp = 5
        // instr fields: [25:21]=src1=R1, [20:16]=src2=R2, [15:11]=src3=R3
        run_cycle(1'b1, 2'd0, 3'd5, 3'd2,
                  {6'b0, 5'd1, 5'd2, 5'd3, 11'b0}, 32'hAAAA_0000);

        // one cycle later: instr_q/instr_pc_q loaded, src_addr tagged with
        // next_warp=5, sub_warp_cycle=0 (both live during the load cycle)
        check_eq(instr_q, {6'b0, 5'd1, 5'd2, 5'd3, 11'b0}, "load: instr_q");
        check_eq(instr_pc_q, 32'hAAAA_0000, "load: instr_pc_q");
        check_eq(src1_addr, {3'd5, 2'd0, 5'd1}, "load: src1_addr (next_warp, cyc0, R1)");
        check_eq(src2_addr, {3'd5, 2'd0, 5'd2}, "load: src2_addr (next_warp, cyc0, R2)");
        check_eq(src3_addr, {3'd5, 2'd0, 5'd3}, "load: src3_addr (next_warp, cyc0, R3)");

        // 3. sub_warp_cycle = 1, curr_warp = 5, consume = 0
        // curr_warp is now 5 (updated to warp_scheduler after cycle 0)
        run_cycle(1'b0, 2'd1, 3'd0, 3'd5,
                  32'hFFFF_FFFF, 32'hFFFF_FFFF); // buf_instr - must be ignored on hold

        check_eq(instr_q, {6'b0, 5'd1, 5'd2, 5'd3, 11'b0}, "hold1: instr_q unchanged");
        check_eq(instr_pc_q, 32'hAAAA_0000, "instr_pc_q unchanged (cycle 1)");
        check_eq(src1_addr, {3'd5, 2'd1, 5'd1}, "src1_addr (curr_warp, cycle 1, R1)");
        check_eq(src2_addr, {3'd5, 2'd1, 5'd2}, "src2_addr (curr_warp, cycle 1, R2)");
        check_eq(src3_addr, {3'd5, 2'd1, 5'd3}, "src3_addr (curr_warp, cycle 1, R3)");

        // 4. sub_warp_cycle = 2
        run_cycle(1'b0, 2'd2, 3'd0, 3'd5, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        check_eq(instr_q, {6'b0, 5'd1, 5'd2, 5'd3, 11'b0}, "hold2: instr_q still unchanged");
        check_eq(src1_addr, {3'd5, 2'd2, 5'd1}, "src1_addr (curr_warp, cycle 2, R1)");
        check_eq(src2_addr, {3'd5, 2'd2, 5'd2}, "src2_addr (curr_warp, cycle 2, R2)");
        check_eq(src3_addr, {3'd5, 2'd2, 5'd3}, "src3_addr (curr_warp, cycle 2, R3)");

        // 5. sub_warp_cycle = 3
        run_cycle(1'b0, 2'd3, 3'd0, 3'd5, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        check_eq(instr_pc_q, 32'hAAAA_0000, "hold3: instr_pc_q still unchanged");
        check_eq(src1_addr, {3'd5, 2'd3, 5'd1}, "src1_addr (curr_warp, cycle 3, R1)");
        check_eq(src2_addr, {3'd5, 2'd3, 5'd2}, "src2_addr (curr_warp, cycle 3, R2)");
        check_eq(src3_addr, {3'd5, 2'd3, 5'd3}, "src3_addr (curr_warp, cycle 3, R3)");

        // 6. new warp/instr, sub_warp_cycle wraps to 0
        run_cycle(1'b1, 2'd0, 3'd7, 3'd5,
                  {6'b0, 5'd10, 5'd11, 5'd12, 11'b0}, 32'hBBBB_1000);
        check_eq(instr_q, {6'b0, 5'd10, 5'd11, 5'd12, 11'b0}, "new warp: instr_q updates");
        check_eq(instr_pc_q, 32'hBBBB_1000, "new warp: instr_pc_q updates");
        check_eq(src1_addr, {3'd7, 2'd0, 5'd10}, "new warp: src1_addr (next_warp=7, cyc0, R10)");
        check_eq(src2_addr, {3'd7, 2'd0, 5'd11}, "new warp: src2_addr (next_warp=7, cyc0, R11)");
        check_eq(src3_addr, {3'd7, 2'd0, 5'd12}, "new warp: src3_addr (next_warp=7, cyc0, R12)");

        // 7. test edge warp values (0 and 7)
        run_cycle(1'b1, 2'd0, 3'd0, 3'd0,
                  {6'b0, 5'd31, 5'd0, 5'd16, 11'b0}, 32'h0);
        check_eq(src1_addr, {3'd0, 2'd0, 5'd31}, "warp0: src1_addr max reg num");
        check_eq(src2_addr, {3'd0, 2'd0, 5'd0}, "warp0: src2_addr R0");
        check_eq(src3_addr, {3'd0, 2'd0, 5'd16}, "warp0: src3_addr mid reg num");

        if (errors == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "%0d TEST(S) FAILED", errors);

        $finish;
    end
endmodule
