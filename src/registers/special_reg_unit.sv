module special_reg_unit # (
    parameter [2:0] LANE_NUM // number of lane instance (0-7)
) (
    input logic [2:0] warp_id,
    input logic [1:0] sub_warp_cycle,
    input logic [2:0] special_instr_type, // opcode[2:0]

    output logic [31:0] result,

    // Input warp_id, thread_slot, and dest_register for writeback_arbiter
    input logic [9:0] reg_bank_addr_in,

    // Output warp_id, thread_slot, and dest_register for writeback_arbiter
    // This is simply the input passed to the output
    output logic [9:0] reg_bank_addr_out,

    input logic valid_in,
    output logic valid_out
);
    logic block_id;
    logic [4:0] thread_id;

    assign block_id = warp_id[2]; // 1 if warp_id >= 4, 0 otherwise
    assign thread_id = ({3'b0, sub_warp_cycle} << 3) + LANE_NUM;

    assign result = special_instr_type[0] ? {27'b0, thread_id} :
                    special_instr_type[1] ? {29'b0, warp_id} : {31'b0, block_id};
    assign reg_bank_addr_out = reg_bank_addr_in;
    assign valid_out = valid_in;
endmodule