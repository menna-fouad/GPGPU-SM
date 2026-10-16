`default_nettype none
`timescale 1ns/1ps
module mem_expander (
    input logic ui_clk,
    input logic ui_rst,
    input logic init_calib_complete,

    // cmd FIFO (memory ui read side)
    input logic cmd_empty,
    input logic [25:0] cmd_rdata,
    output logic cmd_pop,

    // wdata FIFO (memory ui read side)
    input logic wr_empty,
    input logic [127:0] wr_data,
    output logic wr_pop,

    // rdata FIFO (memory ui write side)
    output logic rd_wen,
    output logic [128:0] rd_wdata,
    input logic rd_full,

    // MIG interface
    output logic app_en,
    output logic [2:0] app_cmd,
    output logic [26:0] app_addr,
    input  logic app_rdy,

    // write data channel
    output logic [127:0] app_wdf_data,
    output logic app_wdf_wren,
    output logic app_wdf_end,
    output logic [15:0]  app_wdf_mask,
    input  logic         app_wdf_rdy,

    // read data channel
    input  logic [127:0] app_rd_data,
    input  logic         app_rd_data_valid
);
    typedef enum logic {
        IDLE, ISSUE
    } state_t;

    state_t state;
    logic is_wr;
    logic [24:0] line_addr;
    logic [2:0] beat;
    logic [2:0] ret_beat;
    logic wr_ok, fire;
    
    assign wr_ok = is_wr ? (!wr_empty && app_wdf_rdy) : 1'b1;
    assign fire = (state == ISSUE) && app_rdy && wr_ok;

    assign cmd_pop = (state == IDLE) & !cmd_empty & init_calib_complete;
    assign wr_pop = fire && is_wr;

    assign app_en = fire;
    assign app_cmd = {2'b0, !is_wr}; // Write command = 000, Read command = 001
    assign app_addr = {1'b0, line_addr[19:0], beat, 3'b0};
    assign app_wdf_data = wr_data;
    assign app_wdf_wren = fire & is_wr;
    assign app_wdf_end = fire & is_wr;
    assign app_wdf_mask = '0; // write all bytes
    
    // request issue
    always_ff @(posedge ui_clk) begin
        if (ui_rst) begin
            state <= IDLE;
            line_addr <= '0;
            beat <= '0;
            is_wr <= '0;
        end else begin
            case (state)
                IDLE : begin
                    if (cmd_pop) begin
                        is_wr <= cmd_rdata[25];
                        line_addr <= cmd_rdata[24:0];
                        beat <= '0;
                        state <= ISSUE;
                    end
                end
                ISSUE : begin
                    if (fire) begin
                        beat <= beat + 1'b1;
                        if (beat == 3'd7) state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

    // read return
    assign rd_wen = app_rd_data_valid;
    assign rd_wdata = {(ret_beat == 3'd7), app_rd_data};

    always_ff @(posedge ui_clk) begin
        if (ui_rst) ret_beat <= '0;
        else if (app_rd_data_valid) ret_beat <= ret_beat + 1;
    end
endmodule
