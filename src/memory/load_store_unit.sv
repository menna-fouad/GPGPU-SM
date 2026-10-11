module load_store_unit (
    input logic clk,
    input logic reset,
    input logic wb_buffer_full,

    // input transaction data from memory coalescing unit
    input logic txn_valid,
    input logic txn_is_load,
    input logic txn_last,
    input logic [2:0] txn_warp,
    input logic [4:0] txn_dst,
    input logic [31:0] txn_match_mask,
    input logic [31:0][4:0] txn_word_sel,

    // input data from data cache
    input logic rsp_valid,
    input logic [1023:0] rsp_line,
    // input logic [ID_W-1:0] rsp_id, (only relevant once cache becomes non-blocking)

    // outputs to writeback_arbiter
    output logic [7:0] lsu_valid,
    output logic [9:0] lsu_addr,
    output logic [7:0][31:0] lsu_data,
    
    // output to warp scheduler to clear warp
    // issuing a store instruction since it
    // doesn't write a result to a register
    output logic [7:0] store_done
);
    logic outstanding_valid;
    logic outstanding_is_load;
    logic outstanding_last;
    logic [2:0] outstanding_warp;
    logic [4:0] outstanding_dst;
    logic [31:0] outstanding_match_mask;
    logic [31:0][4:0] outstanding_word_sel;

    logic [7:0][31:0][31:0] slot_data;
    logic [7:0][31:0] slot_mask;
    logic [7:0][4:0] slot_dst;

    // registering transaction meta data
    always_ff @(posedge clk) begin
        if (reset) begin
            outstanding_valid <= 1'b0;
        end else begin
            if (txn_valid) begin
                outstanding_valid <= 1'b1;
                outstanding_is_load <= txn_is_load;
                outstanding_last <= txn_last;
                outstanding_warp <= txn_warp;
                outstanding_dst <= txn_dst;
                outstanding_match_mask <= txn_match_mask;
                outstanding_word_sel <= txn_word_sel;
            end else if (rsp_valid) begin
                outstanding_valid <= 1'b0;
            end
        end
    end

    logic wb_done;

    // accumulate warp data from data cache response
    always_ff @(posedge clk) begin
        if (reset) begin
            slot_mask <= '0;
        end else begin
            if (wb_done)
                slot_mask[wb_warp] <= '0;
            
            if (outstanding_valid && outstanding_is_load && rsp_valid) begin
                slot_dst[outstanding_warp] <= outstanding_dst;
                slot_mask[outstanding_warp] <= slot_mask[outstanding_warp] | outstanding_match_mask;

                for (int t = 0; t < 32; ++t) begin
                    if (outstanding_match_mask[t]) begin
                        slot_data[outstanding_warp][t] <= rsp_line[outstanding_word_sel[t]*32 +: 32];
                    end
                end
            end
        end
    end

    logic txn_complete;
    assign txn_complete = outstanding_valid && outstanding_last && rsp_valid;
    always_comb begin
        store_done = '0;

        if (txn_complete && !outstanding_is_load)
            store_done[outstanding_warp] = 1'b1;
    end

    logic [7:0][2:0] ready_fifo;
    logic [3:0] ready_count;
    logic fifo_push, fifo_pop, direct_handoff;
    logic wb_active; // wb_done declare above
    logic [2:0] wb_warp;
    logic [1:0] wb_group;
    
    assign fifo_push = txn_complete && outstanding_is_load;
    assign fifo_pop = |ready_count && (!wb_active || wb_done);

    assign direct_handoff = ~|ready_count && fifo_push && (wb_done || !wb_active);

    always_ff @(posedge clk) begin
        if (reset)
            ready_count <= 4'd0;
        else begin
            case ({fifo_push && !direct_handoff, fifo_pop})
                2'b10 : begin // push only
                    ready_fifo[ready_count] <= outstanding_warp;
                    ready_count <= ready_count + 4'd1;
                end

                2'b01 : begin // pop only
                    for (int i = 0; i < 7; ++i) begin
                        ready_fifo[i] <= ready_fifo[i + 1];
                    end
                    ready_count <= ready_count - 4'd1;
                end

                2'b11 : begin // push and pop
                    for (int i = 0; i < 7; ++i)
                        ready_fifo[i] <= ready_fifo[i + 1];
                    
                    ready_fifo[ready_count - 1] <= outstanding_warp;
                    // ready_count doesn't change since one left and one entered
                end

                default : ; // do nothing
            endcase
        end
    end

    assign wb_done = wb_active && (wb_group == 2'd3) && !wb_buffer_full;
    
    always_ff @(posedge clk) begin
        if (reset) begin
            wb_active <= 1'b0;
        end else begin
            if (fifo_pop || direct_handoff) begin
                wb_active <= 1'b1;
                wb_warp <= fifo_pop ? ready_fifo[0] : outstanding_warp;
                wb_group <= 1'b0;
            end else if (wb_done) begin
                wb_active <= 1'b0;
            end else if (wb_active && !wb_buffer_full) begin
                wb_group <= wb_group + 2'd1;
            end
        end
    end

    always_comb begin
        lsu_valid = '0;
        lsu_data = '0;

        if (wb_active && !wb_buffer_full) begin
            for (int l = 0; l < 8; ++l) begin
                lsu_valid[l] = slot_mask[wb_warp][8*wb_group + l];
                lsu_data[l] = slot_data[wb_warp][8*wb_group + l];
            end
        end

        lsu_addr = {wb_warp, wb_group, slot_dst[wb_warp]};
    end
endmodule
