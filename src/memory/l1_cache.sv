`default_nettype none
`timescale 1ns/1ps
module l1_cache #(
    parameter int ID_W  = 1,
    parameter int MEM_W = 128   // memory-side beat width: 32, 64, 128, 256 or 512
) (
    input  logic               clk,
    input  logic               reset,

    // client interface (coalescing unit for data, fetch stage for instructions)
    input logic req_valid,
    output logic req_ready,
    input logic [31:0] req_addr,
    input logic [ID_W-1:0] req_id,
    input logic req_write,
    input logic [1023:0] wr_data, // store data
    input logic [31:0] wr_word_en, // which of the 32 words this store overwrites

    output logic rsp_valid, // fires for reads AND writes (write = completion ack)
    output logic [1023:0] rsp_line,
    output logic [ID_W-1:0] rsp_id,

    // flush when the kernel is done
    input logic flush_start,
    output logic flush_done,

    // mem_arbiter interface
    // send out request
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr,  // always line-aligned

    // write request
    output logic mem_wvalid,
    input logic mem_wready,
    output logic mem_wlast,
    output logic [MEM_W-1:0] mem_wdata, // writeback burst, BEATS beats

    input logic [MEM_W-1:0] mem_rdata, // fill burst, BEATS beats
    input logic mem_rvalid,
    input logic mem_rlast
);
    // Burst geometry, all derived from MEM_W
    localparam int BEATS = 1024 / MEM_W;      // beats per 128B line (8 at MEM_W=128)
    localparam int WPB = MEM_W / 32;        // 32-bit words per beat (4 at MEM_W=128)
    localparam int BW = $clog2(BEATS);     // beat counter width (3 at MEM_W=128)

    // Tree PLRU, 3 bits per set.
    function automatic logic [1:0] plru_victim(input logic [2:0] p);
        if (!p[0]) begin // 0 -> LRU is in way0 or way1
            return p[1] ? 2'd1 : 2'd0;
        end else begin   // 1 -> LRU is in way2 or way3
            return p[2] ? 2'd3 : 2'd2;
        end
    endfunction

    // When a way is accessed, flip the bits on its path to point away from it
    function automatic logic [2:0] plru_update(input logic [2:0] p_in, input logic [1:0] way);
        logic [2:0] p;
        p = p_in;
        case (way)
            2'd0 : begin
                p[0] = 1'b1;
                p[1] = 1'b1;
            end
            2'd1 : begin
                p[0] = 1'b1;
                p[1] = 1'b0;
            end
            2'd2 : begin
                p[0] = 1'b0;
                p[2] = 1'b1;
            end
            2'd3 : begin
                p[0] = 1'b0;
                p[2] = 1'b0;
            end
        endcase
        return p;
    endfunction

    typedef enum logic [3:0] {
        IDLE, LOOKUP, RESP,
        WB_REQ, WB_DATA, FILL_REQ, FILL_DATA,
        FLUSH_SCAN, FLUSH_DONE
    } state_t;
    state_t state;

    // Storage
    logic [20:0] tag_mem [16][4]; // Tag array: indexed by SET, all 4 ways read in parallel
    (* ram_style = "distributed" *) logic [1023:0] data_mem [64]; // Data array: indexed by [set][way], single port

    // Per-line metadata
    logic [3:0] valid [16]; // 1 valid bit for each of 4 ways in 16 sets
    logic [3:0] dirty [16]; // 1 dirty bit for each of 4 ways in 16 sets
    logic [2:0] plru [16]; // 3 bits for each of 16 sets

    // Registered request (captured on req_valid && req_ready)
    logic [31:0] r_addr;
    logic [ID_W-1:0] r_id;
    logic r_write;
    logic [31:0] r_wen;
    logic [1023:0] r_wdata;

    logic [20:0] r_tag;
    logic [3:0] r_set;
    assign r_tag = r_addr[31:11];
    assign r_set = r_addr[10:7];

    // data-array address accessed by hit_way or victim_way set in LOOKUP
    logic [3:0] d_set;
    logic [1:0] d_way;

    logic [5:0] d_idx;
    logic [1023:0] line_rd;
    assign d_idx = {d_set, d_way};
    assign line_rd = data_mem[d_idx];

    logic [20:0] victim_tag;
    logic [BW-1:0] beat; // beat counter within a burst
    logic [5:0] f_idx; // flush index to go through all 64 {set,way} cache slots
    logic flushing; // WB_DATA returns to FLUSH_SCAN instead of FILL_REQ

    wire [3:0] f_set = f_idx[5:2];
    wire [1:0] f_way = f_idx[1:0];

    // LOOKUP datapath
    logic [20:0] tag_rd [4];
    logic [3:0] hit_vec;
    logic hit;
    logic [1:0] hit_way;
    logic [1:0] vict_way;

    always_comb begin
        for (int w = 0; w < 4; w++) begin
            tag_rd[w] = tag_mem[r_set][w];
            hit_vec[w] = valid[r_set][w] && (tag_rd[w] == r_tag);
        end
        hit = |hit_vec;

        hit_way = 2'd0; // one-hot to binary
        for (int w = 0; w < 4; w++) if (hit_vec[w]) hit_way = w[1:0];

        vict_way = plru_victim(plru[r_set]);
        for (int w = 3; w >= 0; w--)
            if (!valid[r_set][w]) vict_way = w[1:0]; // empty way (lowest wins)
    end

    // Data array write port. Only accessed during RESP + store or FILL_DATA
    logic data_we;
    logic [31:0] data_wen;
    logic [1023:0] data_wdata;

    always_comb begin
        data_we    = 1'b0;
        data_wen   = '0;
        data_wdata = r_wdata;
        if (state == RESP && r_write) begin
            data_we = 1'b1;
            data_wen = r_wen;
            data_wdata = r_wdata;
        end else if (state == FILL_DATA && mem_rvalid) begin
            data_we    = 1'b1;
            data_wen   = 32'({WPB{1'b1}}) << (beat * WPB);  // enable the WPB words this beat covers
            data_wdata = {BEATS{mem_rdata}};  // replicate; the enable picks the slot
        end
    end

    always_ff @(posedge clk) begin
        if (data_we)
            for (int w = 0; w < 32; w++)
                if (data_wen[w]) data_mem[d_idx][w*32 +: 32] <= data_wdata[w*32 +: 32];
    end

    // Tag array write: only when a fill completes.
    always_ff @(posedge clk) begin
        if (state == FILL_DATA && mem_rvalid && mem_rlast)
            tag_mem[d_set][d_way] <= r_tag;
    end

    // Outputs
    assign req_ready = (state == IDLE && !flush_start) || (state == RESP);

    assign rsp_valid = (state == RESP);
    assign rsp_line = line_rd;
    assign rsp_id = r_id;

    assign mem_req_valid = (state == WB_REQ) || (state == FILL_REQ);
    assign mem_req_write = (state == WB_REQ);
    assign mem_req_addr = (state == WB_REQ) ? {victim_tag, d_set, 7'b0}
                                            : {r_tag,      r_set, 7'b0};
    assign mem_wvalid = (state == WB_DATA);
    assign mem_wdata = line_rd[beat*MEM_W +: MEM_W];
    assign mem_wlast = (beat == BW'(BEATS-1));

    assign flush_done    = (state == FLUSH_DONE);

    // FSM
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            flushing <= 1'b0;
            beat <= '0;
            f_idx <= '0;
        for (int s = 0; s < 16; s++) begin
            valid[s] <= '0;
            dirty[s] <= '0;
            plru[s] <= '0;
        end
        end else begin
            case (state)
                IDLE: begin
                    if (flush_start) begin
                        flushing <= 1'b1;
                        f_idx <= '0;
                        state <= FLUSH_SCAN;
                    end else if (req_valid) begin
                        r_addr <= req_addr; 
                        r_write <= req_write;
                        r_wdata <= wr_data;
                        r_wen <= wr_word_en;
                        r_id <= req_id;
                        state <= LOOKUP;
                    end
                end

                // Compare all 4 tags, decide hit/miss, and settimg the data-array appropriatelt
                LOOKUP: begin
                    d_set <= r_set;
                    if (hit) begin
                        d_way <= hit_way;
                        state <= RESP;
                    end else begin
                        d_way <= vict_way;
                        victim_tag <= tag_rd[vict_way];
                        if (valid[r_set][vict_way] && dirty[r_set][vict_way])
                            state <= WB_REQ; // evicting modified data: save it first
                        else
                            state <= FILL_REQ; // clean or empty victim: just overwrite
                    end
                end

                // Line is resident. rsp_valid is high this cycle; the store merge (if
                // any) happens at this edge through the write port above.
                RESP: begin
                    plru[d_set] <= plru_update(plru[d_set], d_way);   // the ONLY touch site
                    if (r_write) dirty[d_set][d_way] <= 1'b1;

                    if (req_valid) begin // back-to-back accept
                        r_addr <= req_addr;
                        r_write <= req_write;
                        r_wdata <= wr_data;
                        r_wen <= wr_word_en;
                        r_id <= req_id;
                        state <= LOOKUP;
                    end else begin
                        state   <= IDLE;
                    end
                end

                WB_REQ: if (mem_req_ready) begin
                    beat <= '0;
                    state <= WB_DATA;
                end

                // Stream the victim line out, one word per accepted beat.
                WB_DATA: if (mem_wready) begin
                    beat <= beat + 1'b1;
                    if (beat == BW'(BEATS-1)) begin
                        dirty[d_set][d_way] <= 1'b0;
                        if (!flushing) state <= FILL_REQ;
                        else if (f_idx == 6'd63) state <= FLUSH_DONE;
                        else begin
                            f_idx <= f_idx + 6'd1;
                            state <= FLUSH_SCAN;
                        end
                    end
                end

                FILL_REQ: if (mem_req_ready) begin
                    beat <= '0;
                    valid[d_set][d_way] <= 1'b0; // not strictly needed while blocking;
                    state <= FILL_DATA;
                end

                // Write each returning word into the victim slot.
                FILL_DATA: if (mem_rvalid) begin
                    beat <= beat + 1'b1;
                    if (mem_rlast) begin
                        valid[d_set][d_way] <= 1'b1;
                        dirty[d_set][d_way] <= 1'b0;
                        state <= LOOKUP;  // replay: guaranteed hit, then RESP
                    end
                end

                // Walk all 64 entries; write back only the dirty ones.
                FLUSH_SCAN: begin
                    if (valid[f_set][f_way] && dirty[f_set][f_way]) begin
                        d_set      <= f_set;
                        d_way      <= f_way;
                        victim_tag <= tag_mem[f_set][f_way];
                        state      <= WB_REQ;
                    end else if (f_idx == 6'd63) begin
                        state      <= FLUSH_DONE;
                    end else begin
                        f_idx      <= f_idx + 6'd1;
                    end
                end

            FLUSH_DONE: begin // flush_done pulses for this cycle
                flushing <= 1'b0;
                state    <= IDLE;
            end

            default: state <= IDLE;
            endcase
        end
    end
endmodule
