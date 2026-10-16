`timescale 1ns/1ps
module reg_file_tb;
    logic clk;
    logic reset;

    logic [9:0] src1_addr, src2_addr, src3_addr;
    logic write_en;
    
    logic [9:0] wr_addr;
    logic [31:0] wr_data;
    
    logic [31:0] src1_data, src2_data, src3_data;

    int errors = 0;

    reg_file DUT (
        .clk(clk),
        .reset(reset),
        .src1_addr(src1_addr),
        .src2_addr(src2_addr),
        .src3_addr(src3_addr),
        .write_en(write_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .src1_data(src1_data),
        .src2_data(src2_data),
        .src3_data(src3_data)
    );

    initial begin
        for (int i = 0; i < 1024; i++) begin
            DUT.bram1[i] = (i[4:0] == 5'b0) ? 32'b0 : i;
            DUT.bram2[i] = (i[4:0] == 5'b0) ? 32'b0 : i;
            DUT.bram3[i] = (i[4:0] == 5'b0) ? 32'b0 : i;
        end
    end

    initial clk = 0;
    always #5 clk = ~clk;

    // tick(): advance one clock edge + settle time, clear one-shot pulses
    task tick();
        @(posedge clk);
        #1; // settle
        write_en = 1'b0;
    endtask

    task check(logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL | got = %h exp = %h", got, exp);
            errors++;
        end else begin
            $display("PASS | got = %h", got);
        end
    endtask

    // address = {warp_id(3b), thread_slot(2b), register_num(5b)}
    function automatic [9:0] addr(input [2:0] warp, input [1:0] thread_slot, input [4:0] reg_num);
        addr = {warp, thread_slot, reg_num};
    endfunction

    initial begin
        reset = 1'b1;
        write_en  = 1'b0;
        wr_addr = 10'b0;
        wr_data = 32'b0;
        src1_addr = 10'b0;
        src2_addr = 10'b0;
        src3_addr = 10'b0;
        tick();
        reset = 1'b0;
        tick();

        // Write test
        wr_addr = addr(3'd2, 2'd1, 5'd5); // warp 2, thread_slot 1, reg 5
        wr_data = 32'h1234_5678;
        write_en = 1'b1;
        tick();

        $display("basic write & check if it copies to all 3 BRAMs");
        src1_addr = addr(3'd2, 2'd1, 5'd5);
        src2_addr = addr(3'd2, 2'd1, 5'd5);
        src3_addr = addr(3'd2, 2'd1, 5'd5);
        tick(); // registered read: value appears after this tick
        check(src1_data, 32'h1234_5678);
        check(src2_data, 32'h1234_5678);
        check(src3_data, 32'h1234_5678);

        // check highest possible address
        wr_addr  = addr(3'd7, 2'd3, 5'd31);
        wr_data  = 32'hABCD_EF12;
        write_en = 1'b1;
        tick();

        // check lowest possible addresss where register is not R0
        wr_addr  = addr(3'd0, 2'd0, 5'd1);
        wr_data  = 32'hFFFF_FFFF;
        write_en = 1'b1;
        tick();

        $display("Check write/read to highest and lowest address");
        src1_addr = addr(3'd7, 2'd3, 5'd31);
        src2_addr = addr(3'd0, 2'd0, 5'd1);
        tick();
        check(src1_data, 32'hABCD_EF12);
        check(src2_data, 32'hFFFF_FFFF);

        $display("Check R0 hardwired to 0 for every thread in every warp");
        // R0 is hardwired to 0 for every warp
        // write to register_num 0 must be dropped
        for (int warp = 0; warp < 8; warp++) begin
            for (int thread_slot = 0; thread_slot < 4; thread_slot++) begin
                wr_addr = addr(warp[2:0], thread_slot[1:0], 5'd0); // register_num = 0
                wr_data = 32'hFFFF_FFFF;
                write_en = 1'b1;
                tick();

                src1_addr = addr(warp[2:0], thread_slot[4:0], 5'd0);
                tick();
                check(src1_data, 32'h0000_0000);
            end
        end

        // Simultaneously reading distinct address across all 3 ports in one cycle
        wr_addr  = addr(3'd1, 2'd0, 5'd10);
        wr_data  = 32'hAAAA_AAAA;
        write_en = 1'b1;
        tick();
        wr_addr  = addr(3'd1, 2'd0, 5'd11);
        wr_data  = 32'hBBBB_BBBB;
        write_en = 1'b1;
        tick();
        wr_addr  = addr(3'd1, 2'd0, 5'd12);
        wr_data  = 32'hCCCC_CCCC;
        write_en = 1'b1;
        tick();

        $display("Simultaneous read ports");
        src1_addr = addr(3'd1, 2'd0, 5'd10);
        src2_addr = addr(3'd1, 2'd0, 5'd11);
        src3_addr = addr(3'd1, 2'd0, 5'd12);
        tick();
        check(src1_data, 32'hAAAA_AAAA);
        check(src2_data, 32'hBBBB_BBBB);
        check(src3_data, 32'hCCCC_CCCC);

        // write_en == 0 so no write happens
        $display("write_en=0 means no write (src1 != 0x11111111)");
        wr_addr  = addr(3'd3, 2'd2, 5'd8);
        wr_data  = 32'h1111_1111;
        write_en = 1'b0; // explicitly not writing
        tick();
        src1_addr = addr(3'd3, 2'd2, 5'd8);
        tick();
        check((src1_data === 32'h1111_1111), 1'b0);

        if (errors == 0)
            $display("\nALL TESTS PASSED");
        else
            $fatal(1, "\n%0d TEST(S) FAILED", errors);

        $finish;
    end
endmodule
