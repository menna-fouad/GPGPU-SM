`timescale 1ns/1ps
module special_reg_unit_tb;
    // special_instr_type = opcode[2:0]
    localparam logic [2:0] MOV_TID = 3'b001, MOV_WID = 3'b010, MOV_BID = 3'b100;

    logic [2:0] warp_id;
    logic [1:0] sub_warp_cycle;
    logic [2:0] special_instr_type;
    logic [9:0] reg_bank_addr_in;
    logic valid_in;

    // 8 lanes
    logic [31:0] result [0:7];
    logic [9:0] reg_bank_addr_out [0:7];
    logic valid_out [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : lane
            special_reg_unit #(.LANE_NUM(i[2:0])) DUT (
                .warp_id(warp_id),
                .sub_warp_cycle(sub_warp_cycle),
                .special_instr_type(special_instr_type),
                .result(result[i]),
                .reg_bank_addr_in(reg_bank_addr_in),
                .reg_bank_addr_out(reg_bank_addr_out[i]),
                .valid_in(valid_in),
                .valid_out(valid_out[i])
            );
        end
    endgenerate

    int errors = 0;

    task automatic check(input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL | got = %0d expected = %0d", got, exp);
            errors++;
        end else begin
            $display("PASS | got = %0d", got);
        end
    endtask

    initial begin
        warp_id = 3'd0;
        sub_warp_cycle = 2'd0;
        special_instr_type = MOV_TID;
        reg_bank_addr_in = 10'd0;
        valid_in = 1'b0;
        #1;

        // MOV_TID: thread_id = lane_number + 8 * sub_warp_cycle
        special_instr_type = MOV_TID;
        for (int cycle = 0; cycle < 4; cycle++) begin
            sub_warp_cycle = cycle[1:0];
            #1;
            for (int lane_idx = 0; lane_idx < 8; lane_idx++) begin
                $display("MOV_TID, sub_warp_cycle = %0d, lane = %0d", sub_warp_cycle, lane_idx);
                check(result[lane_idx], lane_idx + 8 * cycle);
            end
        end

        // MOV_WID: every lane broadcasts the same warp_id
        special_instr_type = MOV_WID;
        sub_warp_cycle = 2'd2;
        for (int warp = 0; warp < 8; warp++) begin
            warp_id = warp[2:0];
            #1;
            for (int lane_idx = 0; lane_idx < 8; lane_idx++) begin
                $display("MOV_WID, warp = %0d, lane = %0d", warp, lane_idx);
                check(result[lane_idx], warp);
            end
        end

        // MOV_BID: warps 0-3 are block 0, warps 4-7 are block 1
        special_instr_type = MOV_BID;
        for (int warp = 0; warp < 8; warp++) begin
            warp_id = warp[2:0];
            #1;
            for (int lane_idx = 0; lane_idx < 8; lane_idx++) begin
                $display("MOV_BID, warp = %0d, lane = %0d", warp, lane_idx);
                check(result[lane_idx], warp / 4);
            end
        end

        // valid and reg_bank_addr are passed straight through
        $display("\nvalid and reg_bank_addr passthrough");
        reg_bank_addr_in = 10'b101_10_00110;
        valid_in = 1'b1;
        #1;
        for (int lane_idx = 0; lane_idx < 8; lane_idx++) begin
            check(valid_out[lane_idx], 1'b1);
            check(reg_bank_addr_out[lane_idx], 10'b101_10_00110);
        end
        valid_in = 1'b0;
        #1;
        for (int lane_idx = 0; lane_idx < 8; lane_idx++)
            check(valid_out[lane_idx], 1'b0);

        if (errors == 0)
            $display("\nALL TESTS PASSED");
        else
            $fatal(1, "\n%0d TEST(S) FAILED", errors);

        $finish;
    end
endmodule
