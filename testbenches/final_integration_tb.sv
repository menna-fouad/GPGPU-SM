`timescale 1ns/1ps
`default_nettype none

module final_integration_tb;
    logic sm_clk, sm_reset;
    logic mem_ui_clk, mem_ui_reset;

    always #5 sm_clk = ~sm_clk;
    always #6.154 mem_ui_clk = ~mem_ui_clk;
    
    logic kernel_start, kernel_done;
    logic [3:0] num_warps;

    logic init_calib_complete, app_rdy, app_en;
    logic [2:0] app_cmd;
    logic [26:0] app_addr;

    logic app_wdf_rdy, app_wdf_wren, app_wdf_end;
    logic [15:0] app_wdf_mask;
    logic [127:0] app_wdf_data;
    
    logic app_rd_data_valid;
    logic [127:0] app_rd_data;

    sm_top u_sm_top (.*);

    // fake MIG
    localparam logic [31:0] K = 32'hA5A50000;

    // beat_no = app_addr[25:3]; byte address of the beat = beat_no*16
    function automatic logic [127:0] init_beat(input logic [22:0] beat_no);
        logic [31:0] ba;
        ba = {5'b0, beat_no, 4'b0};
        return {(ba+32'd12)^K, (ba+32'd8)^K, (ba+32'd4)^K, ba^K}; // word 0 in [31:0]
    endfunction

    logic [127:0] mig_mem [logic [22:0]]; // associative array only holding values written to it
    logic [22:0] rq [$];
    logic [22:0] a;

    always_ff @(posedge mem_ui_clk) begin
        if (mem_ui_reset) begin
            rq.delete();
            app_rd_data_valid <= 1'b0;
            app_rdy <= 1'b0;
            app_wdf_rdy <= 1'b0;
        end else begin
            app_rdy <= init_calib_complete && ($urandom_range(0,3) != 0);
            app_wdf_rdy <= init_calib_complete && ($urandom_range(0,3) != 0);
            app_rd_data_valid <= 1'b0;

            if (app_en && app_rdy) begin
                if (app_cmd == 3'b000) begin
                    assert (app_wdf_wren && app_wdf_rdy) else $fatal(1, "MIG write command/data not paired");
                    mig_mem[app_addr[25:3]] = app_wdf_data;
                end else
                    rq.push_back(app_addr[25:3]);
            end

            if (rq.size() > 0 && $urandom_range(0,2) == 0) begin
                a = rq.pop_front();
                app_rd_data <= mig_mem.exists(a) ? mig_mem[a] : init_beat(a);
                app_rd_data_valid <= 1'b1;
            end
        end
    end

    task automatic reset;
        begin
            fork
                begin
                    @(negedge sm_clk);
                    sm_reset = 1'b1;
                    
                    repeat (3) @(negedge sm_clk);
                    sm_reset = 1'b0;
                end
                begin
                    @(negedge mem_ui_clk);
                    mem_ui_reset = 1'b1;

                    repeat (3) @(negedge mem_ui_clk);
                    mem_ui_reset = 1'b0;
                    init_calib_complete = 1'b1;
                end
            join
        end
    endtask

    task automatic launch_kernel(input logic [3:0] warps);
        @(negedge sm_clk);
        num_warps = warps;
        kernel_start = 1'b1;

        @(negedge sm_clk);
        kernel_start = 1'b0;
    endtask

    task automatic wait_for_kernel_done(input int max_cycles);
        for (int i = 0; i < max_cycles; i++) begin
            @(negedge sm_clk);

            if (kernel_done) begin
                $display("Kernel completed after %0d cycles", i + 1);
                return;
            end
        end

        $fatal(1, "Kernel timeout after %0d cycles", max_cycles);
    endtask

    // R-type
    localparam logic [5:0] NOP = 6'b000000, ADD = 6'b000001, SUB = 6'b000010,
                           AND = 6'b000011, OR  = 6'b000100, SLT = 6'b000101,
                           MUL = 6'b000110;

        // I-type
    localparam logic [5:0] LUI  = 6'b001000, ADDI  = 6'b001001, SUBI  = 6'b001010,
                           ANDI = 6'b001011, ORI   = 6'b001100, SLTI  = 6'b001101,
                           LOAD = 6'b001110, STORE = 6'b001111;

    // FMA
    localparam logic [5:0] FMA = 6'b010000;

    // Branch
    localparam logic [5:0] BEQ = 6'b011000, BNE = 6'b011001, BLT = 6'b011010, BGE = 6'b011011;

    // Special reg instructions
    localparam logic [5:0] MOV_TID = 6'b100001, MOV_WID = 6'b100010, MOV_BID = 6'b100100;

    // R-type: opcode | src1 | src2 | dst | unused
    function automatic logic [31:0] encode_r(
        input logic [5:0] opcode,
        input logic [4:0] src1, src2, dst
    );
        return {opcode, src1, src2, dst, 11'b0};
    endfunction

    // I-type: opcode | src1 | dst/src2 | immediate
    function automatic logic [31:0] encode_i(
        input logic [5:0] opcode,
        input logic [4:0] src1, dst,
        input logic [15:0] imm
    );
        return {opcode, src1, dst, imm};
    endfunction

    // FMA: opcode | src1 | src2 | src3 | dst | unused
    function automatic logic [31:0] encode_fma(
        input logic [4:0] src1, src2, src3, dst
    );
        return {FMA, src1, src2, src3, dst, 6'b0};
    endfunction

    // Branch: opcode | src1 | src2 | target_offset | reconv_offset
    function automatic logic [31:0] encode_branch(
        input logic [5:0] opcode,
        input logic [4:0] src1, src2,
        input logic [9:0] target_offset,
        input logic [5:0] reconv_offset
    );
        return {opcode, src1, src2, target_offset, reconv_offset};
    endfunction

    // Special: opcode | dst | unused
    function automatic logic [31:0] encode_special(
        input logic [5:0] opcode,
        input logic [4:0] dst
    );
        return {opcode, dst, 21'b0};
    endfunction

    task automatic load_instruction(
        input logic [31:0] byte_addr,
        input logic [31:0] instr
    );
        logic [22:0] beat;
        logic [127:0] data;

        beat = byte_addr[26:4];

        data = mig_mem.exists(beat) ? mig_mem[beat] : init_beat(beat);
        data[32 * byte_addr[3:2] +: 32] = instr;

        mig_mem[beat] = data;
    endtask

    generate
        for (genvar lane = 0; lane < 8; lane++) begin : init_rf
            task automatic initialize();
                for (int addr = 0; addr < 1024; addr++) begin
                    u_sm_top.gen_reg_bank[lane].u_reg_file.bram1[addr] = 32'b0;
                    u_sm_top.gen_reg_bank[lane].u_reg_file.bram2[addr] = 32'b0;
                    u_sm_top.gen_reg_bank[lane].u_reg_file.bram3[addr] = 32'b0;
                end
            endtask
        end
    endgenerate

    generate
        for (genvar lane = 0; lane < 8; lane++) begin : check_rf
            task automatic check_register(
                input logic [2:0] warp,
                input logic [1:0] sw,
                input logic [4:0] reg_num,
                input logic [31:0] expected
            );
                logic [9:0] addr;
                addr = {warp, sw, reg_num};

                assert (u_sm_top.gen_reg_bank[lane].u_reg_file.bram1[addr] === expected)
                    else $fatal(1, "Lane %0d, warp %0d, subwarp %0d, R%0d: expected %0d, got %0d",
                                    lane, warp, sw, reg_num, expected,
                                    u_sm_top.gen_reg_bank[lane].u_reg_file.bram1[addr]);
            endtask
        end
    endgenerate

    task automatic check_all_lanes(
        input logic [2:0] warp,
        input logic [1:0] sw,
        input logic [4:0] reg_num,
        input logic [31:0] expected
    );
        check_rf[0].check_register(warp, sw, reg_num, expected);
        check_rf[1].check_register(warp, sw, reg_num, expected);
        check_rf[2].check_register(warp, sw, reg_num, expected);
        check_rf[3].check_register(warp, sw, reg_num, expected);
        check_rf[4].check_register(warp, sw, reg_num, expected);
        check_rf[5].check_register(warp, sw, reg_num, expected);
        check_rf[6].check_register(warp, sw, reg_num, expected);
        check_rf[7].check_register(warp, sw, reg_num, expected);
    endtask

    initial begin
        localparam logic [31:0] DONE_INSTR = 32'hFC00_0000;

        $dumpfile("final_integration_tb");
        $dumpvars(0, final_integration_tb);

        sm_clk = 1'b0; mem_ui_clk = 1'b0;
        sm_reset = 1'b1; mem_ui_reset = 1'b1;

        kernel_start = 1'b0; num_warps = 4'd0;
        
        init_calib_complete = 1'b0; app_rd_data = '0;

        reset();

        $display("TEST 1: Single-warp DONE");
        mig_mem.delete();
        load_instruction(32'h0000_0000, DONE_INSTR);

        launch_kernel(4'd1);
        wait_for_kernel_done(500);

        $display("TEST 1 PASSED");

        $display("TEST 2: Single-warp arithmetic instructions and register writeback");

        /*
        ADDI R1, R0, 10     // R1 = 10
        ADDI R2, R0, 20     // R2 = 20
        ADD  R3, R1, R2     // R3 = 30
        SUB  R4, R3, R1     // R4 = 20
        MUL  R5, R4, R2     // R5 = 400
        DONE
        */

        reset();
        mig_mem.delete();
        load_instruction('h00, encode_i(ADDI, 0, 1, 10));
        load_instruction('h04, encode_i(ADDI, 0, 2, 20));
        load_instruction('h08, encode_r(ADD, 1, 2, 3));
        load_instruction('h0C, encode_r(SUB, 3, 1, 4));
        load_instruction('h10, encode_r(MUL, 4, 2, 5));
        load_instruction('h14, DONE_INSTR);

        init_rf[0].initialize();
        init_rf[1].initialize();
        init_rf[2].initialize();
        init_rf[3].initialize();
        init_rf[4].initialize();
        init_rf[5].initialize();
        init_rf[6].initialize();
        init_rf[7].initialize();

        launch_kernel(4'd1);
        wait_for_kernel_done(50000);

        for (int sw = 0; sw < 4; sw++) begin
            check_all_lanes(3'd0, 2'(sw), 5'd1, 32'd10);
            check_all_lanes(3'd0, 2'(sw), 5'd2, 32'd20);
            check_all_lanes(3'd0, 2'(sw), 5'd3, 32'd30);
            check_all_lanes(3'd0, 2'(sw), 5'd4, 32'd20);
            check_all_lanes(3'd0, 2'(sw), 5'd5, 32'd400);
        end

        $display("TEST 2 PASSED");

        $finish;
    end

    initial begin
        #10_000_000;
        $fatal("TIMEOUT");
    end
endmodule
