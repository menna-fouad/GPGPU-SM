module mask_split_unit #(
    parameter int NUM_WARPS = 8
) (
    input logic clk,
    input logic reset,
    input logic [1:0] sub_warp_cycle,
    input logic sub_warp_valid,
    input logic buffer_full, // causes ALU to hold results for multiple cycles

    // Information about the branch
    input logic is_branch,
    input logic [7:0] is_valid,
    input logic [7:0] branch_taken_bits, // 1 bit per lane (8 total)
    // Info for calculating reconvergence PC
    input logic [31:0] branch_pc,
    input logic [8:0] push2_pc_recon_offset,
    input logic [31:0] pc_taken,

    // used to identify which warp is currently executing
    input logic [9:0] reg_bank_addr,

    output logic [31:0] push2_mask_taken,
    output logic [31:0] push2_mask_not_taken,
    output logic [31:0] push2_pc_taken,
    output logic [31:0] push2_pc_fallthrough, // branch_pc + 4
    output logic [31:0] push2_recon_pc, // branch_pc + push2_pc_recon_offset

    // Per-warp valid bit, one-hot for currently executing warp
    output logic [NUM_WARPS-1:0] recon_push2_valid
);
    logic accum_done;
    assign accum_done = (&sub_warp_cycle && sub_warp_valid);

    always_ff @(posedge clk) begin
        if (reset) begin
            push2_mask_taken <= 32'b0;
            push2_mask_not_taken <= 32'b0;
        end else if (is_branch && !buffer_full) begin
            case (sub_warp_cycle)
                2'd0: begin
                    push2_mask_taken[7:0] <= sub_warp_valid ? is_valid & branch_taken_bits : push2_mask_taken[7:0];
                    push2_mask_not_taken[7:0] <= sub_warp_valid ? is_valid & ~branch_taken_bits : push2_mask_not_taken[7:0];
                end
                2'd1: begin
                    push2_mask_taken[15:8] <= sub_warp_valid ? is_valid & branch_taken_bits : push2_mask_taken[15:8];
                    push2_mask_not_taken[15:8] <= sub_warp_valid ? is_valid & ~branch_taken_bits : push2_mask_not_taken[15:8];
                end
                2'd2: begin
                    push2_mask_taken[23:16] <= sub_warp_valid ? is_valid & branch_taken_bits : push2_mask_taken[23:16];
                    push2_mask_not_taken[23:16] <= sub_warp_valid ? is_valid & ~branch_taken_bits : push2_mask_not_taken[23:16];
                end
                2'd3: begin
                    push2_mask_taken[31:24] <= sub_warp_valid ? is_valid & branch_taken_bits : push2_mask_taken[31:24];
                    push2_mask_not_taken[31:24] <= sub_warp_valid ? is_valid & ~branch_taken_bits : push2_mask_not_taken[31:24];
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            push2_pc_taken <= 32'b0;
            push2_pc_fallthrough <= 32'b0;
            push2_recon_pc <= 32'b0;
        end else if (!buffer_full) begin
            push2_pc_taken <= pc_taken;
            push2_pc_fallthrough <= branch_pc + 32'd4;
            push2_recon_pc <= branch_pc + {{23{push2_pc_recon_offset[8]}}, push2_pc_recon_offset};
        end
    end

    // warp routing to appropriate recon_stack
    logic [NUM_WARPS-1:0] exec_warp_id;
    always_comb begin
        exec_warp_id = '0;
        exec_warp_id[reg_bank_addr[9:7]] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (reset)
            recon_push2_valid <= 1'b0;
        else
            recon_push2_valid <= exec_warp_id & {NUM_WARPS{accum_done && is_branch && !reset && !buffer_full}};
    end
endmodule