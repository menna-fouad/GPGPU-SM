`default_nettype none
`timescale 1ns/1ps
module l1_icache # (
    parameter int ID_W = 1,
    parameter int MEM_W = 128
) (
    input logic clk,
    input logic reset,

    // client interface (coalescing unit for data, fetch stage for instructions)
    input logic req_valid,
    output logic req_ready,
    input logic [31:0] req_addr,
    input logic [ID_W-1:0] req_id,

    output logic rsp_valid, // fires for reads AND writes (write = completion ack)
    output logic [127:0] instrs,
    output logic [ID_W-1:0] rsp_id,

    // mem_arbiter interface
    // send out request
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic [31:0] mem_req_addr,  // always line-aligned

    // read request
    input logic [MEM_W-1:0] mem_rdata, // fill burst, BEATS beats
    input logic mem_rvalid,
    input logic mem_rlast
);
    logic [1023:0] rsp_line;

    l1_cache # (.ID_W(ID_W), .MEM_W(MEM_W)) cache (
        .*,
        .req_write(1'b0),
        .wr_word_en(32'b0),
        .wr_data(1024'b0),
        .flush_start(1'b0),
        .flush_done(),
        .mem_req_write(),
        .mem_wvalid(),
        .mem_wready(1'b0),
        .mem_wlast(),
        .mem_wdata()
    );

    logic [4:0] word_idx_q;
    always_ff @(posedge clk)
        if (req_valid && req_ready)
            word_idx_q <= req_addr[6:2];

    assign instrs = {
        rsp_line[32 * 5'(word_idx_q + 5'd3) +: 32],
        rsp_line[32 * 5'(word_idx_q + 5'd2) +: 32],
        rsp_line[32 * 5'(word_idx_q + 5'd1) +: 32],
        rsp_line[32 * 5'(word_idx_q) +: 32]
    };
    // wrap around occurs if the idx goes out of range
endmodule
