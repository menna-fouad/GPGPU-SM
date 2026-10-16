module fp32_fma_back2back_tb;
    reg clk, reset, valid_in;
    reg [31:0] src1, src2, src3;
    reg [9:0] reg_bank_addr_in;
 
    wire [31:0] result;
    wire valid_out;
    wire [9:0] reg_bank_addr_out;

    integer errors = 0;
    integer tests = 0;

    fp32_fma dut (
        .clk(clk),
        .reset(reset),
        .valid_in(valid_in),
        .src1(src1),
        .src2(src2),
        .src3(src3),
        .reg_bank_addr_in(reg_bank_addr_in),
        .result(result),
        .valid_out(valid_out),
        .reg_bank_addr_out(reg_bank_addr_out)
    );

    always #5 clk = ~clk;
 
    // Arrays for expected results and tracking which instructions we're currently issuing and checking
    parameter NUM_CASES = 13;
    reg [31:0] expected_result [0:NUM_CASES-1];
    reg [9:0]  expected_tag    [0:NUM_CASES-1];
    integer issue_index;
    integer check_index;
 
    // We check every clock edge and move to the next case if we're not restting and have a valid resylt
    always @(posedge clk) begin
        if (!reset && valid_out) begin
            tests = tests + 1;
            if (result !== expected_result[check_index] || reg_bank_addr_out !== expected_tag[check_index]) begin
                errors = errors + 1;
                $display("FAIL @t=%0t: case #%0d expected result=%h tag=%h | got result=%h tag=%h",
                          $time, check_index, expected_result[check_index], expected_tag[check_index],
                          result, reg_bank_addr_out);
            end else begin
                $display("PASS @t=%0t: case #%0d result=%h tag=%h", $time, check_index, result, reg_bank_addr_out);
            end
            check_index = check_index + 1;
        end
    end
 
    // Task to apply stimulus and store information in arrays
    task issue_case;
        input [31:0] a, b, c, expected;
        input [9:0] tag;
        begin
            expected_result[issue_index] = expected;
            expected_tag[issue_index]    = tag;
            issue_index = issue_index + 1;
 
            @(negedge clk);
            src1 = a; src2 = b; src3 = c;
            reg_bank_addr_in = tag;
            valid_in = 1'b1;
        end
    endtask
 
    initial begin
        clk = 0;
        reset = 1;
        valid_in = 0;
        src1 = 0; src2 = 0; src3 = 0;
        reg_bank_addr_in = 0;
        issue_index = 0;
        check_index = 0;
        repeat (2) @(negedge clk);
        reset = 0;

        issue_case(32'h40400000, 32'h40000000, 32'h3FC00000, 32'h40F00000, 10'h001); // 3*2+1.5=7.5
        issue_case(32'h40400000, 32'h40000000, 32'hBFC00000, 32'h40900000, 10'h002); // 3*2-1.5=4.5
        issue_case(32'h3F800000, 32'h3F800000, 32'hBF800000, 32'h00000000, 10'h003); // 1*1-1=0
        issue_case(32'h3FC00000, 32'h3FC00000, 32'h00000000, 32'h40100000, 10'h004); // 1.5*1.5+0=2.25
        issue_case(32'hC0400000, 32'h40000000, 32'h3FC00000, 32'hC0900000, 10'h005); // -3*2+1.5=-4.5
        issue_case(32'h40400000, 32'hC0000000, 32'h3FC00000, 32'hC0900000, 10'h006); // 3*-2+1.5=-4.5
        issue_case(32'hC0400000, 32'hC0000000, 32'h3FC00000, 32'h40F00000, 10'h007); // -3*-2+1.5=7.5
        issue_case(32'hC0400000, 32'hC0000000, 32'hBFC00000, 32'h40900000, 10'h008); // -3*-2-1.5=4.5
        issue_case(32'hC0400000, 32'h40000000, 32'h3F000000, 32'hC0B00000, 10'h009); // -3*2+0.5=-5.5
 
        // Gap between first and second birst
        @(negedge clk);
        valid_in = 1'b0;
        repeat (3) @(negedge clk);
 
        issue_case(32'h40800000, 32'h40800000, 32'h00000000, 32'h41800000, 10'h00A); // 4*4+0=16
        issue_case(32'h3F800000, 32'h3F800000, 32'h3F800000, 32'h40000000, 10'h00B); // 1*1+1=3
        issue_case(32'hBF800000, 32'h3F800000, 32'h3F800000, 32'h00000000, 10'h00C); // -1*1+1=0
        issue_case(32'h3FC00000, 32'hBF800000, 32'h3FC00000, 32'h00000000, 10'h00D); // 1.5*-1+1.5=0
 
        @(negedge clk);
        valid_in = 1'b0;
        src1 = 0; src2 = 0; src3 = 0;
 
        // Let the pipeline fully drain (4 cycles of latency + margin)
        // before checking final state.
        repeat (8) @(negedge clk);
 
        $display("---------------------------------------------");
        $display("Tests: %0d  Errors: %0d", tests, errors);
        if (check_index != issue_index) begin
            errors = errors + 1;
            $display("FAIL: issued %0d instructions but only checked %0d results -- pipeline dropped result(s)",
                      issue_index, check_index);
        end
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $fatal(1, "SOME TESTS FAILED");
 
        $finish;
    end
endmodule
