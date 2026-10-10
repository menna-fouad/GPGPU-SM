module sub_warp_counter(
    input logic clk,
    input logic reset,
    input logic fetch_valid, // from fetch_stage — hold at 3 instead of resetting to 0 for invalid fetch
    input logic buffer_full, // from writeback_arbiter - stall (hold current warp and make it not valid)
    output logic [1:0] sub_warp_cycle,
    output logic sub_warp_valid
);
    logic hold_d;
    assign hold_d = buffer_full || (sub_warp_cycle == 2'd3 && !fetch_valid);
    assign sub_warp_valid = !hold_d;

    always_ff @(posedge clk) begin
        if (reset) begin
            sub_warp_cycle <= 2'd3;
        end else begin
            if (hold_d)
                sub_warp_cycle <= sub_warp_cycle;
            else if (sub_warp_cycle == 2'd3)
                sub_warp_cycle <= 2'd0;
            else
                sub_warp_cycle <= sub_warp_cycle + 2'd1;
        end
    end
endmodule