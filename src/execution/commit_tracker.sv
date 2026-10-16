`default_nettype none
`timescale 1ns/1ps
module commit_tracker (
    input logic clk,
    input logic reset,

    input logic consume,
    input logic [2:0] ws_next_warp,
    input logic [7:0][31:0] recon_top_mask_arr,

    input logic [7:0] rf_write_enable,
    input logic [7:0][9:0] rf_write_addr, // rf_write_addr[9:7]
    
    output logic [7:0] commit_done
);
    logic [7:0][31:0] pending_mask;
    logic [7:0][31:0] wb_completed_mask, wb_completed_mask_next;
    logic [7:0] warp_complete;

    logic [7:0][2:0] warp_id;
    logic [7:0][1:0] sub_warp_id;

    always_comb begin
        for (int i = 0; i < 8; ++i) begin
            warp_id[i] = rf_write_addr[i][9:7];
            sub_warp_id[i] = rf_write_addr[i][6:5];
        end

        wb_completed_mask_next = wb_completed_mask;
        warp_complete = '0;

        // Record every lane that writes back this cycle
        for (int i = 0; i < 8; ++i) begin
            if (rf_write_enable[i]) begin
                wb_completed_mask_next[warp_id[i]][sub_warp_id[i] * 8 + i] = 1'b1;
            end
        end

        // Check whether all expected threads have written back
        for (int w = 0; w < 8; ++w) begin
            if (pending_mask[w] != 0 && ((wb_completed_mask_next[w] & pending_mask[w]) == pending_mask[w]))
                warp_complete[w] = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pending_mask <= '0;
            wb_completed_mask <= '0;
            commit_done <= '0;
        end else begin
            wb_completed_mask <= wb_completed_mask_next;
            commit_done <= warp_complete;

            for (int w = 0; w < 8; ++w) begin
                if (warp_complete[w]) begin
                    wb_completed_mask[w] <= '0;
                    pending_mask[w] <= '0;
                end
            end

            if (consume) begin
                pending_mask[ws_next_warp] <= recon_top_mask_arr[ws_next_warp];
                wb_completed_mask[ws_next_warp] <= '0;
            end
        end
    end
endmodule
