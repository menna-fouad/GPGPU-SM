`timescale 1ns/1ps
module decode_stage_tb;
    logic clk, reset;
    logic buffer_full;
    logic sub_warp_valid;
    logic [1:0] sub_warp_cycle;
    logic [2:0] curr_warp;
    logic [31:0] active_mask;
    logic [31:0] instr, instr_pc;

    logic sub_warp_valid_q;
    logic [1:0] sub_warp_cycle_q;
    logic [5:0] opcode_q;
    logic done_detect;
    logic [7:0] alu_valid_q, fma_valid_q, special_reg_valid_q;
    logic [9:0] dest_addr_q;
    logic [15:0] imm_q;
    logic [31:0] instr_pc_q;

    int errors;

    decode_stage dut (
        .clk(clk),
        .reset(reset),
        .buffer_full(buffer_full),
        .sub_warp_valid(sub_warp_valid),
        .sub_warp_cycle(sub_warp_cycle),
        .curr_warp(curr_warp),
        .active_mask(active_mask),
        .instr(instr), .instr_pc(instr_pc),
        .sub_warp_valid_q(sub_warp_valid_q),
        .sub_warp_cycle_q(sub_warp_cycle_q),
        .opcode_q(opcode_q),
        .done_detect(done_detect),
        .alu_valid_q(alu_valid_q),
        .fma_valid_q(fma_valid_q),
        .special_reg_valid_q(special_reg_valid_q),
        .dest_addr_q(dest_addr_q),
        .imm_q(imm_q),
        .instr_pc_q(instr_pc_q)
    );

    always #5 clk = ~clk;

    // format/suboptype locals, matching the ISA table
    localparam [2:0] R_TYPE = 3'b000, I_TYPE = 3'b001, FMA = 3'b010, BRANCH = 3'b011, SPECIAL = 3'b100;

    task check_eq(input [63:0] actual, input [63:0] expected, string name);
        if (actual !== expected) begin
            $display("FAIL %s | expected %0d, got %0d", name, expected, actual);
            errors = errors + 1;
        end else begin
            $display("PASS %s | ", name);
        end
    endtask

    // decode registers sub_warp_cycle/valid internally and uses them one cycle later,
    // when the instruction latch presents the instruction for that sub-warp.
    // Drive the sub-warp count first, then the instruction, then check registered outputs
    task run_cycle(
        input [31:0] t_instr,
        input [31:0] t_instr_pc,
        input [2:0]  t_curr_warp,
        input [1:0]  t_sub_warp_cycle,
        input        t_sub_warp_valid,
        input [31:0] t_active_mask
    );
        @(negedge clk);
        sub_warp_cycle  = t_sub_warp_cycle;
        sub_warp_valid  = t_sub_warp_valid;
        @(negedge clk);
        instr           = t_instr;
        instr_pc        = t_instr_pc;
        curr_warp       = t_curr_warp;
        active_mask     = t_active_mask;
        @(posedge clk);
        #1; // settle
    endtask

    initial begin
        errors = 0;
        clk = 1'b0;
        reset = 1'b1;
        buffer_full = 1'b0;
        sub_warp_valid = 1'b0;
        sub_warp_cycle = 2'b0;
        curr_warp = 3'b0;
        active_mask = 32'b0;
        instr = 32'b0;
        instr_pc = 32'b0;

        @(posedge clk); #1;
        @(posedge clk); #1;

        // 1. reset clears all registered outputs
        check_eq(sub_warp_valid_q, 1'b0, "reset: sub_warp_valid_q");
        check_eq(sub_warp_cycle_q, 2'b0, "reset: sub_warp_cycle_q");
        check_eq(opcode_q, 6'b0, "reset: opcode_q");
        check_eq(alu_valid_q, 8'b0, "reset: alu_valid_q");
        check_eq(fma_valid_q, 8'b0, "reset: fma_valid_q");
        check_eq(special_reg_valid_q, 8'b0, "reset: special_reg_valid_q");
        check_eq(dest_addr_q, 10'b0, "reset: dest_addr_q");
        check_eq(imm_q, 16'b0, "reset: imm_q");
        check_eq(instr_pc_q, 32'b0, "reset: instr_pc_q");

        reset = 0;

        // 2. R_TYPE (ADD), sub_warp_cycle = 0, warp = 3, dst = R7
        // instr[31:29] = R_TYPE(000) [28:26] = ADD(001) [25:21] = dst(7)
        // [20:16] = src1(1) [15:11]=src2(2)
        run_cycle({R_TYPE, 3'b001, 5'd1, 5'd2, 5'd7, 11'b0}, 32'h100,
                    3'd3, 2'd0, 1'b1, 32'hFFFF_FFFF);
        check_eq(sub_warp_valid_q, 1'b1, "R_TYPE: sub_warp_valid_q");
        check_eq(sub_warp_cycle_q, 2'd0, "R_TYPE: sub_warp_cycle_q");
        check_eq(opcode_q, {R_TYPE, 3'b001}, "R_TYPE: opcode_q");
        check_eq(alu_valid_q, 8'hFF, "R_TYPE: alu_valid_q (mask slice 0, all active)");
        check_eq(fma_valid_q, 8'h00, "R_TYPE: fma_valid_q");
        check_eq(special_reg_valid_q, 8'h00, "R_TYPE: special_reg_valid_q");
        check_eq(dest_addr_q, {3'd3, 2'd0, 5'd7}, "R_TYPE: dest_addr_q (dst=R15:11)");
        check_eq(instr_pc_q, 32'h100, "R_TYPE: instr_pc_q");

        // 3. I_TYPE, dst at [20:16], sub_warp_cycle=2, partial mask
        // active_mask byte for cycle 2 = active_mask[23:16]
        run_cycle({I_TYPE, 3'b001, 5'd0, 5'd12, 16'hABCD}, 32'h200,
                   3'd5, 2'd2, 1'b1, {8'hAA, 8'h55, 8'h0F, 8'h00});
        check_eq(opcode_q, {I_TYPE, 3'b001}, "I_TYPE: opcode_q");
        check_eq(alu_valid_q, 8'h55, "I_TYPE: alu_valid_q (mask slice = bits[23:16]=0x55)");
        check_eq(fma_valid_q, 8'h00, "I_TYPE: fma_valid_q");
        check_eq(special_reg_valid_q, 8'h00, "I_TYPE: special_reg_valid_q");
        check_eq(dest_addr_q, {3'd5, 2'd2, 5'd12}, "I_TYPE: dest_addr_q (dst=[20:16])");
        check_eq(imm_q, 16'hABCD, "I_TYPE: imm_q (low 16 bits)");

        // 4. FMA, dst at [10:6], sub_warp_cycle = 3
        run_cycle({FMA, 3'b000, 5'd1, 5'd2, 5'd3, 5'd9, 6'b0}, 32'h300,
                   3'd0, 2'd3, 1'b1, {8'h33, 8'h00, 8'h00, 8'h00});
        check_eq(fma_valid_q, 8'h33, "FMA: fma_valid_q (mask slice = bits[31:24]=0x33)");
        check_eq(alu_valid_q, 8'h00, "FMA: alu_valid_q should stay 0");
        check_eq(special_reg_valid_q, 8'h00, "FMA: special_reg_valid_q should stay 0");
        check_eq(dest_addr_q, {3'd0, 2'd3, 5'd9}, "FMA: dest_addr_q (dst=[10:6])");

        // 5. SPECIAL, dst at [25:21]
        run_cycle({SPECIAL, 3'b000, 5'd20, 21'b0}, 32'h400,
                    3'd7, 2'd1, 1'b1, {8'h00, 8'h00, 8'hCC, 8'h00});
        check_eq(special_reg_valid_q, 8'hCC, "SPECIAL: special_reg_valid_q (mask slice=bits[15:8])");
        check_eq(alu_valid_q, 8'h00, "SPECIAL: alu_valid_q should stay 0");
        check_eq(fma_valid_q, 8'h00, "SPECIAL: fma_valid_q should stay 0");
        check_eq(dest_addr_q, {3'd7, 2'd1, 5'd20}, "SPECIAL: dest_addr_q (dst=[25:21])");

        // 6. BRANCH, dst forced 0, alu_valid asserted
        run_cycle({BRANCH, 3'b000, 5'd11, 5'd22, 16'b0}, 32'h500,
                   3'd2, 2'd0, 1'b1, 32'hFFFF_FFFF);
        check_eq(alu_valid_q, 8'hFF, "BRANCH: alu_valid_q asserted");
        check_eq(fma_valid_q, 8'h00, "BRANCH: fma_valid_q stays 0");
        check_eq(special_reg_valid_q, 8'h00, "BRANCH: special_reg_valid_q stays 0");
        check_eq(dest_addr_q, {3'd2, 2'd0, 5'd0}, "BRANCH: dest_addr_q dst forced to 0");

        // 7. sub_warp_valid = 0 still registers
        run_cycle({R_TYPE, 3'b001, 5'd4, 10'b0}, 32'h600,
                   3'd1, 2'd1, 1'b0, 32'hFFFF_FFFF);
        check_eq(sub_warp_valid_q, 1'b0, "held cycle: sub_warp_valid_q forwards 0");
        check_eq(sub_warp_cycle_q, 2'd1, "held cycle: sub_warp_cycle_q still forwards the cycle");
        check_eq(alu_valid_q, 8'h00, "held cycle: no lane valid");

        // 8. mask slicing at all 4 byte boundaries in one instruction type ----
        // confirms curr_active_mask indexing (sub_warp_cycle*8 +: 8) picks the right byte
        run_cycle({R_TYPE, 3'b001, 5'd1, 10'b0}, 32'h700, 3'd0, 2'd0, 1'b1,
                   {8'hD4, 8'hC3, 8'hB2, 8'hA1});
        check_eq(alu_valid_q, 8'hA1, "mask byte 0 (bits[7:0])");
        run_cycle({R_TYPE, 3'b001, 5'd1, 10'b0}, 32'h700, 3'd0, 2'd1, 1'b1,
                   {8'hD4, 8'hC3, 8'hB2, 8'hA1});
        check_eq(alu_valid_q, 8'hB2, "mask byte 1 (bits[15:8])");
        run_cycle({R_TYPE, 3'b001, 5'd1, 10'b0}, 32'h700, 3'd0, 2'd2, 1'b1,
                   {8'hD4, 8'hC3, 8'hB2, 8'hA1});
        check_eq(alu_valid_q, 8'hC3, "mask byte 2 (bits[23:16])");
        run_cycle({R_TYPE, 3'b001, 5'd1, 10'b0}, 32'h700, 3'd0, 2'd3, 1'b1,
                   {8'hD4, 8'hC3, 8'hB2, 8'hA1});
        check_eq(alu_valid_q, 8'hD4, "mask byte 3 (bits[31:24])");

        // 9. DONE is detected on sub-warp 0 only, and only when valid
        // done_detect is combinational on the instruction and the delayed sub-warp count
        run_cycle(32'hFC00_0000, 32'h800, 3'd4, 2'd0, 1'b1, 32'hFFFF_FFFF);
        check_eq(done_detect, 1'b1, "DONE at sub-warp 0: done_detect");
        check_eq(alu_valid_q | fma_valid_q | special_reg_valid_q, 8'h00, "DONE: no execution unit valid");
        sub_warp_cycle = 2'd1;
        @(posedge clk); #1;
        check_eq(done_detect, 1'b0, "DONE at sub-warp 1: no done_detect");
        sub_warp_cycle = 2'd0; sub_warp_valid = 1'b0;
        @(posedge clk); #1;
        check_eq(done_detect, 1'b0, "DONE with invalid sub-warp: no done_detect");

        // 10. Pipeline-style stream: one FMA held for four sub-warps while the counter advances.
        // Each sub-warp must get its own dest_addr sub-warp field and mask byte
        @(negedge clk);
        sub_warp_cycle = 2'd0; sub_warp_valid = 1'b1;
        @(negedge clk);
        instr = {FMA, 3'b000, 5'd1, 5'd2, 5'd3, 5'd17, 6'b0};
        instr_pc = 32'h900;
        curr_warp = 3'd6;
        active_mask = {8'h80, 8'h40, 8'h20, 8'h10};
        for (int sw = 0; sw < 4; sw++) begin
            sub_warp_cycle = 2'(sw + 1);
            sub_warp_valid = (sw < 3);
            @(posedge clk); #1;
            check_eq(dest_addr_q, {3'd6, 2'(sw), 5'd17}, $sformatf("stream: dest_addr_q sub-warp %0d", sw));
            check_eq(fma_valid_q, 8'h10 << sw, $sformatf("stream: fma_valid_q sub-warp %0d", sw));
            check_eq(sub_warp_cycle_q, sw, $sformatf("stream: sub_warp_cycle_q sub-warp %0d", sw));
            @(negedge clk);
        end

        // 11. buffer_full holds every registered output and the delayed sub-warp count
        run_cycle({R_TYPE, 3'b001, 5'd1, 5'd2, 5'd5, 11'b0}, 32'hA00, 3'd1, 2'd2, 1'b1, 32'h00FF_0000);
        check_eq(dest_addr_q, {3'd1, 2'd2, 5'd5}, "before stall: dest_addr_q");
        @(negedge clk);
        buffer_full = 1'b1;
        instr = {I_TYPE, 3'b001, 5'd0, 5'd9, 16'h1234};
        curr_warp = 3'd3;
        sub_warp_cycle = 2'd3;
        repeat (3) @(posedge clk);
        #1;
        check_eq(dest_addr_q, {3'd1, 2'd2, 5'd5}, "stalled: dest_addr_q held");
        check_eq(alu_valid_q, 8'hFF, "stalled: alu_valid_q held");
        check_eq(opcode_q, {R_TYPE, 3'b001}, "stalled: opcode_q held");
        check_eq(dut.sub_warp_cycle_prev, 2'd2, "stalled: delayed sub-warp count held");
        @(negedge clk);
        buffer_full = 1'b0;
        @(posedge clk); #1;
        check_eq(dest_addr_q, {3'd3, 2'd2, 5'd9}, "released: decodes the held sub-warp with the new instruction");

        if (errors == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "%0d TEST(S) FAILED", errors);

        $finish;
    end
endmodule
