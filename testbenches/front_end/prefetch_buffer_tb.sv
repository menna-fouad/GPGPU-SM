module prefetch_buffer_tb;
    logic clk, reset;
    logic [2:0] next_warp;
    logic fill_valid, consume;
    logic [127:0] fill_data, fill_pcs;
    logic [31:0] fill_recon_pc;

    logic [31:0] instr, instr_pc;
    logic fetch_valid;

    int errors = 0;
    int tests = 0;

    prefetch_buffer DUT (
        .clk(clk),
        .reset(reset),
        .next_warp(next_warp),
        .fill_valid(fill_valid),
        .consume(consume),
        .fill_data(fill_data),
        .fill_pcs(fill_pcs),
        .fill_recon_pc(fill_recon_pc),
        .instr(instr),
        .instr_pc(instr_pc),
        .fetch_valid(fetch_valid)
    );

    always #5 clk = ~clk;

    task automatic drive(
        input [2:0] warp,
        input valid, cons,
        input [127:0] data, pcs,
        input [31:0] recon_pc
    );
        next_warp = warp;
        fill_valid = valid; consume = cons;
        fill_data = data; fill_pcs = pcs;
        fill_recon_pc = recon_pc;
    endtask

    task automatic check(
        input [31:0] exp_instr, exp_pc,
        input exp_valid
    );
        tests++;
        if (instr !== exp_instr || instr_pc !== exp_pc || fetch_valid !== exp_valid) begin
            $display("FAIL | expected instr = %0d instr_pc = %0d valid= %0d | got instr = %0d instr_pc = %0d valid = %0b",
            exp_instr, exp_pc, exp_valid, instr, instr_pc, fetch_valid);
            errors++;
        end else begin
            $display("PASS | got instr = %0d, instr_pc = %0d, valid = %0b", instr, instr_pc, fetch_valid);
        end
    endtask

    task automatic check_valid(input exp_valid);
        tests++;
        if (fetch_valid !== exp_valid) begin
            errors++;
            $display("FAIL | expected valid = %0b | got valid = %0b", exp_valid, fetch_valid);
        end else begin
            $display("PASS | got valid = %0b", fetch_valid);
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1; // settle after clock edge
        end
    endtask

    localparam [31:0] I_A = 32'h0000_0001; // R-type
    localparam [31:0] I_B = 32'h0000_0002; // R-type
    localparam [31:0] I_C = 32'h0000_0003; // R-type
    localparam [31:0] I_D = 32'h0000_0004; // R-type
    localparam [31:0] I_BR = 32'h6000_0005; // BRANCH (top 3 bits = 011 => BEQ)
    localparam [31:0] I_DONE = 32'hFFFF_FFFF; // DONE (top 6 bits = 111 111 => DONE)

    initial begin
        clk = 1'b0;
        next_warp = 3'd0; fill_valid = 1'b0; consume = 1'b0;
        fill_data = '0; fill_pcs = '0; fill_recon_pc = 32'hFFFF_FFFF;

        reset = 1'b1; tick(); reset = 1'b0; tick();
        
        // 1: reset clears valid
        $display("Instruction and PC should be 0 and set not valid");
        next_warp = 3'd0;
        check(32'h0000_0000, 32'h0000_0000, 1'b0);

        // 2: basic fill
        $display("Fill warp 2");
        drive(3'd2, // warp
            1'b1, 1'b0, // fetch_valid & cons
            {I_D, I_C, I_B, I_A},
            {32'h1030, 32'h1020, 32'h1010, 32'h1000},
            32'hFFFF_FFFF);
        tick();
        fill_valid = 1'b0;
        check(I_A, 32'h1000, 1'b1);

        // 3: base-indexing at warp 0 and warp 7
        $display("Fill edge warps (0 & 7)");
        drive(3'd0,
            1'b1, 1'b0,
            {I_D, I_C, I_B, I_A},
            {32'h2030, 32'h2020, 32'h2010, 32'h2000},
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;
        check(I_A, 32'h2000, 1'b1);

        drive(3'd7,
            1'b1, 1'b0,
            {I_D, I_C, I_B, I_A},
            {32'h3030, 32'h3020, 32'h3010, 32'h3000},
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;
        check(I_A, 32'h3000, 1'b1);

        // 4: consume advances, drops after 4th (warp 2 from test 2)
        $display("Consume advances warp 2");
        next_warp = 3'd2;
        consume = 1'b1; tick();
        check(I_B, 32'h1010, 1'b1);
        tick();
        check(I_C, 32'h1020, 1'b1);
        tick();
        check(I_D, 32'h1030, 1'b1);
        tick();
        consume = 1'b0;
        check_valid(1'b0);

        // 5: fill_recon_pc truncation mid-batch, warp 4
        $display("Entries with pc >= fill_recon_pc are invalid");
        drive(3'd4,
            1'b1, 1'b0,
            {I_D, I_C, I_B, I_A},
            {32'h4030, 32'h4020, 32'h4010, 32'h4000},
            32'h4020);              // word 2's PC (0x4020) >= bound
        tick(); fill_valid = 1'b0;
        check(I_A, 32'h4000, 1'b1);
        consume = 1'b1; tick();
        check(I_B, 32'h4010, 1'b1);
        tick();
        consume = 1'b0;
        check_valid(1'b0); // both truncated words invalid

        // 6: branch mid-buffer (word 1) for warp 5
        $display("Branch mid-buffer clears remaining entries when consumed");
        drive(3'd5,
            1'b1, 1'b0,
            {I_D, I_C, I_BR, I_A},
            {32'h5030, 32'h5020, 32'h5010, 32'h5000},
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;
        check(I_A, 32'h5000, 1'b1); // word 0, not yet touched
        consume = 1'b1; tick();
        check(I_BR, 32'h5010, 1'b1); // word 1, the branch itself, still valid
        tick();
        consume = 1'b0;
        check_valid(1'b0); // words 2,3 wiped on the branch's consume

        // 7: DONE mid-buffer (word 1)
        $display("DONE mid-buffer clears remaining entries when consumed");
        drive(3'd6,
            1'b1, 1'b0,
            {I_D, I_C, I_DONE, I_A},
            {32'h6030, 32'h6020, 32'h6010, 32'h6000},
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;
        check(I_A, 32'h6000, 1'b1);
        consume = 1'b1; tick();
        check(I_DONE, 32'h6010, 1'b1);
        tick();
        consume = 1'b0;
        check_valid(1'b0);

        // 8: branch as last word (word 3)
        $display("Branch is the last instruction fetched");
        drive(1'b1,
            1'b1, 1'b0,
            {I_BR, I_C, I_B, I_A},
            {32'h7030, 32'h7020, 32'h7010, 32'h7000},
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;
        consume = 1'b1;
        tick(); tick(); tick();
        check(I_BR, 32'h7030, 1'b1);
        tick();
        consume = 1'b0;
        check_valid(1'b0);

        // 9: two warps independent under interleaved fill/consume
        $display("Two independent warps should not affect each other");
        drive(3'd3,
            1'b1, 1'b0,
            {I_D, I_C, I_B, I_A},
            {32'h8030, 32'h8020, 32'h8010, 32'h8000},
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;

        next_warp = 3'd4;   // warp 4 already fully drained/invalid from test 5
        consume = 1'b1; tick(); consume = 1'b0;

        next_warp = 3'd3;   // warp 3 must be untouched by warp 4's consume
        #1;
        check(I_A, 32'h8000, 1'b1);

        // 10: line-boundary truncation
        $display("Words crossing the 128B line boundary are invalid");
        drive(3'd1,
            1'b1, 1'b0,
            {I_D, I_C, I_B, I_A},
            {32'h9084, 32'h9080, 32'h907C, 32'h9078}, // word0 offset 0x78 -> word index 30; words 2,3 spill into next line
            32'hFFFF_FFFF);
        tick(); fill_valid = 1'b0;
        check(I_A, 32'h9078, 1'b1); // word 0: offset 0x78, index 30 — within line
        consume = 1'b1; tick();
        check(I_B, 32'h907C, 1'b1); // word 1: offset 0x7C, index 31 — still the last valid word in this line
        tick();
        consume = 1'b0;
        check_valid(1'b0);          // words 2,3 (0x9080, 0x9084) are in the NEXT line, therefore invalid

        $display("tests=%0d errors=%0d", tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
