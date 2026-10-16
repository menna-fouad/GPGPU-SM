`default_nettype none
`timescale 1ns/1ps
module reg_file (
    input logic clk,
    input logic reset,

    input logic [9:0] src1_addr,
    input logic [9:0] src2_addr,
    input logic [9:0] src3_addr,
    
    input logic write_en,
    input logic [9:0] wr_addr,
    input logic [31:0] wr_data,
    
    output logic [31:0] src1_data,
    output logic [31:0] src2_data,
    output logic [31:0] src3_data
);
    (* ram_style = "block" *) logic  [31:0] bram1 [0:1023];
    (* ram_style = "block" *) logic  [31:0] bram2 [0:1023];
    (* ram_style = "block" *) logic  [31:0] bram3 [0:1023];

    // Reading each source register from its respective BRAM
    always_ff @(posedge clk) begin
        if (reset) begin
            src1_data <= 32'b0;
            src2_data <= 32'b0;
            src3_data <= 32'b0;
        end else begin
            src1_data <= bram1[src1_addr];
            src2_data <= bram2[src2_addr];
            src3_data <= bram3[src3_addr];
        end
    end

    // Write to all three BRAMSs so that they all have the correct data
    always_ff @(posedge clk) begin
        if (!reset && write_en && (wr_addr[4:0] != 5'b0)) begin
            bram1[wr_addr] <= wr_data;
            bram2[wr_addr] <= wr_data;
            bram3[wr_addr] <= wr_data;
        end
    end
endmodule
