`timescale 1ns/1ps
module l1_i_cache_stub #(
    parameter int MEM_WORDS = 8192,
    parameter int LATENCY   = 2
) (
    input logic clk,
    input logic reset,
    input logic req_valid,
    input logic [31:0] addr,
    output logic ready,
    output logic [127:0] data
);
    logic [31:0] mem [0:MEM_WORDS-1];

    logic pending;
    logic [31:0] req_addr_q;
    logic [7:0] cnt;

    initial begin
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'hFFFF_FFFF; // erased-memory pattern == DONE
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pending <= 1'b0;
            ready <= 1'b0;
            req_addr_q <= 32'b0;
            cnt <= 8'b0;
        end else begin
            ready <= 1'b0;
            if (!pending) begin
                if (req_valid) begin
                    req_addr_q <= addr;
                    if (LATENCY <= 1) begin
                        ready <= 1'b1;             // pulses next cycle
                    end else begin
                        pending <= 1'b1;
                        cnt <= LATENCY[7:0] - 8'd2;
                    end
                end
            end else begin
                if (cnt == 8'd0) begin
                    ready <= 1'b1;
                    pending <= 1'b0;
                end else begin
                    cnt <= cnt - 8'd1;
                end
            end
        end
    end

    // combinational burst read off the latched request address; word 0 at [31:0]
    logic [12:0] base;
    assign base = req_addr_q[14:2];
    assign data = { mem[base + 13'd3], mem[base + 13'd2], mem[base + 13'd1], mem[base] };
endmodule

module tb_frontend_integration;
    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;
    task check(input logic cond, input string msg);
        begin
            checks = checks + 1;
            if (cond) $display("[PASS] t=%0t: %s", $time, msg);
            else begin
                $display("[FAIL] t=%0t: %s", $time, msg);
                errors = errors + 1;
            end
        end
    endtask

    // instruction encodings
    localparam [5:0] OP_ADD = 6'b000001; // R-type instruction
    localparam [5:0] OP_ADDI = 6'b001001; // I-type instruction
    localparam [5:0] OP_FMA = 6'b010000; // FMA instruction
    localparam [5:0] OP_MOV_TID = 6'b100000; // SPECIAL (move) instruction
    localparam [5:0] OP_BEQ = 6'b011000; // Branch instruction

    // R-type: [31:26]=opcode, [25:21]=src1, [20:16]=src2, [15:11]=dst, [10:0]=unused
    function [31:0] r_type(input [5:0] opc, input [4:0] s1, s2, d);
        r_type = {opc, s1, s2, d, 11'b0};
    endfunction

    // I-type: [31:26]=opcode, [25:21]=base/src1, [20:16]=dst/src2-slot, [15:0]=imm
    function [31:0] i_type(input [5:0] opc, input [4:0] s1, s2, input [15:0] imm);
        i_type = {opc, s1, s2, imm};
    endfunction

    // FMA: [31:26]=opcode, [25:21]=src1, [20:16]=src2, [15:11]=src3, [10:6]=dst, [5:0]=unused
    function [31:0] fma_type(input [5:0] opc, input [4:0] s1, s2, s3, d);
        fma_type = {opc, s1, s2, s3, d, 6'b0};
    endfunction

    // Special (MOV_TID/WID/BID): [31:26]=opcode, [25:21]=dst, rest unused
    function [31:0] special_type(input [5:0] opc, input [4:0] d);
        special_type = {opc, d, 21'b0};
    endfunction

    // R-type: [31:26]=opcode, [25:21]=src1, [20:16]=src2, [15:6]=pc target offset, [5:0]=recon pc offset
    function [31:0] branch_instr(input [5:0] opc, input [4:0] s1, s2, input [9:0] toff, input [5:0] roff);
        branch_instr = {opc, s1, s2, toff, roff};
    endfunction

    // top-level launch controls
    logic kernel_start_r;
    logic [2:0] num_warps_r;
    logic [31:0] start_pc_r;
    logic tb_buffer_full;

    logic [2:0] ws_curr_warp, ws_next_warp;
    logic ws_issue_valid, ws_kernel_done;

    logic commit_done_auto;
    logic [2:0] commit_warp_auto;

    logic swc_valid;
    logic [1:0] swc_cycle;
    logic consume_sig;
    assign consume_sig = (swc_cycle == 2'd0) && swc_valid && !tb_buffer_full;

    logic dec_done_detect;

    logic [7:0]  recon_push2_done_arr;

    warp_scheduler u_ws (
        .clk(clk),
        .reset(reset),
        .kernel_start(kernel_start_r),
        .num_warps(num_warps_r),
        .commit_done(commit_done_auto),
        .commit_warp_id(commit_warp_auto),
        .push2_done(recon_push2_done_arr),
        .sub_warp_cycle(swc_cycle),
        .sub_warp_valid(swc_valid),
        .buffer_full(tb_buffer_full),
        .done_detect(dec_done_detect),
        .curr_warp(ws_curr_warp),
        .next_warp(ws_next_warp),
        .issue_valid(ws_issue_valid),
        .kernel_done(ws_kernel_done)
    );

    // recon_stack x8
    logic [31:0] top_pc_arr        [0:7];
    logic [31:0] top_recon_pc_arr  [0:7];
    logic [31:0] top_mask_arr      [0:7];
    logic [31:0] init_recon_pc_arr [0:7];
    logic [7:0]  tb_push2_valid;
    logic [31:0] tb_push2_mask_taken     [0:7];
    logic [31:0] tb_push2_mask_not_taken [0:7];
    logic [31:0] tb_push2_pc_taken       [0:7];
    logic [31:0] tb_push2_pc_fallthrough [0:7];
    logic [31:0] tb_push2_recon_pc       [0:7];
    logic [31:0] init_mask_arr           [0:7];

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_recon
            recon_stack #(.DEPTH(8)) u_recon (
                .clk(clk), .reset(reset),
                .init_push(kernel_start_r && (gi < num_warps_r)),
                .init_mask(init_mask_arr[gi]),
                .init_pc(start_pc_r),
                .init_recon_pc(init_recon_pc_arr[gi]),
                .push2_valid(tb_push2_valid[gi]),
                .push2_mask_taken(tb_push2_mask_taken[gi]),
                .push2_mask_not_taken(tb_push2_mask_not_taken[gi]),
                .push2_pc_taken(tb_push2_pc_taken[gi]),
                .push2_pc_fallthrough(tb_push2_pc_fallthrough[gi]),
                .push2_recon_pc(tb_push2_recon_pc[gi]),
                .current_pc_valid(1'b0),
                .current_pc(32'b0),
                .top_mask(top_mask_arr[gi]),
                .top_pc(top_pc_arr[gi]),
                .top_recon_pc(top_recon_pc_arr[gi]),
                .stack_empty(),
                .stack_full(),
                .push2_done(recon_push2_done_arr[gi])
            );
        end
    endgenerate

    // icache stub
    logic ic_req_valid, ic_ready;
    logic [31:0] ic_addr;
    logic [127:0] ic_data;

    l1_i_cache_stub #(.LATENCY(2)) u_icache (
        .clk(clk),
        .reset(reset),
        .req_valid(ic_req_valid),
        .addr(ic_addr),
        .ready(ic_ready),
        .data(ic_data)
    );

    // fetch_stage (+prefetch_buffer)
    logic fs_fetch_valid;
    logic [31:0] fs_instr, fs_instr_pc;

    fetch_stage u_fetch (
        .clk(clk),
        .reset(reset),
        .kernel_launch(kernel_start_r),
        .next_warp(ws_next_warp),
        .top_pc(top_pc_arr[ws_next_warp]),
        .recon_pc(top_recon_pc_arr[ws_next_warp]),
        .consume(consume_sig),
        .icache_ready(ic_ready),
        .icache_data(ic_data),
        .icache_req_valid(ic_req_valid),
        .icache_addr(ic_addr),
        .fetch_valid(fs_fetch_valid),
        .instr(fs_instr),
        .instr_pc(fs_instr_pc)
    );

    // sub_warp_counter
    sub_warp_counter u_swc (
        .clk(clk), .reset(reset),
        .fetch_valid(fs_fetch_valid),
        .buffer_full(tb_buffer_full),
        .sub_warp_cycle(swc_cycle),
        .sub_warp_valid(swc_valid)
    );

    // instruction_latch
    logic [31:0] il_instr_q, il_instr_pc_q;
    logic [9:0] il_src1_addr, il_src2_addr, il_src3_addr;

    instruction_latch u_ilatch (
        .clk(clk),
        .reset(reset),
        .consume(consume_sig),
        .buffer_full(tb_buffer_full),
        .sub_warp_cycle(swc_cycle),
        .next_warp(ws_next_warp),
        .curr_warp(ws_curr_warp),
        .buf_instr(fs_instr),
        .buf_instr_pc(fs_instr_pc),
        .instr_q(il_instr_q),
        .instr_pc_q(il_instr_pc_q),
        .src1_addr(il_src1_addr),
        .src2_addr(il_src2_addr),
        .src3_addr(il_src3_addr)
    );

    // decode_stage
    logic dec_sub_warp_valid_q;
    logic [1:0] dec_sub_warp_cycle_q;
    logic [5:0] dec_opcode_q;
    logic [7:0] dec_alu_valid_q, dec_fma_valid_q, dec_special_reg_valid_q;
    logic [9:0] dec_dest_addr_q;
    logic [15:0] dec_imm_q;
    logic [31:0] dec_instr_pc_q;

    decode_stage u_decode (
        .clk(clk),
        .reset(reset),
        .buffer_full(tb_buffer_full),
        .sub_warp_valid(swc_valid),
        .sub_warp_cycle(swc_cycle),
        .curr_warp(ws_curr_warp),
        .active_mask(top_mask_arr[ws_curr_warp]),
        .instr(il_instr_q),
        .instr_pc(il_instr_pc_q),
        .sub_warp_valid_q(dec_sub_warp_valid_q),
        .sub_warp_cycle_q(dec_sub_warp_cycle_q),
        .opcode_q(dec_opcode_q),
        .done_detect(dec_done_detect),
        .alu_valid_q(dec_alu_valid_q),
        .fma_valid_q(dec_fma_valid_q),
        .special_reg_valid_q(dec_special_reg_valid_q),
        .dest_addr_q(dec_dest_addr_q),
        .imm_q(dec_imm_q),
        .instr_pc_q(dec_instr_pc_q)
    );

    // auto-commit stand-in for commit_tracker & writeback_arbiter
    // 1 cycle after a non-branch instruction's last sub-group decodes, pulse commit_done
    // push2_done is also testbench-driven (tb_push2_done) rather than real.
    wire is_branch_decode = (dec_opcode_q[5:3] == 3'b011);
    logic auto_commit_enable = 1'b1;
    always_ff @(posedge clk) begin
        if (reset) begin
            commit_done_auto <= 1'b0;
            commit_warp_auto <= 3'b0;
        end else begin
            commit_done_auto <= auto_commit_enable && dec_sub_warp_valid_q && (dec_sub_warp_cycle_q == 2'd3) && !is_branch_decode;
            commit_warp_auto <= dec_dest_addr_q[9:7];
        end
    end

    // reg_file (single instance, "lane 0 by convention")
    logic [31:0] reg_src1_data, reg_src2_data, reg_src3_data;

    reg_file u_regfile (
        .clk(clk),
        .reset(reset),
        .src1_addr(il_src1_addr),
        .src2_addr(il_src2_addr),
        .src3_addr(il_src3_addr),
        .write_en(1'b0),
        .wr_addr(10'b0),
        .wr_data(32'b0),
        .src1_data(reg_src1_data),
        .src2_data(reg_src2_data),
        .src3_data(reg_src3_data)
    );

    task poke_reg(input [2:0] warp, input [1:0] subcyc, input [4:0] regnum, input [31:0] v);
        begin
            u_regfile.bram1[{warp, subcyc, regnum}] = v;
            u_regfile.bram2[{warp, subcyc, regnum}] = v;
            u_regfile.bram3[{warp, subcyc, regnum}] = v;
        end
    endtask

    task load_word(input [31:0] addr, input [31:0] w);
        u_icache.mem[addr[14:2]] = w;
    endtask

    // second, independent fetch_stage/icache pair, for scenario 9
    logic ic2_req_valid, ic2_ready;
    logic [31:0] ic2_addr;
    logic [127:0] ic2_data;
    logic fs2_fetch_valid;
    logic [31:0] fs2_instr, fs2_instr_pc;
    logic fs2_kernel_launch, fs2_consume;
    logic [2:0] fs2_next_warp;
    logic [31:0] fs2_top_pc, fs2_recon_pc;

    l1_i_cache_stub #(.LATENCY(1)) u_icache_fast (
        .clk(clk), .reset(reset),
        .req_valid(ic2_req_valid),
        .addr(ic2_addr),
        .ready(ic2_ready),
        .data(ic2_data)
    );

    fetch_stage u_fetch_fast (
        .clk(clk),
        .reset(reset),
        .kernel_launch(fs2_kernel_launch),
        .next_warp(fs2_next_warp),
        .top_pc(fs2_top_pc),
        .recon_pc(fs2_recon_pc),
        .consume(fs2_consume),
        .icache_ready(ic2_ready),
        .icache_data(ic2_data),
        .icache_req_valid(ic2_req_valid),
        .icache_addr(ic2_addr),
        .fetch_valid(fs2_fetch_valid),
        .instr(fs2_instr),
        .instr_pc(fs2_instr_pc)
    );

    task load_word_fast(input [31:0] addr, input [31:0] w);
        u_icache_fast.mem[addr[14:2]] = w;
    endtask

    // helpers
    integer tick_i;
    task tick(input integer n);
        begin
            for (tick_i = 0; tick_i < n; tick_i = tick_i + 1) begin
                @(posedge clk);
                #1;
                kernel_start_r = 1'b0;
            end
        end
    endtask

    integer reset_i;
    task do_reset;
        begin
            reset = 1'b1;
            tb_buffer_full = 1'b0;
            kernel_start_r = 1'b0;
            num_warps_r = 3'd0;
            start_pc_r = 32'b0;
            tb_push2_valid = 8'b0;
            for (reset_i = 0; reset_i < 8; reset_i = reset_i + 1) begin
                init_recon_pc_arr[reset_i] = 32'hFFFFFFFF;
                init_mask_arr[reset_i] = 32'hFFFFFFFF;
                tb_push2_mask_taken[reset_i] = 32'b0;
                tb_push2_mask_not_taken[reset_i] = 32'b0;
                tb_push2_pc_taken[reset_i] = 32'b0;
                tb_push2_pc_fallthrough[reset_i] = 32'b0;
                tb_push2_recon_pc[reset_i] = 32'b0;
            end
            fs2_next_warp = 3'd0;
            fs2_top_pc = 32'b0;
            fs2_recon_pc = 32'hFFFF_FFFF;
            fs2_consume = 1'b0;
            fs2_kernel_launch = 1'b0;
            tick(3);
            reset = 1'b0;
            tick(2);
        end
    endtask

    task launch_kernel(input integer nwarps, input [31:0] spc);
        begin
            num_warps_r = nwarps[2:0];
            start_pc_r  = spc;
            kernel_start_r = 1'b1;
            tick(1);
        end
    endtask

    function fetch_buffer_all_invalid;
        fetch_buffer_all_invalid = (u_fetch.buffer.valid[0] == 1'b0) &&
                                    (u_fetch.buffer.valid[1] == 1'b0) &&
                                    (u_fetch.buffer.valid[2] == 1'b0) &&
                                    (u_fetch.buffer.valid[3] == 1'b0);
    endfunction

    // scratch vars, reused across scenarios
    integer c;
    integer seen_cycle1;
    integer held_cycles;
    logic [1:0] cyc_before_hold;
    logic seen_warp0, seen_warp1;
    integer consumed;
    logic [31:0] consumed_pc0, consumed_pc1;
    integer filled;
    logic seen_done_detect;
    logic saw_spurious_valid;
    logic seen_itype, itype_ok;
    logic seen_fma, fma_ok;
    logic seen_spec, spec_ok;
    logic seen_branch, branch_ok;
    logic seen_masked_cycle;
    integer filled3, drained, refilled;
    integer redirect_fired;
    integer saw_stale, saw_target;
    logic [2:0] exp_warp;
    logic [1:0] exp_cyc;
    logic       exp_vld;
    logic       saw0, saw1;

    // Scenario 1: tag alignment -- warp0's first instruction, ADD R1,R2,R3.
    task scenario1_tag_alignment;
        begin
            $display("\nScenario 1: tag alignment");
            do_reset();
            load_word(32'h0000_1000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_1004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_1008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_100C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            poke_reg(3'd0, 2'd0, 5'd2, 32'hCAFE_0000);
            poke_reg(3'd0, 2'd1, 5'd2, 32'hCAFE_0001);
    
            launch_kernel(1, 32'h0000_1000);
    
            saw0 = 1'b0;
            saw1 = 1'b0;
            for (c = 0; c < 40 && !(saw0 && saw1); c = c + 1) begin
                tick(1);
                if (dec_sub_warp_valid_q && dec_dest_addr_q[9:7] == 3'd0 && dec_alu_valid_q != 8'b0) begin
                    if (dec_sub_warp_cycle_q == 2'd0 && !saw0) begin
                        saw0 = 1'b1;
                        check(reg_src1_data == 32'hCAFE_0000,
                            $sformatf("scenario1: src1_data matches poke on {warp0,cyc0} decode cycle (got %h)", reg_src1_data));
                        check(dec_dest_addr_q == {3'd0, 2'd0, 5'd1},
                            $sformatf("scenario1: dest_addr_q == {warp0,cyc0,R1} (got %b)", dec_dest_addr_q));
                    end
                    if (dec_sub_warp_cycle_q == 2'd1 && !saw1) begin
                        saw1 = 1'b1;
                        check(reg_src1_data == 32'hCAFE_0001,
                            $sformatf("scenario1: src1_data matches poke on {warp0,cyc1} decode cycle (got %h)", reg_src1_data));
                        check(dec_dest_addr_q == {3'd0, 2'd1, 5'd1},
                            $sformatf("scenario1: dest_addr_q == {warp0,cyc1,R1} (got %b)", dec_dest_addr_q));
                    end
                end
            end
            check(saw0, "scenario1: observed a {warp0,cyc0} decode cycle (guard: check actually ran)");
            check(saw1, "scenario1: observed a {warp0,cyc1} decode cycle (guard: check actually ran)");
        end
    endtask

    // Scenario 2: buffer_full mid-span hold
    task scenario2_buffer_full_hold;
    logic [31:0] held_instr, held_pc;
    logic [9:0] held_src1, held_src2, held_src3;

    logic [1:0] held_dec_cycle;
    logic held_dec_valid;
    logic [9:0] held_dec_dest;
    logic [7:0] held_dec_alu_valid;

    logic [31:0] held_buf_instr, held_buf_pc;
    logic [31:0] target_pc;

    int expected_cycle;
    int observed_count;
    bit sequence_error;

    begin
        $display("\nScenario 2: buffer_full mid-instruction stall");

        do_reset();

        target_pc = 32'h0000_2000;

        load_word(32'h0000_2000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
        load_word(32'h0000_2004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
        load_word(32'h0000_2008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
        load_word(32'h0000_200C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));

        launch_kernel(1, target_pc);

        // Wait until sub-warp 0 of the first instruction reaches decode.
        seen_cycle1 = 0;

        for (c = 0; c < 30 && !seen_cycle1; c++) begin
            tick(1);

            if (dec_sub_warp_valid_q &&
                dec_instr_pc_q == target_pc &&
                dec_sub_warp_cycle_q == 2'd0)
                seen_cycle1 = 1;
        end

        check(seen_cycle1,
              "scenario2: sub-warp 0 reached decode before stall");

        // Assert stall between clock edges.
        @(negedge clk);
        tb_buffer_full = 1'b1;

        // Snapshot all pipeline outputs.
        held_instr = il_instr_q;
        held_pc = il_instr_pc_q;

        held_src1 = il_src1_addr;
        held_src2 = il_src2_addr;
        held_src3 = il_src3_addr;

        held_dec_cycle = dec_sub_warp_cycle_q;
        held_dec_valid = dec_sub_warp_valid_q;
        held_dec_dest = dec_dest_addr_q;
        held_dec_alu_valid = dec_alu_valid_q;

        held_buf_instr = fs_instr;
        held_buf_pc = fs_instr_pc;

        cyc_before_hold = swc_cycle;

        // Hold stall for four clock cycles.
        for (c = 0; c < 4; c++) begin
            tick(1);

            check(swc_cycle == cyc_before_hold,
                  "scenario2: sub-warp counter frozen");

            check(il_instr_q == held_instr &&
                  il_instr_pc_q == held_pc,
                  "scenario2: instruction and PC frozen");

            check(il_src1_addr == held_src1 &&
                  il_src2_addr == held_src2 &&
                  il_src3_addr == held_src3,
                  "scenario2: source addresses frozen");

            check(dec_sub_warp_cycle_q == held_dec_cycle &&
                  dec_sub_warp_valid_q == held_dec_valid &&
                  dec_dest_addr_q == held_dec_dest &&
                  dec_alu_valid_q == held_dec_alu_valid,
                  "scenario2: decode registers frozen");

            check(fs_instr == held_buf_instr &&
                  fs_instr_pc == held_buf_pc,
                  "scenario2: prefetch buffer head unchanged");

            check(!consume_sig,
                  "scenario2: no instruction consumed during stall");

            check(!swc_valid,
                  "scenario2: sub_warp_valid deasserted during stall");
        end

        // Release stall between clock edges.
        @(negedge clk);
        tb_buffer_full = 1'b0;

        // Sub-warp 0 was decoded before the stall.
        // Expect sub-warps 1, 2, and 3 in order after recovery.
        expected_cycle = 1;
        observed_count = 0;
        sequence_error = 0;

        for (c = 0; c < 30 && observed_count < 3; c++) begin
            tick(1);

            if (dec_sub_warp_valid_q &&
                dec_instr_pc_q == target_pc) begin

                if (dec_sub_warp_cycle_q != expected_cycle[1:0]) begin
                    sequence_error = 1;

                    check(1'b0,
                          $sformatf(
                              "scenario2: expected sub-warp %0d, got %0d",
                              expected_cycle,
                              dec_sub_warp_cycle_q
                          ));
                end

                observed_count++;
                expected_cycle++;
            end
        end

        check(observed_count == 3,
              "scenario2: three sub-warps observed after stall");

        check(!sequence_error,
              "scenario2: sub-warps 1, 2, 3 decoded in order");
    end
endtask

    // Scenario 3: two-warp back-to-back spans (natural GTO cycling)
    task scenario3_two_warp_alternation;
        begin
            auto_commit_enable = 1'b0;
            $display("\n--- Scenario 3: two-warp back-to-back spans ---");
            do_reset();
            load_word(32'h0000_3000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_3004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_3008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_300C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
    
            launch_kernel(2, 32'h0000_3000);
    
            seen_warp0 = 1'b0;
            seen_warp1 = 1'b0;
            exp_vld    = 1'b0;
            for (c = 0; c < 60; c = c + 1) begin
                tick(1);
                if (dec_sub_warp_valid_q && dec_dest_addr_q[9:7] == 3'd0) seen_warp0 = 1'b1;
                if (dec_sub_warp_valid_q && dec_dest_addr_q[9:7] == 3'd1) seen_warp1 = 1'b1;
    
                if (exp_vld) begin
                    check(il_src1_addr[9:7] == exp_warp && il_src1_addr[6:5] == exp_cyc,
                        $sformatf("scenario3: latch src addr {warp,cyc}={%0d,%0d} matches what it used at the registering edge (got {%0d,%0d})",
                                    exp_warp, exp_cyc, il_src1_addr[9:7], il_src1_addr[6:5]));
                end
                // what the latch will use at the NEXT edge (values visible right now)
                exp_warp = consume_sig ? ws_next_warp : ws_curr_warp;
                exp_cyc  = swc_cycle;
                exp_vld  = 1'b1;
            end
            check(seen_warp0, "scenario3: warp0 was decoded at least once");
            check(seen_warp1, "scenario3: warp1 was decoded at least once (GTO switched away from warp0 without a commit)");
            auto_commit_enable = 1'b1;
        end
    endtask

    // Scenario 4: branch discard through prefetch_buffer.
    task scenario4_branch_discard;
        begin
            $display("\nScenario 4: branch/DONE discard through prefetch_buffer");
            do_reset();
            load_word(32'h0000_4000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_4004, branch_instr(OP_BEQ, 5'd2, 5'd3, 10'd4, 6'd2));
            load_word(32'h0000_4008, r_type(OP_ADD, 5'd2, 5'd3, 5'd9));
            load_word(32'h0000_400C, r_type(OP_ADD, 5'd2, 5'd3, 5'd9));

            launch_kernel(1, 32'h0000_4000);

            consumed = 0;
            for (c = 0; c < 60 && consumed < 2; c = c + 1) begin
                tick(1);
                if (consume_sig) begin
                    if (consumed == 0) consumed_pc0 = fs_instr_pc;
                    else if (consumed == 1) consumed_pc1 = fs_instr_pc;
                    consumed = consumed + 1;
                end
            end
            check(consumed == 2, $sformatf("scenario4: exactly 2 instructions consumed (word0, word1=branch) before stall (got %0d)", consumed));
            if (consumed == 2) begin
                check(consumed_pc0 == 32'h0000_4000, "scenario4: first consumed = word0 (ADD)");
                check(consumed_pc1 == 32'h0000_4004, "scenario4: second consumed = word1 (BRANCH)");
            end
            
            tick(1);
            check(fetch_buffer_all_invalid(), "scenario4: prefetch_buffer fully invalidated after consuming the branch (word2/word3 discarded)");
        end
    endtask

    // Scenario 5: fill_recon_pc truncation (isolated from line-boundary)
    task scenario5_recon_pc_truncation;
        begin
            $display("\nScenario 5: fill_recon_pc truncation");
            do_reset();
            load_word(32'h0000_5000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_5004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_5008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_500C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));

            init_recon_pc_arr[0] = 32'h0000_5008;
            launch_kernel(1, 32'h0000_5000);

            filled = 0;
            for (c = 0; c < 20 && !filled; c = c + 1) begin
                tick(1);
                if (u_fetch.buffer.valid[0] || u_fetch.buffer.valid[1] ||
                    u_fetch.buffer.valid[2] || u_fetch.buffer.valid[3])
                    filled = 1;
            end
            check(filled == 1, "scenario5: fill landed");
            check(u_fetch.buffer.valid[0] == 1'b1, "scenario5: word0 (pc=0x5000) valid (below recon_pc)");
            check(u_fetch.buffer.valid[1] == 1'b1, "scenario5: word1 (pc=0x5004) valid (below recon_pc)");
            check(u_fetch.buffer.valid[2] == 1'b0, "scenario5: word2 (pc=0x5008 == recon_pc) truncated");
            check(u_fetch.buffer.valid[3] == 1'b0, "scenario5: word3 (pc=0x500C) truncated");
        end
    endtask

    // Scenario 6: line-boundary truncation (isolated from recon_pc)
    task scenario6_line_boundary_truncation;
        begin
            $display("\nScenario 6: line-boundary truncation");
            do_reset();
            load_word(32'h0000_2078, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_207C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_2080, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_2084, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));

            launch_kernel(1, 32'h0000_2078);

            filled = 0;
            for (c = 0; c < 20 && !filled; c = c + 1) begin
                tick(1);
                if (u_fetch.buffer.valid[0] || u_fetch.buffer.valid[1] ||
                    u_fetch.buffer.valid[2] || u_fetch.buffer.valid[3])
                    filled = 1;
            end
            check(filled == 1, "scenario6: fill landed");
            check(u_fetch.buffer.valid[0] == 1'b1, "scenario6: word at 0x2078 valid (within line)");
            check(u_fetch.buffer.valid[1] == 1'b1, "scenario6: word at 0x207C valid (within line)");
            check(u_fetch.buffer.valid[2] == 1'b0, "scenario6: word at 0x2080 truncated (crosses into next line)");
            check(u_fetch.buffer.valid[3] == 1'b0, "scenario6: word at 0x2084 truncated (crosses into next line)");
        end
    endtask

    // Scenario 7: kernel_done and DONE warp
    task scenario7_done_kernel_done;
        begin
            $display("\nScenario 7: kernel_done & DONE");
            do_reset();
            load_word(32'h0000_6000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_6004, 32'hFFFF_FFFF); // DONE
            load_word(32'h0000_6008, 32'hFFFF_FFFF);
            load_word(32'h0000_600C, 32'hFFFF_FFFF);

            launch_kernel(1, 32'h0000_6000);

            check(u_ws.finished[0] == 1'b0, "scenario7: warp0 not finished before DONE decodes");

            seen_done_detect = 1'b0;
            for (c = 0; c < 60 && !u_ws.finished[0]; c = c + 1) begin
                tick(1);
                if (dec_done_detect) seen_done_detect = 1'b1;
            end
            check(seen_done_detect, "scenario7: dec_done_detect pulsed while DONE was in decode");
            check(u_ws.finished[0] == 1'b1, "scenario7: warp0 marked finished after DONE");
            check(ws_kernel_done == 1'b1, "scenario7: kernel_done asserted (single active warp, now finished)");
        end
    endtask

    task scenario8_buffer_full;
        logic [31:0] expected_instr;
        logic [31:0] expected_pc;
        logic [31:0] held_instr, held_pc;
        logic [9:0] held_src1, held_src2, held_src3;
        logic [1:0] held_dec_cycle;
        logic held_dec_valid;
        logic [9:0] held_dec_dest;
        logic [7:0] held_dec_alu_valid;
        logic [1:0] held_swc_cycle;
        bit saw_first_consume;
        bit saw_first_decode;
        bit sequence_error;
        int decode_count[4];
        int observed_count;
        int expected_cycle;

        begin
            $display("\nScenario 8: stall before first instruction is available");

            do_reset();

            expected_pc = 32'h0000_8000;
            expected_instr = r_type(OP_ADD, 5'd2, 5'd3, 5'd1);

            load_word(expected_pc, expected_instr);

            // Stall the pipeline before launching the kernel.
            @(negedge clk);
            tb_buffer_full = 1'b1;

            launch_kernel(1, expected_pc);

            held_instr = il_instr_q;
            held_pc = il_instr_pc_q;
            held_src1 = il_src1_addr;
            held_src2 = il_src2_addr;
            held_src3 = il_src3_addr;

            held_dec_cycle = dec_sub_warp_cycle_q;
            held_dec_valid = dec_sub_warp_valid_q;
            held_dec_dest = dec_dest_addr_q;
            held_dec_alu_valid = dec_alu_valid_q;

            held_swc_cycle = swc_cycle;

            // Allow the prefetch buffer to fill while the pipeline is stalled.
            for (c = 0; c < 30; c++) begin
                tick(1);

                check(swc_cycle == held_swc_cycle,
                    "scenario8: counter stays at reset value during stall");

                check(il_instr_q == held_instr &&
                    il_instr_pc_q == held_pc,
                    "scenario8: instruction latch does not capture instruction");

                check(il_src1_addr == held_src1 &&
                    il_src2_addr == held_src2 &&
                    il_src3_addr == held_src3,
                    "scenario8: source addresses remain frozen");

                check(dec_sub_warp_cycle_q == held_dec_cycle &&
                    dec_sub_warp_valid_q == held_dec_valid &&
                    dec_dest_addr_q == held_dec_dest &&
                    dec_alu_valid_q == held_dec_alu_valid,
                    "scenario8: decode registers remain frozen");
            end

            check(!swc_valid,
                "scenario8: sub_warp_valid never asserted during stall");

            check(!consume_sig,
                "scenario8: no instruction consumed during stall");

            check(fs_fetch_valid,
                "scenario8: prefetch buffer filled despite buffer_full");

            check(fs_instr == expected_instr &&
                fs_instr_pc == expected_pc,
                "scenario8: prefetch buffer contains correct instruction and PC");

            // Release the stall.
            @(negedge clk);
            tb_buffer_full = 1'b0;

            saw_first_consume = 1'b0;
            saw_first_decode = 1'b0;
            sequence_error = 1'b0;
            observed_count = 0;
            expected_cycle = 0;

            for (int i = 0; i < 4; i++)
                decode_count[i] = 0;

            // Stop after the first four valid decode events.
            // This avoids counting subsequent refetches of the same PC.
            for (c = 0; c < 30 && observed_count < 4; c++) begin
                @(negedge clk);

                if (consume_sig && !saw_first_consume) begin
                    saw_first_consume = 1'b1;

                    check(fs_instr == expected_instr &&
                        fs_instr_pc == expected_pc,
                        "scenario8: first consumed instruction is correct");
                end

                tick(1);

                if (dec_sub_warp_valid_q &&
                    dec_instr_pc_q == expected_pc) begin

                    if (dec_sub_warp_cycle_q != expected_cycle[1:0]) begin
                        sequence_error = 1'b1;

                        check(1'b0,
                            $sformatf(
                                "scenario8: expected sub-warp %0d, got %0d",
                                expected_cycle,
                                dec_sub_warp_cycle_q
                            ));
                    end

                    decode_count[dec_sub_warp_cycle_q]++;
                    observed_count++;
                    expected_cycle++;

                    if (dec_sub_warp_cycle_q == 2'd0)
                        saw_first_decode = 1'b1;
                end
            end

            check(saw_first_consume,
                "scenario8: first instruction consumed after stall release");

            check(saw_first_decode,
                "scenario8: first sub-warp reached decode after stall release");

            check(observed_count == 4,
                "scenario8: four sub-warps reached decode");

            check(!sequence_error,
                "scenario8: sub-warps 0, 1, 2, 3 decoded in order");

            for (int i = 0; i < 4; i++) begin
                check(decode_count[i] == 1,
                    $sformatf(
                        "scenario8: sub-warp %0d decoded exactly once (got %0d)",
                        i, decode_count[i]
                    ));
            end
        end
    endtask

    // Scenario 9: Minimum latency of a single cycle using u_icache_fast (LATENCY(1))
    task scenario9_min_latency_hit;
        begin
            $display("\nScenario 9: minimum-latency icache response path");
            do_reset();
            load_word_fast(32'h0000_9000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word_fast(32'h0000_9004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word_fast(32'h0000_9008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word_fast(32'h0000_900C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));

            fs2_next_warp = 3'd0;
            fs2_top_pc = 32'h0000_9000;
            fs2_recon_pc = 32'hFFFF_FFFF;
            fs2_consume = 1'b0;
            fs2_kernel_launch = 1'b1;
            tick(1);
            fs2_kernel_launch = 1'b0;
            #1;

            check(fs2_fetch_valid == 1'b0, "scenario9: buffer empty right after launch");
            check(ic2_req_valid == 1'b1, "scenario9: fetch_stage issues a request immediately (buffer empty, nothing outstanding)");

            filled = 0;
            for (c = 0; c < 6 && !filled; c = c + 1) begin
                tick(1);
                if (fs2_fetch_valid) filled = 1;
            end
            check(filled == 1, "scenario9: fetch completed");
            check(c <= 2, $sformatf("scenario9: minimum-latency stub resolved quickly (took %0d ticks to observe fetch_valid, vs 3 for the LATENCY(2) stub)", c));
            check(fs2_instr == r_type(OP_ADD, 5'd2, 5'd3, 5'd1), "scenario9: fetched word matches what was loaded");
            check(fs2_instr_pc == 32'h0000_9000, "scenario9: fetched instruction's PC is correct");
        end
    endtask

    // Scenario 10: decode_stage's format-dependent dst mux for I-type, FMA, Special, and Branch instructions
    task scenario10_decode_formats;
        begin
            $display("\nScenario 10: decode_stage format-dependent dst mux (I-type/FMA/Special/Branch)");
            do_reset();
            load_word(32'h0000_A000, i_type(OP_ADDI, 5'd4, 5'd7, 16'h00FF));         // I-type: dst = s2 = R7
            load_word(32'h0000_A004, fma_type(OP_FMA, 5'd1, 5'd2, 5'd3, 5'd9));      // FMA: dst = R9
            load_word(32'h0000_A008, special_type(OP_MOV_TID, 5'd11));               // Special: dst = R11
            load_word(32'h0000_A00C, branch_instr(OP_BEQ, 5'd2, 5'd3, 10'd4, 6'd2)); // Branch: dst = 0

            launch_kernel(1, 32'h0000_A000);

            seen_itype = 1'b0; itype_ok = 1'b0;
            seen_fma   = 1'b0; fma_ok   = 1'b0;
            seen_spec  = 1'b0; spec_ok  = 1'b0;
            seen_branch = 1'b0; branch_ok = 1'b0;

            for (c = 0; c < 200; c = c + 1) begin
                tick(1);
                if (dec_sub_warp_valid_q && dec_sub_warp_cycle_q == 2'd0) begin
                    if (dec_instr_pc_q == 32'h0000_A000) begin
                        seen_itype = 1'b1;
                        itype_ok = (dec_alu_valid_q != 8'b0) && (dec_fma_valid_q == 8'b0) &&
                                   (dec_special_reg_valid_q == 8'b0) && (dec_dest_addr_q[4:0] == 5'd7);
                    end else if (dec_instr_pc_q == 32'h0000_A004) begin
                        seen_fma = 1'b1;
                        fma_ok = (dec_fma_valid_q != 8'b0) && (dec_alu_valid_q == 8'b0) &&
                                 (dec_special_reg_valid_q == 8'b0) && (dec_dest_addr_q[4:0] == 5'd9);
                    end else if (dec_instr_pc_q == 32'h0000_A008) begin
                        seen_spec = 1'b1;
                        spec_ok = (dec_special_reg_valid_q != 8'b0) && (dec_alu_valid_q == 8'b0) &&
                                  (dec_fma_valid_q == 8'b0) && (dec_dest_addr_q[4:0] == 5'd11);
                    end else if (dec_instr_pc_q == 32'h0000_A00C) begin
                        seen_branch = 1'b1;
                        branch_ok = (dec_alu_valid_q != 8'b0) && (dec_fma_valid_q == 8'b0) &&
                                    (dec_special_reg_valid_q == 8'b0) && (dec_dest_addr_q[4:0] == 5'd0);
                    end
                end
            end

            check(seen_itype && itype_ok, "scenario10: I-type dst = src2-slot field (R7), routed to alu_valid only");
            check(seen_fma && fma_ok, "scenario10: FMA dst = [10:6] field (R9), routed to fma_valid only");
            check(seen_spec && spec_ok, "scenario10: Special dst = [25:21] field (R11), routed to special_reg_valid only");
            check(seen_branch && branch_ok, "scenario10: Branch dst forced to 0, routed to alu_valid (branches share the ALU path)");
        end
    endtask

    // Scenario 11: thread masking during branching
    task scenario11_masking;
        begin
            $display("\nScenario 11: active_mask gates decode_stage's per-lane valid bits");
            do_reset();
            load_word(32'h0000_B000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_B004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_B008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_B00C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));

            init_mask_arr[0] = 32'h0000_00A5; // cycle0 lane slice = 8'hA5 = 10100101
            launch_kernel(1, 32'h0000_B000);

            seen_masked_cycle = 1'b0;
            for (c = 0; c < 60 && !seen_masked_cycle; c = c + 1) begin
                tick(1);
                if (dec_sub_warp_valid_q && dec_sub_warp_cycle_q == 2'd0 && dec_instr_pc_q == 32'h0000_B000) begin
                    check(dec_alu_valid_q == 8'hA5,
                          $sformatf("scenario11: alu_valid_q reflects active_mask[7:0]=A5 exactly (got %b)", dec_alu_valid_q));
                    seen_masked_cycle = 1'b1;
                end
            end
            check(seen_masked_cycle, "scenario11: observed the masked decode cycle");
        end
    endtask

    // Scenario 12: buffer refill after a full, non-branch drain.
    task scenario12_refill_after_drain;
        begin
            $display("\nScenario 12: buffer refill after full (non-branch) drain");
            do_reset();
            load_word(32'h0000_C000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_C004, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_C008, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_C00C, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));

            launch_kernel(1, 32'h0000_C000);

            filled3 = 0;
            for (c = 0; c < 20 && !filled3; c = c + 1) begin
                tick(1);
                if (fs_fetch_valid) filled3 = 1;
            end
            check(filled3 == 1, "scenario12: initial fill landed");

            drained = 0;
            for (c = 0; c < 40 && !drained; c = c + 1) begin
                tick(1);
                if (!fs_fetch_valid) drained = 1;
            end
            check(drained == 1, "scenario12: buffer fully drained after 4 non-branch consumes (no discard involved)");

            refilled = 0;
            for (c = 0; c < 20 && !refilled; c = c + 1) begin
                tick(1);
                if (fs_fetch_valid) refilled = 1;
            end
            check(refilled == 1, "scenario12: fetch_stage re-issued a request and the buffer refilled after draining");
            check(top_pc_arr[0] == 32'h0000_C000,
                  "scenario12: top_pc unchanged (expected/known gap -- current_pc/current_pc_valid unwired, refetches same line, see NOTES.md Sec.3)");
        end
    endtask

    // Scenario 13: branch redirect actually changes fetch PC.
    task scenario13_branch_redirect;
        begin
            $display("\nScenario 13: branch redirect actually changes fetch PC");
            do_reset();
            load_word(32'h0000_D000, r_type(OP_ADD, 5'd2, 5'd3, 5'd1));
            load_word(32'h0000_D004, branch_instr(OP_BEQ, 5'd2, 5'd3, 10'd0, 6'd0));
            load_word(32'h0000_D008, r_type(OP_ADD, 5'd2, 5'd3, 5'd9));  // must never be seen post-redirect
            load_word(32'h0000_D00C, r_type(OP_ADD, 5'd2, 5'd3, 5'd9));  // must never be seen post-redirect
            load_word(32'h0000_E000, r_type(OP_ADD, 5'd2, 5'd3, 5'd20)); // branch target line
            load_word(32'h0000_E004, r_type(OP_ADD, 5'd2, 5'd3, 5'd20));
            load_word(32'h0000_E008, r_type(OP_ADD, 5'd2, 5'd3, 5'd20));
            load_word(32'h0000_E00C, r_type(OP_ADD, 5'd2, 5'd3, 5'd20));

            launch_kernel(1, 32'h0000_D000);

            redirect_fired = 0;
            for (c = 0; c < 60 && !redirect_fired; c = c + 1) begin
                tick(1);
                // fire once, on the cycle decode tags the branch's final sub-warp
                // cycle -- stand-in for mask_split_unit's real per-cycle
                // accumulation completing.
                if (dec_sub_warp_valid_q && dec_sub_warp_cycle_q == 2'd3 &&
                    dec_instr_pc_q == 32'h0000_D004 && !redirect_fired) begin
                    tb_push2_valid[0]          = 1'b1;
                    tb_push2_mask_taken[0]     = 32'hFFFF_FFFF;   // fully-taken, no divergence
                    tb_push2_mask_not_taken[0] = 32'h0000_0000;
                    tb_push2_pc_taken[0]       = 32'h0000_E000;   // branch target
                    tb_push2_pc_fallthrough[0] = 32'h0000_D008;
                    tb_push2_recon_pc[0]       = 32'h0000_F000;   // distinct from both, so neither
                                                                   // child gets skip-pushed for the
                                                                   // wrong reason -- see chat writeup
                    redirect_fired = 1;
                end else begin
                    tb_push2_valid[0] = 1'b0;
                end
            end
            check(redirect_fired == 1, "scenario13: branch reached decode and redirect was issued");

            tick(1); // let the push land in recon_stack's registers
            tb_push2_valid[0] = 1'b0;
            check(top_pc_arr[0] == 32'h0000_E000, "scenario13: recon_stack top_pc updated to the branch target");

            saw_stale = 0;
            saw_target = 0;
            for (c = 0; c < 40 && !saw_target; c = c + 1) begin
                tick(1);
                if (consume_sig) begin
                    if (fs_instr_pc == 32'h0000_D008 || fs_instr_pc == 32'h0000_D00C) saw_stale = 1;
                    if (fs_instr_pc == 32'h0000_E000) saw_target = 1;
                end
            end
            check(saw_stale == 0, "scenario13: stale pre-redirect instructions (0xD008/0xD00C) were never consumed");
            check(saw_target == 1, "scenario13: fetch_stage/prefetch_buffer picked up the redirected target (0xE000)");
        end
    endtask

    initial begin
        scenario1_tag_alignment();
        scenario2_buffer_full_hold();
        scenario3_two_warp_alternation();
        scenario4_branch_discard();
        scenario5_recon_pc_truncation();
        scenario6_line_boundary_truncation();
        scenario7_done_kernel_done();
        scenario8_buffer_full();
        scenario9_min_latency_hit();
        scenario10_decode_formats();
        scenario11_masking();
        scenario12_refill_after_drain();
        scenario13_branch_redirect();


        $display("\n----------------------------------------------------");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL SCENARIOS PASSED");
        else $display("SCENARIOS FAILED");
        $finish;
    end
endmodule