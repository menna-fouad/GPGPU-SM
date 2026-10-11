module sm_top(
    input logic clk,
    input logic reset,

    input logic kernel_start,
    input logic [3:0] num_warps,
    output logic kernel_done,

    // MIG interface
    output logic app_en,
    output logic [2:0] app_cmd,
    output logic [26:0] app_addr,
    input  logic app_rdy,

    // write data channel
    output logic [127:0] app_wdf_data,
    output logic app_wdf_wren,
    output logic app_wdf_end,
    output logic [15:0] app_wdf_mask,
    input  logic app_wdf_rdy,

    // read data channel
    input  logic [127:0] app_rd_data,
    input  logic app_rd_data_valid
);
    logic fetch_valid, wb_buffer_full, sub_warp_valid;
    logic [1:0] sub_warp_cycle;

    sub_warp_counter u_sub_warp_counter (
        .clk(clk),
        .reset(reset),
        .fetch_valid(fetch_valid), // from fetch_stage
        .buffer_full(wb_buffer_full), // from writeback_arbiter
        .sub_warp_cycle(sub_warp_cycle),
        .sub_warp_valid(sub_warp_valid)
    );

    logic dec_done_detect;
    logic [7:0] commit_done;
    logic [7:0] recon_push2_done_arr;

    logic [2:0] ws_curr_warp, ws_next_warp;
    logic ws_issue_valid;

    warp_scheduler u_warp_sheduler (
        .clk(clk),
        .reset(reset),
        .kernel_start(kernel_start),
        .num_warps(num_warps),
        .commit_done(commit_done), // from commit_tracker
        .push2_done(recon_push2_done_arr), // from recon_pc
        .sub_warp_cycle(sub_warp_cycle), // from u_sub_warp_counter
        .sub_warp_valid(sub_warp_valid), // from u_sub_warp_counter
        .buffer_full(wb_buffer_full), // from writeback_arbiter
        .done_detect(dec_done_detect), // from decode
        .curr_warp(ws_curr_warp),
        .next_warp(ws_next_warp),
        .issue_valid(ws_issue_valid),
        .kernel_done(kernel_done)
    );

    // recon_stack x8
    // recon_stack outputs
    logic [7:0][31:0] recon_top_mask_arr;
    logic [7:0][31:0] recon_top_pc_arr;
    logic [7:0][31:0] recon_top_recon_pc_arr;

    // Mask split unit outputs routed to reconvergence stacks
    logic [7:0] ms_push2_valid;
    logic [31:0] ms_push2_mask_taken;
    logic [31:0] ms_push2_mask_not_taken;
    logic [31:0] ms_push2_pc_taken;
    logic [31:0] ms_push2_pc_fallthrough;
    logic [31:0] ms_push2_recon_pc;

    // Current PC signals (to be connected later)
    logic [7:0] ms_curr_pc_valid;
    logic [31:0] curr_pc_update;
    assign curr_pc_update = ms_push2_pc_fallthrough;

    genvar gi;
    generate
        for (gi = 0; gi < 8; ++gi) begin : g_recon
            recon_stack #(.DEPTH(8)) u_recon (
                .clk(clk),
                .reset(reset),
                .init_push(kernel_start && (gi < num_warps)),
                .init_mask(32'hFFFF_FFFF),
                .init_pc(32'b0),
                .init_recon_pc(32'hFFFF_FFFF),
                .push2_valid(ms_push2_valid[gi]),
                .push2_mask_taken(ms_push2_mask_taken),
                .push2_mask_not_taken(ms_push2_mask_not_taken),
                .push2_pc_taken(ms_push2_pc_taken),
                .push2_pc_fallthrough(ms_push2_pc_fallthrough),
                .push2_recon_pc(ms_push2_recon_pc),
                .current_pc_valid(ms_curr_pc_valid[gi]),
                .current_pc(curr_pc_update),
                .top_mask(recon_top_mask_arr[gi]),
                .top_pc(recon_top_pc_arr[gi]),
                .top_recon_pc(recon_top_recon_pc_arr[gi]),
                .stack_empty(),
                .stack_full(),
                .push2_done(recon_push2_done_arr[gi])
            );
        end
    endgenerate

    logic [31:0] fs_instr, fs_instr_pc;
    logic consume;

    logic ic_ready, ic_req_valid;
    logic [31:0] ic_addr;
    logic [127:0] ic_data;

    assign consume = ws_issue_valid && ~|sub_warp_cycle && sub_warp_valid && !wb_buffer_full;

    fetch_stage u_fetch (
        .clk(clk),
        .reset(reset),
        .kernel_launch(kernel_start),
        .issue_valid(ws_issue_valid),
        .next_warp(ws_next_warp),
        .top_pc(recon_top_pc_arr[ws_next_warp]),
        .recon_pc(recon_top_recon_pc_arr[ws_next_warp]),
        .consume(consume),
        .icache_ready(ic_ready),
        .icache_data(ic_data),
        .icache_req_valid(ic_req_valid),
        .icache_addr(ic_addr),
        .fetch_valid(fetch_valid),
        .instr(fs_instr),
        .instr_pc(fs_instr_pc)
    );

    logic [31:0] il_instr, il_instr_pc;
    logic [9:0] il_src1_addr, il_src2_addr, il_src3_addr;

    instruction_latch u_instruction_latch (
        .clk(clk),
        .reset(reset),
        .consume(consume),
        .buffer_full(wb_buffer_full),
        .sub_warp_cycle(sub_warp_cycle),
        .next_warp(ws_next_warp),
        .curr_warp(ws_curr_warp),
        .buf_instr(fs_instr),
        .buf_instr_pc(fs_instr_pc),
        .instr_q(il_instr),
        .instr_pc_q(il_instr_pc),
        .src1_addr(il_src1_addr),
        .src2_addr(il_src2_addr),
        .src3_addr(il_src3_addr)
    );

    logic dec_sub_warp_valid;
    logic [1:0] dec_sub_warp_cycle;
    logic [5:0] dec_opcode;
    logic [7:0] dec_alu_valid, dec_fma_valid, dec_special_reg_valid;
    logic [9:0] dec_dest_addr;
    logic [15:0] dec_imm;
    logic [31:0] dec_instr_pc;

    decode_stage u_decode (
        .clk(clk),
        .reset(reset),
        .buffer_full(wb_buffer_full),
        .sub_warp_valid(sub_warp_valid),
        .sub_warp_cycle(sub_warp_cycle),
        .curr_warp(ws_curr_warp),
        .active_mask(recon_top_mask_arr[ws_curr_warp]),
        .instr(il_instr),
        .instr_pc(il_instr_pc),
        .sub_warp_valid_q(dec_sub_warp_valid),
        .sub_warp_cycle_q(dec_sub_warp_cycle),
        .opcode_q(dec_opcode),
        .done_detect(dec_done_detect),
        .alu_valid_q(dec_alu_valid),
        .fma_valid_q(dec_fma_valid),
        .special_reg_valid_q(dec_special_reg_valid),
        .dest_addr_q(dec_dest_addr),
        .imm_q(dec_imm),
        .instr_pc_q(dec_instr_pc)
    );

    logic [7:0][31:0] reg_src1_data, reg_src2_data, reg_src3_data;
    logic [7:0] wb_rf_write_enable;
    logic [7:0][9:0] wb_rf_write_addr_arr;
    logic [7:0][31:0] wb_rf_write_data;

    generate
        for (gi = 0; gi < 8; ++gi) begin : gen_reg_bank
            reg_file u_reg_file (
                .clk(clk),
                .reset(reset),

                // source addresses from instruction latch
                .src1_addr(il_src1_addr),
                .src2_addr(il_src2_addr),
                .src3_addr(il_src3_addr),

                // write data from writeback_arbiter
                .write_en(wb_rf_write_enable[gi]),
                .wr_addr(wb_rf_write_addr_arr[gi]),
                .wr_data(wb_rf_write_data[gi]),

                .src1_data(reg_src1_data[gi]),
                .src2_data(reg_src2_data[gi]),
                .src3_data(reg_src3_data[gi])
            );
        end
    endgenerate

    logic [7:0] alu_valid_out, alu_branch_taken;
    logic [7:0][31:0] alu_result;

    logic [7:0] alu_is_branch_arr, alu_is_load_arr, alu_is_store_arr, alu_sub_warp_valid_arr;
    logic [7:0][1:0] alu_sub_warp_cycle_arr;
    logic [7:0][31:0] alu_branch_pc_arr;
    logic [7:0][5:0] alu_recon_offset_arr;
    
    logic [7:0][9:0] alu_reg_bank_addr_out;
    logic [7:0][31:0] alu_src2_out;

    generate
        for (gi = 0; gi < 8; ++gi) begin : gen_int_alu
            int_alu u_int_alu (
                .clk(clk),
                .reset(reset),
                .valid_in(dec_alu_valid[gi]),
                .buffer_full(wb_buffer_full),
                .sub_warp_valid_in(dec_sub_warp_valid),
                .sub_warp_cycle_in(dec_sub_warp_cycle),
                .reg_bank_addr_in(dec_dest_addr),
                .opcode(dec_opcode),
                .src1(reg_src1_data[gi]),
                .src2(reg_src2_data[gi]),
                .instr_pc(dec_instr_pc),
                .offset(dec_imm),
                .valid_out(alu_valid_out[gi]),
                .branch_taken(alu_branch_taken[gi]),
                .result(alu_result[gi]),
                
                // outputs for writeback_arbiter
                .sub_warp_valid_out(alu_sub_warp_valid_arr[gi]),
                .sub_warp_cycle_out(alu_sub_warp_cycle_arr[gi]),
                .reg_bank_addr_out(alu_reg_bank_addr_out[gi]),

                // Instruction information
                .is_branch(alu_is_branch_arr[gi]),
                .is_load(alu_is_load_arr[gi]),
                .is_store(alu_is_store_arr[gi]),
                .branch_pc_out(alu_branch_pc_arr[gi]),
                .push2_pc_recon_offset(alu_recon_offset_arr[gi]),
                .src2_out(alu_src2_out[gi]) // needed for LSU store instruction
            );
        end
    endgenerate

    wire alu_is_branch = alu_is_branch_arr[0];
    wire alu_is_load = alu_is_load_arr[0];
    wire alu_is_store = alu_is_store_arr[0];
    wire alu_sub_warp_valid = alu_sub_warp_valid_arr[0];
    wire [1:0] alu_sub_warp_cycle = alu_sub_warp_cycle_arr[0];
    wire [9:0] alu_reg_bank_addr = alu_reg_bank_addr_out[0];
    wire [31:0] alu_branch_pc = alu_branch_pc_arr[0];
    wire [5:0] alu_push2_pc_recon_offset = alu_recon_offset_arr[0];

    mask_split_unit u_mask_split (
        .clk(clk),
        .reset(reset),
        .buffer_full(wb_buffer_full),
        .sub_warp_cycle(alu_sub_warp_cycle),
        .sub_warp_valid(alu_sub_warp_valid),
        .is_branch(alu_is_branch),
        .is_valid(alu_valid_out),
        .branch_taken_bits(alu_branch_taken),
        .branch_pc(alu_branch_pc),
        .push2_pc_recon_offset(alu_push2_pc_recon_offset),
        .pc_taken(alu_result[0]),
        .reg_bank_addr(alu_reg_bank_addr),
        .push2_mask_taken(ms_push2_mask_taken),
        .push2_mask_not_taken(ms_push2_mask_not_taken),
        .push2_pc_taken(ms_push2_pc_taken),
        .push2_pc_fallthrough(ms_push2_pc_fallthrough),
        .push2_recon_pc(ms_push2_recon_pc),
        .recon_push2_valid(ms_push2_valid),
        .recon_current_pc_valid(ms_curr_pc_valid)
    );

    logic [7:0] fma_valid_out;
    logic [7:0][31:0] fma_result;
    logic [7:0][9:0] fma_reg_bank_addr_out;

    generate
        for (gi = 0; gi < 8; ++gi) begin : gen_fma
            fp32_fma u_fma (
                .clk(clk),
                .reset(reset),
                .valid_in(dec_fma_valid[gi]),
                .buffer_full(wb_buffer_full),
                .src1(reg_src1_data[gi]),
                .src2(reg_src2_data[gi]),
                .src3(reg_src3_data[gi]),
                .reg_bank_addr_in(dec_dest_addr),
                .result(fma_result[gi]),
                .valid_out(fma_valid_out[gi]),
                .reg_bank_addr_out(fma_reg_bank_addr_out[gi])
            );
        end
    endgenerate

    wire [9:0] fma_reg_bank_addr = fma_reg_bank_addr_out[0];

    logic [7:0][31:0] sp_reg_result;
    logic [7:0][9:0] sp_reg_bank_addr_out;
    logic [7:0] sp_reg_valid_out;

    generate
        for (gi = 0; gi < 8; ++gi) begin
            special_reg_unit #(.LANE_NUM(gi)) u_special_reg (
                .warp_id(dec_dest_addr[9:7]),
                .sub_warp_cycle(dec_sub_warp_cycle),
                .special_instr_type(dec_opcode[2:0]),
                .result(sp_reg_result[gi]),
                .reg_bank_addr_in(dec_dest_addr),
                .reg_bank_addr_out(sp_reg_bank_addr_out[gi]),
                .valid_in(dec_special_reg_valid[gi]),
                .valid_out(sp_reg_valid_out[gi])
            );
        end
    endgenerate

    wire [9:0] sp_reg_bank_addr = sp_reg_bank_addr_out[0];

    logic [7:0] lsu_valid_out;
    logic [7:0][31:0] lsu_result;
    logic [9:0] lsu_reg_bank_addr;

    logic [7:0] wb_buffer_full_arr;

    generate
        for (gi = 0; gi < 8; ++gi) begin
            writeback_arbiter u_writeback_arbiter (
                .clk(clk),
                .reset(reset),

                .alu_data(alu_result[gi]),
                .fma_data(fma_result[gi]),
                .lsu_data(lsu_result[gi]),
                .special_reg_data(sp_reg_result[gi]),

                .alu_addr(alu_reg_bank_addr),
                .fma_addr(fma_reg_bank_addr),
                .lsu_addr(lsu_reg_bank_addr),
                .special_reg_addr(sp_reg_bank_addr),

                .alu_valid(alu_valid_out[gi]),
                .fma_valid(fma_valid_out[gi]),
                .lsu_valid(lsu_valid_out[gi]),
                .special_reg_valid(sp_reg_valid_out[gi]),

                .is_branch(alu_is_branch),
                .is_load(alu_is_load),
                .is_store(alu_is_store),

                .rf_write_addr(wb_rf_write_addr_arr[gi]),
                .rf_write_data(wb_rf_write_data[gi]),
                .rf_write_enable(wb_rf_write_enable[gi]),
                
                .buffer_full(wb_buffer_full_arr[gi])
            );
        end
    endgenerate

    assign wb_buffer_full = |wb_buffer_full_arr;

    commit_tracker u_commit_tracker (
        .clk(clk),
        .reset(reset),
        .recon_top_mask_arr(recon_top_mask_arr),
        .rf_write_enable(wb_rf_write_enable),
        .rf_write_addr(wb_rf_write_addr_arr),
        .commit_done(commit_done)
    );

    
endmodule
