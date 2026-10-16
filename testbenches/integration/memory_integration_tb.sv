`timescale 1ns/1ps
`default_nettype none
module memory_integration_tb;
    logic sm_clk = 0, sm_reset = 1;
    always #5 sm_clk = ~sm_clk; // 100 MHz

    logic icache_req_valid, icache_req_ready;
    logic [31:0] icache_req_addr;
    logic icache_rsp_valid; logic [127:0] icache_instrs;
    logic icache_mem_req_valid, icache_mem_req_ready;
    logic [31:0] icache_mem_req_addr;
    logic [127:0] icache_mem_rdata;
    logic icache_mem_rvalid, icache_mem_rlast;

    l1_icache icache (
        .clk(sm_clk),
        .reset(sm_reset),
        .req_valid(icache_req_valid),
        .req_ready(icache_req_ready),
        .req_addr(icache_req_addr),
        .req_id(1'b0),
        .rsp_valid(icache_rsp_valid),
        .instrs(icache_instrs),
        .rsp_id(),
        .mem_req_valid(icache_mem_req_valid),
        .mem_req_ready(icache_mem_req_ready),
        .mem_req_addr(icache_mem_req_addr),
        .mem_rdata(icache_mem_rdata),
        .mem_rvalid(icache_mem_rvalid),
        .mem_rlast(icache_mem_rlast)
    );

    logic dcache_req_valid, dcache_req_ready;
    logic [31:0] dcache_req_addr;
    logic dcache_req_write; logic [1023:0] dcache_wr_data;
    logic [31:0] dcache_wr_word_en;
    logic dcache_rsp_valid; logic [1023:0] dcache_rsp_line;
    logic dcache_mem_req_valid, dcache_mem_req_ready, dcache_mem_req_write;
    logic [31:0] dcache_mem_req_addr;
    logic dcache_mem_wvalid, dcache_mem_wready, dcache_mem_wlast;
    logic [127:0] dcache_mem_wdata;
    logic [127:0] dcache_mem_rdata;
    logic dcache_mem_rvalid, dcache_mem_rlast;
    logic flush_start, flush_done;

    l1_cache dcache (
        .clk(sm_clk),
        .reset(sm_reset),
        .req_valid(dcache_req_valid),
        .req_ready(dcache_req_ready),
        .req_addr(dcache_req_addr),
        .req_id(1'b0),
        .req_write(dcache_req_write),
        .wr_data(dcache_wr_data),
        .wr_word_en(dcache_wr_word_en),
        .rsp_valid(dcache_rsp_valid),
        .rsp_line(dcache_rsp_line),
        .rsp_id(),
        .flush_start(flush_start),
        .flush_done(flush_done),
        .mem_req_valid(dcache_mem_req_valid),
        .mem_req_ready(dcache_mem_req_ready),
        .mem_req_write(dcache_mem_req_write),
        .mem_req_addr(dcache_mem_req_addr),
        .mem_wvalid(dcache_mem_wvalid),
        .mem_wready(dcache_mem_wready),
        .mem_wlast(dcache_mem_wlast),
        .mem_wdata(dcache_mem_wdata),
        .mem_rdata(dcache_mem_rdata),
        .mem_rvalid(dcache_mem_rvalid),
        .mem_rlast(dcache_mem_rlast)
    );

    logic arb_cmd_ready, arb_wready, arb_rsp_valid, arb_rsp_last;
    logic [127:0] arb_rsp_data;
    logic arb_cmd_valid, arb_cmd_write, arb_wvalid;
    logic [31:0] arb_cmd_addr;
    logic [127:0] arb_wdata;

    mem_arbiter memory_arbiter (
        .clk(sm_clk),
        .reset(sm_reset),
        .i_cache_req_valid(icache_mem_req_valid),
        .d_cache_req_valid(dcache_mem_req_valid),
        .d_cache_req_write(dcache_mem_req_write),
        .i_cache_req_addr(icache_mem_req_addr),
        .d_cache_req_addr(dcache_mem_req_addr),
        .i_cache_req_ready(icache_mem_req_ready),
        .d_cache_req_ready(dcache_mem_req_ready),
        .d_cache_wvalid(dcache_mem_wvalid),
        .d_cache_wlast(dcache_mem_wlast),
        .d_cache_wdata(dcache_mem_wdata),
        .d_cache_wready(dcache_mem_wready),
        .i_cache_rdata(icache_mem_rdata),
        .d_cache_rdata(dcache_mem_rdata),
        .i_cache_rvalid(icache_mem_rvalid),
        .d_cache_rvalid(dcache_mem_rvalid),
        .i_cache_rlast(icache_mem_rlast),
        .d_cache_rlast(dcache_mem_rlast),
        .arb_cmd_ready(arb_cmd_ready),
        .arb_wready(arb_wready),
        .rsp_valid(arb_rsp_valid),
        .rsp_last(arb_rsp_last),
        .rsp_data(arb_rsp_data),
        .arb_cmd_valid(arb_cmd_valid),
        .arb_cmd_write(arb_cmd_write),
        .arb_cmd_addr(arb_cmd_addr),
        .arb_wvalid(arb_wvalid),
        .arb_wdata(arb_wdata)
    );

    logic mem_ui_clk = 1'b0, mem_ui_reset = 1'b1;
    always #6.154 mem_ui_clk = ~mem_ui_clk; // ~81.25 MHz

    logic cmd_full, cmd_empty, cmd_pop;
    logic calib_sync = 1'b0;
    assign arb_cmd_ready = !cmd_full && calib_sync;
    logic [25:0] cmd_rdata;

    // write side: mem_arbiter, read side: mem_expander
    cdc_fifo #(.DATA_WIDTH(26), .DEPTH(4)) cmd_fifo (
        .wclk(sm_clk),
        .wrst(sm_reset),
        .wen(arb_cmd_valid && arb_cmd_ready),
        .wdata({arb_cmd_write, arb_cmd_addr[31:7]}),
        .full(cmd_full),
        .rclk(mem_ui_clk),
        .rrst(mem_ui_reset),
        .ren(cmd_pop),
        .empty(cmd_empty),
        .rdata(cmd_rdata)
    );

    // write side: mem_arbiter, read side: mem_expander

    logic wr_full, wr_pop, wr_empty;
    logic [127:0] wr_rdata;
    assign arb_wready = !wr_full;

    cdc_fifo #(.DATA_WIDTH(128), .DEPTH(16)) wr_fifo (
        .wclk(sm_clk),
        .wrst(sm_reset),
        .wen(arb_wvalid & arb_wready),
        .wdata(arb_wdata),
        .full(wr_full),
        .rclk(mem_ui_clk),
        .rrst(mem_ui_reset),
        .ren(wr_pop),
        .empty(wr_empty),
        .rdata(wr_rdata)
    );

    // write side: mem_expander, read_side: mem_arbiter

    logic rd_wen, rd_ren, rd_full, rd_empty;
    logic [128:0] rd_wdata, rd_rdata;
    assign rd_ren = !rd_empty;
    assign arb_rsp_valid = rd_ren;
    assign {arb_rsp_last, arb_rsp_data} = rd_rdata;

    cdc_fifo #(.DATA_WIDTH(129), .DEPTH(16)) rd_fifo (
        .wclk(mem_ui_clk),
        .wrst(mem_ui_reset),
        .wen(rd_wen),
        .wdata(rd_wdata),
        .full(rd_full),
        .rclk(sm_clk),
        .rrst(sm_reset),
        .ren(rd_ren),
        .empty(rd_empty),
        .rdata(rd_rdata)
    );

    logic init_calib_complete = 1'b0, calib_sync_temp = 1'b0;
    logic app_en, app_rdy;
    logic [2:0] app_cmd;
    logic [26:0] app_addr;

    logic app_wdf_wren, app_wdf_end, app_wdf_rdy;
    logic [15:0] app_wdf_mask;
    logic [127:0] app_wdf_data;

    logic app_rd_data_valid;
    logic [127:0] app_rd_data;

    mem_expander expander (
        .ui_clk(mem_ui_clk),
        .ui_rst(mem_ui_reset),
        .init_calib_complete(init_calib_complete),
        .cmd_empty(cmd_empty),
        .cmd_rdata(cmd_rdata),
        .cmd_pop(cmd_pop),
        .wr_empty(wr_empty),
        .wr_data(wr_rdata),
        .wr_pop(wr_pop),
        .rd_wen(rd_wen),
        .rd_wdata(rd_wdata),
        .rd_full(rd_full),
        // MIG interface
        .app_en(app_en),
        .app_cmd(app_cmd),
        .app_addr(app_addr),
        .app_rdy(app_rdy), // driven in testbench
        .app_wdf_data(app_wdf_data),
        .app_wdf_wren(app_wdf_wren),
        .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask),
        .app_wdf_rdy(app_wdf_rdy), // driven in testbench
        .app_rd_data(app_rd_data), // rd data driven in testbench
        .app_rd_data_valid(app_rd_data_valid) // rd data valid driven in testbench
    );

    always_ff @(posedge sm_clk) begin
        calib_sync_temp <= init_calib_complete;
        calib_sync <= calib_sync_temp;
    end

    // fake MIG
    localparam logic [31:0] K = 32'hA5A50000;

    // beat_no = app_addr[25:3]; byte address of the beat = beat_no*16
    function automatic logic [127:0] init_beat(input logic [22:0] beat_no);
        logic [31:0] ba;
        ba = {5'b0, beat_no, 4'b0};
        return {(ba+32'd12)^K, (ba+32'd8)^K, (ba+32'd4)^K, ba^K}; // word 0 in [31:0]
    endfunction

    logic [127:0] mig_mem [logic [22:0]]; // associative array only holding values written to it
    logic [22:0] rq [$];
    logic [22:0] a;

    always_ff @(posedge mem_ui_clk) begin
        if (mem_ui_reset) begin
            rq.delete();
            app_rd_data_valid <= 1'b0;
            app_rdy <= 1'b0;
            app_wdf_rdy <= 1'b0;
        end else begin
            app_rdy <= init_calib_complete && ($urandom_range(0,3) != 0);
            app_wdf_rdy <= init_calib_complete && ($urandom_range(0,3) != 0);
            app_rd_data_valid <= 1'b0;

            if (app_en && app_rdy) begin
                if (app_cmd == 3'b000) begin
                    assert (app_wdf_wren && app_wdf_rdy) else $error("cmd/data not paired");
                    mig_mem[app_addr[25:3]] = app_wdf_data;
                end else
                    rq.push_back(app_addr[25:3]);
            end

            if (rq.size() > 0 && $urandom_range(0,2) == 0) begin
                a = rq.pop_front();
                app_rd_data <= mig_mem.exists(a) ? mig_mem[a] : init_beat(a);
                app_rd_data_valid <= 1'b1;
            end
        end
    end

    always_ff @(posedge mem_ui_clk) assert (!rd_full);

    logic [31:0] unified_cache [logic [29:0]];
    int error_count = 0;

    function automatic logic [31:0] exp_word(input logic [31:0] addr);
        return (addr & 32'hFFFF_FFFC) ^ K;
    endfunction

    task automatic icache_fetch(
        input logic [31:0] addr,
        output logic [127:0] instrs
    );
        int timeout;
        @(negedge sm_clk);

        icache_req_addr  = addr;
        icache_req_valid = 1'b1;

        timeout = 0;

        // request
        do begin
            @(posedge sm_clk);
            timeout++;

            if (timeout > 100)
                $fatal("I$ request timeout at addr %h", addr);
        end while (!icache_req_ready);

        // Request was accepted on that posedge
        @(negedge sm_clk);
        icache_req_valid = 1'b0;

        // Wait for response
        timeout = 0;
        do begin
            @(posedge sm_clk);
            timeout++;

            if (timeout > 1000)
                $fatal("I$ response timeout at addr %h", addr);
        end while (!icache_rsp_valid);

        instrs = icache_instrs;
    endtask

    task automatic dcache_access(
        input logic write,
        input logic [31:0] addr,
        input logic [31:0] write_data,
        output logic [31:0] data
    );
        int timeout;

        // Send load
        @(negedge sm_clk);

        dcache_req_addr = addr;
        dcache_req_write = write;
        dcache_req_valid = 1'b1;

        dcache_wr_word_en = '0;
        dcache_wr_data = '0;
        if (write) begin
            dcache_wr_word_en[addr[6:2]] = 1'b1;
            dcache_wr_data[32*addr[6:2] +: 32] = write_data;
        end

        timeout = 0;
        do begin
            @(posedge sm_clk);
            timeout++;

            if (timeout > 100)
                $fatal("D$ %s request timeout at addr %h", 
                write ? "store" : "load", addr);
        end while (!dcache_req_ready);

        @(negedge sm_clk);
        dcache_req_valid = 1'b0;
        dcache_req_write = 1'b0;
        dcache_wr_word_en = '0;
        dcache_wr_data = '0;

        // Wait for response
        timeout = 0;
        do begin
            @(posedge sm_clk);
            timeout++;

            if (timeout > 1000)
                $fatal("D$ response timeout at addr %h", addr);

        end while (!dcache_rsp_valid);

        // Pick requested word from returned line
        if (!write)
            data = dcache_rsp_line[32*addr[6:2] +: 32];
        else begin
            unified_cache[addr[31:2]] = write_data;
            data = 'x;
        end
    endtask

    task automatic icache_fetch_check(input logic [31:0] addr);
        for (int i = 0; i < 4; i++) begin
            logic [31:0] expected;

            expected = exp_word({addr[31:7], 7'b0} + (5'(addr[6:2] + i) << 2));

            if (icache_instrs[32*i +: 32] !== expected) begin
                $error("I$ mismatch addr=%h instr=%0d expected=%h got=%h",
                        addr, i, expected, icache_instrs[32*i +: 32]);
                error_count++;
            end
        end
    endtask

    int cmd_count = 0;

    always_ff @(posedge sm_clk) begin
        if (arb_cmd_valid && arb_cmd_ready)
            cmd_count <= cmd_count + 1;
    end

    initial begin
        logic [31:0]  addr;
        logic [31:0]  expected;
        logic [127:0] instrs;

        logic [31:0] data;
        logic [31:0] adjacent_data;
        int cmd_count_before;
        int cmd_count_after;

        logic [31:0] A;
        logic [31:0] store_addr;

        icache_req_valid = 1'b0; dcache_req_valid = 1'b0;
        dcache_req_write = 1'b0; dcache_wr_data = 1024'b0;
        dcache_wr_word_en = 32'b0; flush_start = 1'b0;

        fork
            begin
                repeat (10) @(posedge sm_clk);
                sm_reset = 0;
            end
            begin
                repeat (10) @(posedge mem_ui_clk);
                mem_ui_reset = 0;
            end
            begin
                repeat (10) @(posedge mem_ui_clk);
                init_calib_complete = 1;
            end
        join

        $display("\nTEST 1: I$ miss at word 0");
        addr = 32'h0000_1000;    // word 0 of a fresh cache line
        icache_fetch(addr, instrs);

        for (int i = 0; i < 4; i++) begin
            expected = exp_word(addr + 4*i);

            if (instrs[32*i +: 32] !== expected) begin
                $error("TEST 1 FAIL: instr %0d expected=%h got=%h",
                        i, expected, instrs[32*i +: 32]);
                error_count++;
            end
        end

        // TEST 2: I$ requested word 30 so last 2 words of the 4 words wraparound
        $display("\nTEST 2: I$ request word 30 so last 2 words wraparound");

        addr = 32'h0000_2078;
        // byte offset [6:0] = word_idx[6:2] & byte_offset[1:0]
        // (7'b111 1000)     = 11110 (30)    & 00 (0)

        icache_fetch(addr, instrs);
        icache_fetch_check(addr);

        // TEST 3: I$ hit on line loaded by TEST 2
        $display("\nTEST 3: I$ hit on previously loaded line");

        addr = 32'h0000_2020;   // word 8 of line 0x2000
        cmd_count_before = cmd_count;

        icache_fetch(addr, instrs);
        icache_fetch_check(addr);

        cmd_count_after = cmd_count;
        // A cache hit must NOT generate another external memory command
        if (cmd_count_after !== cmd_count_before) begin
            $error("TEST 3 FAIL: I$ hit generated a new memory command");
            error_count++;
        end
        
        // TEST 4: D$ load miss -> store -> reload
        $display("\nTEST 4: D$ load miss, store, and reload");

        addr = 32'h0000_300C;

        dcache_access(1'b0, addr, 32'b0, data);
        expected = exp_word(addr);
        if (data !== expected) begin
            $error("TEST 4A FAIL: initial load expected=%h got=%h",
                    expected, data);
            error_count++;
        end
        
        cmd_count_before = cmd_count;
        dcache_access(1'b0, addr + 32'd4, 32'b0, adjacent_data);
        cmd_count_after = cmd_count;

        expected = exp_word(addr + 32'd4);
        if (adjacent_data !== expected) begin
            $error("TEST 4B FAIL: adjacent word expected=%h got=%h",
                    expected, adjacent_data);
            error_count++;
        end
        
        if (cmd_count_before !== cmd_count_after) begin
            $error("TEST 4B FAIL: I$ hit generated a new memory command");
            error_count++;
        end

        dcache_access(1'b1, addr, 32'h1234_5678, data);
        dcache_access(1'b0, addr, 32'b0, data);

        if (data !== 32'h1234_5678) begin
            $error("TEST 4C FAIL: reload expected=12345678 got=%h", data);
            error_count++;
        end
        
        dcache_access(1'b0, addr + 32'd4, 32'b0, data);
        expected = exp_word(addr + 32'd4);
        if (data !== expected) begin
            $error("TEST 4D FAIL: adjacent word corrupted, expected=%h got=%h",
                    expected, data);
            error_count++;
        end

        $display("\nTEST 5: Simultaneous I$ and D$ misses");
        addr = 32'h0000_6000;
        icache_fetch(addr, instrs); // fetch request to make next a data request when they are high simultaneously

        fork
            begin
                icache_fetch(32'h0000_7000, instrs); // Icache request
            end
            begin
                dcache_access(1'b0, 32'h0000_8000, 32'b0, data);
            end
            begin
                // Who gets accepted by the arbiter first?
                while (1) begin
                    @(posedge sm_clk);

                    if (dcache_mem_req_valid && dcache_mem_req_ready) begin
                        $display("D$ won first arbitration");
                        break;
                    end
                    else if (icache_mem_req_valid && icache_mem_req_ready) begin
                        $error("TEST 5 FAIL: expected D$ to win first arbitration");
                        error_count++;
                        break;
                    end
                end

                // D$ won. Now I$ must eventually get accepted.
                while (1) begin
                    @(posedge sm_clk);

                    if (icache_mem_req_valid && icache_mem_req_ready) begin
                        $display("I$ went second");
                        break;
                    end
                end
            end
        join

        icache_fetch_check(32'h0000_7000);
        
        expected = exp_word(32'h0000_8000);
        if (data !== expected) begin
            $error("TEST 5 FAIL: D$ data expected=%h got=%h", expected, data);
            error_count++;
        end

        $display("\nTEST 6: Evict dirty line");
        // Load and update a cache line to make it dirty
        A = 32'h0001_0080;
        store_addr = A + 32'h34; // word 13 of the cache line
        dcache_access(1'b1, store_addr, 32'hABCD_EFEF, data);
        
        // Fill up the remaining set with clean lines
        for (int i = 1; i <= 3; i++) begin
            dcache_access(1'b0, A + i*32'h800, 32'b0, data);
            expected = exp_word(A + i*32'h800);

            if (data !== expected) begin
                $error("TEST 6A FAIL: conflicting line %0d expected=%h got=%h",
                        i, expected, data);
                error_count++;
            end
        end

        // Cache line A is now the oldest
        // Requesting a 5th line kicks out A from the cache
        dcache_access(1'b0, A + 4*32'h800, 32'b0, data);

        // Check that cache line actually exists in the MIG memory model
        for (int beat_num = 0; beat_num < 8; beat_num++) begin
            if (!mig_mem.exists((A >> 4) + beat_num)) begin
                $error("TEST 6B FAIL: writeback beat %0d missing", beat_num);
                error_count++;
            end
        end

        // Check the data in the cache line is correct
        for (int beat_num = 0; beat_num < 8; beat_num++) begin
            for (int word = 0; word < 4; word++) begin
                logic [31:0] word_addr;
                logic [31:0] actual_word;

                word_addr = A + beat_num*16 + word*4;

                actual_word = mig_mem[(A >> 4) + beat_num][32*word +: 32];

                if (word_addr == store_addr)
                    expected = 32'hABCD_EFEF;
                else
                    expected = exp_word(word_addr);

                if (actual_word !== expected) begin
                    $error("TEST 6E FAIL: addr=%h expected=%h got=%h",
                            word_addr, expected, actual_word);
                    error_count++;
                end
            end
        end

        // flush the data cache with a dirty line
        $display("\nTEST 7: Flush the data cache with a dirty line");

        A = 32'h0001_0100;       // fresh line/set
        store_addr = A + 32'h28; // word 10

        dcache_access(1'b1, store_addr, 32'h1357_9BDF, data);

        @(negedge sm_clk);
        flush_start = 1'b1;

        while (!flush_done)
            @(posedge sm_clk);

        @(negedge sm_clk);
        flush_start = 1'b0;

        // verify that the dirty line is written to the memory
        for (int beat_num = 0; beat_num < 8; beat_num++) begin
            if (!mig_mem.exists((A >> 4) + beat_num)) begin
                error_count++;
                $error("TEST 7B FAIL: flushed beat %0d missing", beat_num);
            end
        end

        // verify that the correct data got written to memory
        for (int beat_num = 0; beat_num < 8; beat_num++) begin
            for (int word = 0; word < 4; word++) begin
                logic [31:0] word_addr;
                logic [31:0] actual_word;

                word_addr = A + beat_num*16 + word*4;

                actual_word =
                    mig_mem[(A >> 4) + beat_num][32*word +: 32];

                if (word_addr == store_addr)
                    expected = 32'h1357_9BDF;
                else
                    expected = exp_word(word_addr);

                if (actual_word !== expected) begin
                    $error("TEST 7C FAIL: addr=%h expected=%h got=%h",
                            word_addr, expected, actual_word);
                    error_count++;
                end
            end
        end

        if (error_count == 0)
            $display("\nALL TESTS PASSED");
        else
            $fatal(1, "\nTESTBENCH FAILED: %0d ERROR(S)", error_count);
        
        $finish;
    end

    initial begin
        #2000000 $fatal("TIMEOUT");
    end
endmodule
