`default_nettype none
`timescale 1ns/1ps
module writeback_fifo #(
    parameter int DEPTH = 16,
    parameter int COUNT_DEPTH = $clog2(DEPTH+1)
) (
    input logic clk,
    input logic reset,

    input logic lsu_push,
    input logic [9:0] lsu_addr,
    input logic [31:0] lsu_data,

    input logic fma_push,
    input logic [9:0] fma_addr,
    input logic [31:0] fma_data,

    input logic alu_push,
    input logic [9:0] alu_addr,
    input logic [31:0] alu_data,

    input logic special_reg_push,
    input logic [9:0] special_reg_addr,
    input logic [31:0] special_reg_data,

    input logic pop,

    output logic [9:0] head_addr,
    output logic [31:0] head_data,
    output logic empty,
    output logic full
);
    logic [9:0] addr_q [0:DEPTH-1];
    logic [31:0] data_q [0:DEPTH-1];
    logic [COUNT_DEPTH-1:0] count_q;
    logic [2:0] push_count;

    assign push_count = {1'b0, lsu_push} + {1'b0, fma_push} + {1'b0, alu_push} + {1'b0, special_reg_push};

    integer i;

    assign head_addr = addr_q[0];
    assign head_data = data_q[0];
    assign empty = ~|count_q; // (count_q == 0)
    assign full = (count_q >= DEPTH - 3);

    always_ff @(posedge clk) begin
        if (reset) begin
            count_q <= '0;
        end else begin
            if (pop) begin
                for (i = 0; i < DEPTH-1; i = i + 1) begin
                    addr_q[i] <= addr_q[i+1];
                    data_q[i] <= data_q[i+1];
                end
            end

            if (lsu_push) begin
                addr_q[count_q - pop] <= lsu_addr;
                data_q[count_q - pop] <= lsu_data;
            end

            if (fma_push) begin
                addr_q[count_q - pop + lsu_push] <= fma_addr;
                data_q[count_q  - pop + lsu_push] <= fma_data;
            end

            if (alu_push) begin
                addr_q[count_q  - pop + lsu_push + fma_push] <= alu_addr;
                data_q[count_q  - pop + lsu_push + fma_push] <= alu_data;
            end

            if (special_reg_push) begin
                addr_q[count_q  - pop + lsu_push + fma_push + alu_push] <= special_reg_addr;
                data_q[count_q  - pop + lsu_push + fma_push + alu_push] <= special_reg_data;
            end
            
            // Update count
            count_q <= count_q + push_count - pop;
        end
    end

    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (count_q + push_count <= DEPTH + pop)
                else $fatal(1, "Writeback FIFO overflow!");

            assert (!(pop && empty))
                else $fatal(1, "Writeback FIFO underflow!");
        end
    end
    `endif
endmodule
