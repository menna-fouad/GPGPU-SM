`timescale 1ns/1ps

module main_memory_stub #(
    parameter int MEM_WORDS = 16384,  // 64 KB
    parameter int MEM_W     = 128,    // beat width, must match the cache
    parameter int LATENCY   = 6,      // cycles from read command to first beat
    parameter int STALL_PCT = 0       // % of cycles ready/valid are withheld
) (
    input  logic             clk,
    input  logic             reset,
 
    input  logic             mem_req_valid,
    output logic             mem_req_ready,
    input  logic             mem_req_write,
    input  logic [31:0]      mem_req_addr,
 
    input  logic             mem_wvalid,
    output logic             mem_wready,
    input  logic             mem_wlast,
    input  logic [MEM_W-1:0] mem_wdata,
 
    output logic [MEM_W-1:0] mem_rdata,
    output logic             mem_rvalid,
    output logic             mem_rlast
);
    localparam int BEATS = 1024 / MEM_W;
    localparam int WPB   = MEM_W / 32;
 
    logic [31:0] mem [0:MEM_WORDS-1];
    int n_reads  = 0;   // line reads  (= cache fills),  read by the testbench
    int n_writes = 0;   // line writes (= writebacks),   read by the testbench
 
    initial begin
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'(i * 4);
    end
 
    typedef enum logic [1:0] {
        IDLE, WRITE, WAIT, READ
    } state_t;
    state_t state;
    int base;   // word index of the line being transferred
    int beat;
    int cnt;
 
    function automatic bit go();
        return ($urandom % 100) >= STALL_PCT;
    endfunction
 
    // read data comes straight off the array for the current beat
    always_comb begin
        for (int k = 0; k < WPB; k++) mem_rdata[k*32 +: 32] = mem[base + beat*WPB + k];
    end
 
    always @(posedge clk) begin
        if (reset) begin
            state         <= IDLE;
            mem_req_ready <= 1'b0;
            mem_wready    <= 1'b0;
            mem_rvalid    <= 1'b0;
            mem_rlast     <= 1'b0;
            base          <= 0;
            beat          <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (mem_req_valid && mem_req_ready) begin
                        if (mem_req_addr[6:0] != 7'd0)
                            $display("FAIL memory: unaligned address %h", mem_req_addr);
                        base          <= int'(mem_req_addr >> 2);
                        beat          <= 0;
                        mem_req_ready <= 1'b0;
                        if (mem_req_write) begin
                            n_writes++;
                            state      <= WRITE;
                            mem_wready <= go();
                        end else begin
                            n_reads++;
                            state <= WAIT;
                            cnt   <= LATENCY;
                        end
                    end else begin
                        mem_req_ready <= go();
                    end
                end
 
                WRITE: begin
                    if (mem_wvalid && mem_wready) begin
                        for (int k = 0; k < WPB; k++) mem[base + beat*WPB + k] = mem_wdata[k*32 +: 32];
                        if (mem_wlast != (beat == BEATS-1))
                            $display("FAIL memory: mem_wlast=%b on beat %0d of %0d", mem_wlast, beat, BEATS);
                        if (beat == BEATS-1) begin
                            state      <= IDLE;
                            mem_wready <= 1'b0;
                        end else begin
                            beat       <= beat + 1;
                            mem_wready <= go();
                        end
                    end else begin
                        mem_wready <= go();
                    end
                end
 
                WAIT: begin
                    if (cnt <= 1) begin
                        state      <= READ;
                        mem_rvalid <= go();
                        mem_rlast  <= (BEATS == 1);
                    end else begin
                        cnt <= cnt - 1;
                    end
                end
 
                READ: begin   // no rready: a beat transfers whenever mem_rvalid is high
                    if (mem_rvalid && mem_rlast) begin
                        state      <= IDLE;
                        mem_rvalid <= 1'b0;
                        mem_rlast  <= 1'b0;
                    end else if (mem_rvalid) begin
                        beat       <= beat + 1;
                        mem_rvalid <= go();
                        mem_rlast  <= (beat + 1 == BEATS-1);
                    end else begin
                        mem_rvalid <= go();
                        mem_rlast  <= (beat == BEATS-1);
                    end
                end
            endcase
        end
    end
endmodule

module l1_cache_tb;
    localparam int MEM_W = 128;
    localparam int ID_W  = 4;
    localparam int WORDS = 16384;

    logic clk, reset;

    logic req_valid, req_ready, req_write;
    logic [31:0] req_addr;
    logic [ID_W-1:0] req_id, rsp_id;
    logic [1023:0] wr_data, rsp_line;
    logic [31:0] wr_word_en;
    logic rsp_valid;
    logic flush_start, flush_done;

    logic mem_req_valid, mem_req_ready, mem_req_write;
    logic [31:0] mem_req_addr;
    logic mem_wvalid, mem_wready, mem_wlast;
    logic [MEM_W-1:0] mem_wdata, mem_rdata;
    logic mem_rvalid, mem_rlast;

    int errors, cycle;
    int lat;                      // cycles from handshake to rsp_valid, set by access()
    logic [31:0] ref_mem [0:WORDS-1];

    l1_cache #(.ID_W(ID_W), .MEM_W(MEM_W)) dut (
        .clk(clk),
        .reset(reset),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_addr(req_addr),
        .req_id(req_id),
        .req_write(req_write),
        .wr_data(wr_data),
        .wr_word_en(wr_word_en),
        .rsp_valid(rsp_valid),
        .rsp_line(rsp_line),
        .rsp_id(rsp_id),
        .flush_start(flush_start),
        .flush_done(flush_done),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_wvalid(mem_wvalid),
        .mem_wready(mem_wready),
        .mem_wlast(mem_wlast),
        .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata),
        .mem_rvalid(mem_rvalid),
        .mem_rlast(mem_rlast)
    );

    main_memory_stub #(.MEM_WORDS(WORDS), .MEM_W(MEM_W), .LATENCY(6), .STALL_PCT(25)) memory (
        .clk(clk), .reset(reset),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
        .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_wlast(mem_wlast), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_rlast(mem_rlast)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cycle++;

    function automatic logic [31:0] A(input int tag, input int set, input int word);
        return (32'(tag) << 11) | (32'(set) << 7) | (32'(word) << 2);
    endfunction

    function automatic logic [1023:0] ref_line(input logic [31:0] addr);
        logic [1023:0] l;
        for (int w = 0; w < 32; w++) l[w*32 +: 32] = ref_mem[(addr >> 7) * 32 + w];
        return l;
    endfunction

    task check_eq(input [63:0] actual, input [63:0] expected, input string name);
        if (actual !== expected) begin
            $display("FAIL %s | expected %0d, got %0d", name, expected, actual);
            errors = errors + 1;
        end else begin
            $display("PASS %s | got %0d", name, actual);
        end
    endtask

    // Present one request, return 1 ns after the edge where it was accepted.
    task automatic send(input [31:0] addr, input bit write, input [31:0] wen, input [1023:0] wdata);
        req_addr   = addr;
        req_write  = write;
        wr_word_en = write ? wen : 32'd0;
        wr_data    = wdata;
        req_id     = req_id + 1'b1;
        req_valid  = 1'b1;
        while (!req_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;                        // handshake happened at this edge
        req_valid  = 1'b0;
        if (write)
            for (int w = 0; w < 32; w++)
                if (wen[w]) ref_mem[(addr >> 7) * 32 + w] = wdata[w*32 +: 32];
    endtask

    // One full request/response. Loads are checked word-for-word against ref_mem.
    task automatic access(input [31:0] addr, input bit write, input [31:0] wen, input [1023:0] wdata);
        logic [ID_W-1:0] id;
        send(addr, write, wen, wdata);
        id  = req_id;
        lat = 1;
        while (!rsp_valid) begin @(posedge clk); #1; lat++; end
        if (rsp_id !== id) begin
            $display("FAIL rsp_id | expected %0d, got %0d", id, rsp_id);
            errors++;
        end
        if (!write && rsp_line !== ref_line(addr)) begin
            $display("FAIL load %h | line data does not match reference", addr);
            errors++;
        end
        @(posedge clk); #1;
    endtask

    task automatic load(input [31:0] addr);
        access(addr, 1'b0, 32'd0, '0);
    endtask

    task automatic store(input [31:0] addr, input [31:0] data);
        logic [1023:0] d = '0;
        d[addr[6:2]*32 +: 32] = data;
        access(addr, 1'b1, 32'b1 << addr[6:2], d);
    endtask

    // Flush, then require stub memory == ref_mem. Returns the writeback count.
    task automatic flush_and_check(input string name, output int wbs);
        int w0, bad;
        w0 = memory.n_writes;
        flush_start = 1'b1;
        @(posedge clk); #1;
        flush_start = 1'b0;
        while (!flush_done) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        wbs = memory.n_writes - w0;
        bad = 0;
        for (int i = 0; i < WORDS; i++) if (memory.mem[i] !== ref_mem[i]) bad++;
        check_eq(bad, 0, {name, ": words differing from reference after flush"});
    endtask

    task automatic do_reset();
        reset = 1'b1;
        @(posedge clk); @(posedge clk); #1;
        reset = 1'b0;
    endtask

    // Back-to-back checker: every load response in a stream must match ref_mem.
    bit b2b_on, b2b_mixed;
    int b2b_rsp, b2b_last;   // responses seen, cycle of the latest one
    logic [31:0] b2b_addr;
    always @(negedge clk) begin
        if (b2b_on && rsp_valid) begin
            if (!(b2b_mixed && b2b_rsp % 2 == 0) && rsp_line !== ref_line(b2b_addr)) begin
                $display("FAIL back-to-back response %0d | data does not match reference", b2b_rsp);
                errors++;
            end
            b2b_rsp++;
            b2b_last = cycle;
        end
    end

    int f0, w0, wbs, t0, e0;

    initial begin
        errors = 0; cycle = 0;
        clk = 1'b0; reset = 1'b1;
        req_valid = 1'b0; req_write = 1'b0; req_addr = '0; req_id = '0;
        wr_data = '0; wr_word_en = '0; flush_start = 1'b0;
        b2b_on = 1'b0; b2b_mixed = 1'b0; b2b_rsp = 0; b2b_addr = '0;
        for (int i = 0; i < WORDS; i++) ref_mem[i] = 32'(i * 4);
        do_reset();

        // 1. flushing an empty cache writes nothing
        flush_and_check("empty flush", wbs);
        check_eq(wbs, 0, "empty flush: writebacks");

        // 2. cold miss fills once, then the same line hits in 2 cycles
        f0 = memory.n_reads;
        load(A(2, 1, 1));
        check_eq(memory.n_reads - f0, 1, "cold miss: one fill");
        load(A(2, 1, 1));
        check_eq(memory.n_reads - f0, 1, "hit: no new fill");
        check_eq(lat, 2, "hit: latency in cycles");
        load(A(2, 1, 30));
        check_eq(memory.n_reads - f0, 1, "other word, same line: hit");

        // 3. store hit merges one word; memory keeps the old value (write-back)
        f0 = memory.n_reads; w0 = memory.n_writes;
        store(A(2, 1, 2), 32'hCAFE_0000);
        check_eq(memory.n_reads - f0 + memory.n_writes - w0, 0, "store hit: no memory traffic");
        check_eq(lat, 2, "store hit: acknowledged in 2 cycles");
        check_eq(memory.mem[A(2, 1, 2) >> 2], A(2, 1, 2), "store hit: memory still old");
        load(A(2, 1, 0));   // checks all 32 words: word 2 new, neighbours intact

        // 4. store miss fetches the line first (write-allocate)
        f0 = memory.n_reads; w0 = memory.n_writes;
        store(A(9, 3, 5), 32'hBEEF_0005);
        check_eq(memory.n_reads - f0, 1, "store miss: line fetched");
        check_eq(memory.n_writes - w0, 0, "store miss: nothing written back");
        check_eq(memory.mem[A(9, 3, 5) >> 2], A(9, 3, 5), "store miss: memory still old");

        // 5. filling set 1 evicts the dirty line from test 3 and writes it back
        load(A(3, 1, 0)); load(A(4, 1, 0)); load(A(5, 1, 0));
        w0 = memory.n_writes;
        load(A(6, 1, 0));
        check_eq(memory.n_writes - w0, 1, "dirty eviction: one writeback");
        check_eq(memory.mem[A(2, 1, 2) >> 2], 32'hCAFE_0000, "dirty eviction: store reached memory");
        f0 = memory.n_reads;
        load(A(2, 1, 2));
        check_eq(memory.n_reads - f0, 1, "evicted line: misses when reloaded");
        flush_and_check("tests 2-5", wbs);
        do_reset();

        // 6. tree PLRU: fill L0..L3, touch L0, miss on L4. True LRU would evict
        //    L1; tree PLRU (p0=1 -> ways 2/3, p2=0 -> way 2) evicts L2.
        for (int t = 0; t < 4; t++) load(A(t, 5, 0));
        load(A(0, 5, 0));
        load(A(4, 5, 0));
        f0 = memory.n_reads;
        load(A(0, 5, 0)); load(A(1, 5, 0)); load(A(3, 5, 0));
        check_eq(memory.n_reads - f0, 0, "PLRU: L0, L1, L3 still resident");
        load(A(2, 5, 0));
        check_eq(memory.n_reads - f0, 1, "PLRU: L2 was the victim");
        flush_and_check("PLRU", wbs);
        do_reset();

        // 7. back-to-back: req_valid stays high, one request accepted every 2 cycles
        load(A(1, 7, 0));
        b2b_addr = A(1, 7, 0); b2b_rsp = 0; b2b_on = 1'b1;
        t0 = cycle;
        for (int i = 0; i < 32; i++) send(A(1, 7, i), 1'b0, 32'd0, '0);
        while (b2b_rsp < 32) begin @(posedge clk); #1; end
        check_eq(b2b_last - t0, 64, "back-to-back: 32 hits in 64 cycles");
        // alternate store/load to one line: each load must see the store before it
        b2b_rsp = 0; b2b_mixed = 1'b1; e0 = errors;
        for (int i = 0; i < 16; i++) begin
            logic [1023:0] d;
            d = '0;
            d[i*32 +: 32] = 32'h5700_0000 + i;
            send(A(1, 7, i), 1'b1, 32'b1 << i, d);
            send(A(1, 7, 0), 1'b0, 32'd0, '0);
        end
        while (b2b_rsp < 32) begin @(posedge clk); #1; end
        check_eq(errors - e0, 0, "back-to-back: store then load of same line sees new data");
        b2b_on = 1'b0; b2b_mixed = 1'b0;
        @(posedge clk); #1;

        // 8. flush writes dirty lines once, clears dirty, keeps lines valid
        store(A(0, 9, 1), 32'h1111_1111);
        store(A(1, 9, 1), 32'h2222_2222);
        store(A(2, 10, 1), 32'h3333_3333);
        flush_and_check("first flush", wbs);
        check_eq(wbs >= 3, 1, "first flush: dirty lines written back");
        flush_and_check("second flush", wbs);
        check_eq(wbs, 0, "second flush: writes nothing");
        f0 = memory.n_reads;
        load(A(0, 9, 1)); load(A(2, 10, 1));
        check_eq(memory.n_reads - f0, 0, "after flush: lines still valid");
        do_reset();

        // 9. random: 32 lines (8 tags x 4 sets) competing for 16 slots, so
        //    evictions are constant; loads are checked inside access()
        e0 = errors;
        for (int i = 0; i < 2000; i++) begin
            logic [31:0] addr, wen;
            logic [1023:0] d;
            int kind;
            addr = A($urandom % 8, $urandom % 4, $urandom % 32);
            kind = $urandom % 6;
            for (int w = 0; w < 32; w++) d[w*32 +: 32] = $urandom;
            if (kind < 3)       access(addr, 1'b0, 32'd0, '0);
            else if (kind == 3) access(addr, 1'b1, 32'b1 << addr[6:2], d);  // one word
            else if (kind == 4) access(addr, 1'b1, $urandom, d);            // random mask
            else                access(addr, 1'b1, 32'hFFFF_FFFF, d);        // full line
        end
        check_eq(errors - e0, 0, "random: 2000 ops, load mismatches");
        flush_and_check("random", wbs);

        $display("fills %0d, writebacks %0d", memory.n_reads, memory.n_writes);
        if (errors == 0) $display("ALL TESTS PASSED");
        else $fatal(1, "%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
