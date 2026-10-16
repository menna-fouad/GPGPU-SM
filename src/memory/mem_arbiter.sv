`default_nettype none
`timescale 1ns/1ps
module mem_arbiter #(
    parameter int MEM_W = 128
) (
    input logic clk,
    input logic reset,
    
    // I$ and D$ cache controls
    input logic i_cache_req_valid,
    input logic d_cache_req_valid,
    input logic d_cache_req_write,
    input logic [31:0] i_cache_req_addr,
    input logic [31:0] d_cache_req_addr,
    output logic i_cache_req_ready,
    output logic d_cache_req_ready,

    // D$ cache write data
    input logic d_cache_wvalid,
    input logic d_cache_wlast,
    input logic [MEM_W-1:0] d_cache_wdata,
    output logic d_cache_wready,

    // I$ and D$ cache read data
    output logic [MEM_W-1:0] i_cache_rdata,
    output logic [MEM_W-1:0] d_cache_rdata,
    output logic i_cache_rvalid,
    output logic d_cache_rvalid,
    output logic i_cache_rlast,
    output logic d_cache_rlast,

    // signals to & from CDC FIFOs
    input logic arb_cmd_ready,
    input logic arb_wready, // !wr_full
    input logic rsp_valid, // !rd_empty
    input logic rsp_last,
    input logic [MEM_W-1:0] rsp_data,

    output logic arb_cmd_valid,
    output logic arb_cmd_write,
    output logic [31:0] arb_cmd_addr,
    output logic arb_wvalid,
    output logic [MEM_W-1:0] arb_wdata
);
    typedef enum logic [1:0] {
        IDLE, WDATA, RDATA
    } state_t;

    state_t state;

    typedef enum logic {
        ICACHE, DCACHE
    } choose_t;

    choose_t owner;
    choose_t last_owner;

    choose_t sel;
    logic sel_valid;
    assign sel = choose_t'((i_cache_req_valid && d_cache_req_valid) ? (last_owner == ICACHE) ? DCACHE : ICACHE
                 : i_cache_req_valid ? ICACHE
                 : d_cache_req_valid ? DCACHE
                 : last_owner);
    
    assign sel_valid = (i_cache_req_valid || d_cache_req_valid);

    assign arb_cmd_valid = (state == IDLE) && sel_valid;
    assign arb_cmd_write = (sel == ICACHE) ? 1'b0 : d_cache_req_write;
    assign arb_cmd_addr = (sel == ICACHE) ? i_cache_req_addr : d_cache_req_addr;

    assign i_cache_req_ready = (state == IDLE) && sel_valid && (sel == ICACHE) && arb_cmd_ready;
    assign d_cache_req_ready = (state == IDLE) && sel_valid && (sel == DCACHE) && arb_cmd_ready;

    assign arb_wvalid = (state == WDATA) && ((owner == ICACHE) ? 1'b0 : d_cache_wvalid);
    assign arb_wdata = (owner == ICACHE) ? {MEM_W{1'b0}} : d_cache_wdata;
    assign d_cache_wready = (state == WDATA && owner == DCACHE && arb_wready);

    logic beat_valid;
    assign beat_valid = (state == RDATA) && rsp_valid;

    assign i_cache_rvalid = beat_valid && (owner == ICACHE);
    assign d_cache_rvalid = beat_valid && (owner == DCACHE);

    assign i_cache_rdata = rsp_data;
    assign d_cache_rdata = rsp_data;

    assign i_cache_rlast = i_cache_rvalid && rsp_last;
    assign d_cache_rlast = d_cache_rvalid && rsp_last;

    always_ff @(posedge clk) begin
        if (reset) begin
            owner <= ICACHE;
            last_owner <= ICACHE;
            state <= IDLE;
        end else begin
            case (state)
                IDLE : begin
                    if (arb_cmd_valid && arb_cmd_ready) begin
                        owner <= sel;
                        last_owner <= sel;
                        state <= state_t'(arb_cmd_write ? WDATA : RDATA);
                    end
                end
                WDATA : begin
                    if (arb_wvalid && arb_wready && owner == DCACHE && d_cache_wlast)
                        state <= IDLE;
                end
                RDATA : begin
                    if (beat_valid && rsp_last)
                        state <= IDLE;
                end
                default : state <= IDLE;
            endcase
        end
    end
endmodule
