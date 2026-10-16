`default_nettype none
`timescale 1ns/1ps
module instruction_latch (
    input logic clk,
    input logic reset,
    input logic buffer_full,

    input logic consume,
    input logic [1:0] sub_warp_cycle,
    input logic [2:0] next_warp,
    input logic [2:0] curr_warp,

    input logic [31:0] buf_instr,
    input logic [31:0] buf_instr_pc,
    input logic [31:0] active_mask,

    output logic [31:0] instr_q,
    output logic [31:0] instr_pc_q,
    output logic [31:0] active_mask_q,
    output logic [9:0] src1_addr,
    output logic [9:0] src2_addr,
    output logic [9:0] src3_addr
);
    always_ff @(posedge clk) begin
        if (reset) begin
            instr_q <= 32'b0;
            instr_pc_q <= 32'b0;
            active_mask_q <= 32'b0;
            src1_addr <= 10'b0;
            src2_addr <= 10'b0;
            src3_addr <= 10'b0;
        end else if (!buffer_full) begin
            if (consume) begin
                instr_q <= buf_instr;
                instr_pc_q <= buf_instr_pc;
                active_mask_q <= active_mask;
                src1_addr <= {next_warp, sub_warp_cycle, buf_instr[25:21]};
                src2_addr <= {next_warp, sub_warp_cycle, buf_instr[20:16]};
                src3_addr <= {next_warp, sub_warp_cycle, buf_instr[15:11]};
            end else begin
                src1_addr <= {curr_warp, sub_warp_cycle, instr_q[25:21]};
                src2_addr <= {curr_warp, sub_warp_cycle, instr_q[20:16]};
                src3_addr <= {curr_warp, sub_warp_cycle, instr_q[15:11]};
            end
        end
    end
endmodule
