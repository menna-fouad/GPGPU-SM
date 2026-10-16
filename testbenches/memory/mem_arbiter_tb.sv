`timescale 1ns/1ps
module mem_arbiter_tb;
    localparam int MEM_W = 128;
    localparam int BEATS = 8;
    localparam logic ICA = 1'b0;
    localparam logic DCA = 1'b1;
    localparam logic [31:0] IBASE = 32'h0000_0000;
    localparam logic [31:0] DBASE = 32'h4000_0000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset;

    // DUT instantiation
    logic i_cache_req_valid, d_cache_req_valid, d_cache_req_write; // the I$ is read-only
    logic [31:0] i_cache_req_addr, d_cache_req_addr;
    logic i_cache_req_ready, d_cache_req_ready;
    wire  d_cache_wvalid, d_cache_wlast;
    wire  [MEM_W-1:0] d_cache_wdata;
    logic d_cache_wready;
    logic [MEM_W-1:0] i_cache_rdata, d_cache_rdata;
    logic i_cache_rvalid, d_cache_rvalid, i_cache_rlast, d_cache_rlast;
    logic arb_cmd_ready, arb_wready, rsp_valid, rsp_last;
    logic [MEM_W-1:0] rsp_data;
    logic arb_cmd_valid, arb_cmd_write, arb_wvalid;
    logic [31:0] arb_cmd_addr;
    logic [MEM_W-1:0] arb_wdata;

    mem_arbiter #(.MEM_W(MEM_W)) dut (.*);

    // Write-side outputs of the D$ are JUNK (wvalid=1, wlast=1, bad data)
    // unless it owns the current write burst
    logic d_act = 0, d_wv_r, d_wl_r;
    logic [MEM_W-1:0] d_wd_r;
    assign d_cache_wvalid = d_act ? d_wv_r : 1'b1;
    assign d_cache_wlast  = d_act ? d_wl_r : 1'b1;
    assign d_cache_wdata  = d_act ? d_wd_r : {4{32'hBAD1_0001}};

    // data patterns: every word encodes where it came from
    function automatic logic [MEM_W-1:0] rd_word(input logic [31:0] a, input integer b);
        rd_word = {a, 32'(b), ~a, 32'hC0DEC0DE};
    endfunction
    function automatic logic [MEM_W-1:0] wr_word(input integer id, input logic [31:0] a, input integer b);
        wr_word = {32'(id), a, 32'(b), 32'hFACE0000 + 32'(id)};
    endfunction

    // checks
    integer errors = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("%0t FAIL | %0s", $time, msg);
            end
        end
    endtask
    
    task automatic tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    // knobs set by each phase
    integer k_stall = 0, k_again = 0, k_dly = 0;
    logic   k_host = 0, k_rnd = 0;
    task automatic knobs(input integer stall, input integer again, input logic host,
                         input logic rnd, input integer dly);
        begin k_stall = stall; k_again = again; k_host = host; k_rnd = rnd; k_dly = dly; end
    endtask

    // monitoring using reference model
    logic busy = 0, is_wr = 0, txn_reg = 0, last_win = 0;
    logic [31:0] txn_addr;
    integer rbeat = 0, wbeat = 0;
    integer mon_cmds = 0, mon_rbeats = 0, mon_wbeats = 0;
    integer n_ties = 0, n_cmdstall = 0, n_wstall = 0, n_rgap = 0, n_again = 0;
    logic exp_rv;

    always @(posedge clk) begin
        if (reset) begin
            busy = 0; last_win = 0; rbeat = 0; wbeat = 0;   // reset clears the model too
        end else begin
            check((^{arb_cmd_valid, arb_wvalid, i_cache_req_ready, d_cache_req_ready,
                     d_cache_wready, i_cache_rvalid, d_cache_rvalid}) !== 1'bx, "MONITOR: X/Z on arbiter control output");
            check(!(i_cache_req_ready && d_cache_req_ready), "MONITOR: both caches got req_ready");
            check(!(i_cache_rvalid && d_cache_rvalid),       "MONITOR: both caches got rvalid");

            // cmd channel
            check(!(arb_cmd_valid && busy),            "MONITOR: arb_cmd_valid during an open transaction");
            check(!((i_cache_req_ready || d_cache_req_ready) && busy), "MONITOR: req_ready during an open transaction");
            if (arb_cmd_valid && !arb_cmd_ready) n_cmdstall = n_cmdstall + 1;

            // write channel
            check(arb_wvalid === (busy && is_wr && txn_reg == DCA && d_cache_wvalid),
                  "MONITOR: arb_wvalid != D$ wvalid gated by write state");
            check(d_cache_wready === (busy && is_wr && txn_reg == DCA && arb_wready), "MONITOR: d_cache_wready wrong");
            if (arb_wvalid && !arb_wready) n_wstall = n_wstall + 1;
            if (arb_wvalid && arb_wready) begin
                check(arb_wdata === wr_word(int'(txn_reg), txn_addr, wbeat), "MONITOR: write beat data wrong/misrouted");
                mon_wbeats = mon_wbeats + 1;
                if (wbeat == BEATS-1) begin busy = 0; wbeat = 0; end else wbeat = wbeat + 1;
            end

            // read channel
            exp_rv = busy && !is_wr && rsp_valid;
            check(i_cache_rvalid === (exp_rv && txn_reg == ICA), "MONITOR: i_cache_rvalid wrong (leak or missing)");
            check(d_cache_rvalid === (exp_rv && txn_reg == DCA), "MONITOR: d_cache_rvalid wrong (leak or missing)");
            check(i_cache_rlast  === (i_cache_rvalid && rsp_last), "MONITOR: i_cache_rlast wrong");
            check(d_cache_rlast  === (d_cache_rvalid && rsp_last), "MONITOR: d_cache_rlast wrong");
            if (exp_rv) begin
                check(i_cache_rdata === rd_word(txn_addr, rbeat) && d_cache_rdata === rd_word(txn_addr, rbeat),
                      "MONITOR: read beat data wrong");
                mon_rbeats = mon_rbeats + 1;
                if (rbeat == BEATS-1) begin busy = 0; rbeat = 0; end else rbeat = rbeat + 1;
            end

            // cmd accepted
            if (arb_cmd_valid && arb_cmd_ready) begin
                mon_cmds = mon_cmds + 1;
                txn_reg  = arb_cmd_addr[30];
                check(txn_reg ? d_cache_req_valid : i_cache_req_valid, "MONITOR: command forwarded for a non-requesting cache");
                check(!(txn_reg == ICA && arb_cmd_write), "MONITOR: write command forwarded for the read-only I$");
                if (i_cache_req_valid && d_cache_req_valid) begin
                    n_ties = n_ties + 1;
                    check(txn_reg != last_win, "MONITOR: tie must alternate (D$ first after reset)");
                end
                last_win = txn_reg;
                busy = 1; is_wr = arb_cmd_write; txn_addr = arb_cmd_addr; rbeat = 0; wbeat = 0;
            end
        end
    end

    // 1. DRIVER
    // Random garbage on FIFO-side inputs
    task automatic junk;
        begin rsp_valid = $urandom; rsp_last = $urandom; rsp_data = {$urandom, $urandom, $urandom, $urandom};
              arb_wready = $urandom; end
    endtask

    task automatic drive_w(input logic v, input logic l, input logic [MEM_W-1:0] d);
        begin d_act = 1; d_wv_r = v; d_wl_r = l; d_wd_r = d; end
    endtask

    // 8 D$ write beats. host: random wvalid bubbles (with wlast HIGH, must not end burst) + random wready stalls.
    task automatic wphase(input logic [31:0] addr);
        integer b, g, s;
        begin
            for (b = 0; b < BEATS; b = b + 1) begin
                if (k_host) begin
                    g = $urandom_range(0, 2);
                    repeat (g) begin
                        drive_w(1'b0, 1'b1, ~wr_word(int'(DCA), addr, b));
                        arb_wready = $urandom; tick;
                    end
                end
                drive_w(1'b1, (b == BEATS-1), wr_word(int'(DCA), addr, b));
                if (k_host) begin
                    s = $urandom_range(0, 3);
                    repeat (s) begin arb_wready = 1'b0; tick; end
                end
                arb_wready = 1'b1; tick;                       // beat accepted at this edge
            end
            d_act = 0; arb_wready = $urandom;
        end
    endtask

    // 8 read beats. host: random gaps (junk data/last while rsp_valid=0) including an initial latency.
    task automatic rphase(input logic [31:0] addr);
        integer b, g;
        begin
            for (b = 0; b < BEATS; b = b + 1) begin
                if (k_host) begin
                    g = $urandom_range(0, 3);
                    repeat (g) begin
                        rsp_valid = 1'b0; rsp_last = $urandom; rsp_data = {$urandom, $urandom, $urandom, $urandom};
                        n_rgap = n_rgap + 1; tick;
                    end
                end
                rsp_valid = 1'b1; rsp_data = rd_word(addr, b); rsp_last = (b == BEATS-1);
                tick;
            end
            rsp_valid = 1'b0; rsp_last = $urandom;
        end
    endtask

    integer srv_rd = 0, srv_wr = 0, i_nw = 0, i_nr = 0, d_nw = 0, d_nr = 0;

    // Serve every currently-requesting cache, in correct order and monitor
    // k_again: winner re-requests right after its burst if it doesn't get picked
    // The I$ only ever reads; dw selects a D$ read or write
    task automatic round(input logic iv, input logic dv, input logic dw);
        logic win, wr;
        logic [31:0] addr;
        integer left;
        begin
            left = k_again;
            arb_cmd_ready = 1'b0;
            i_cache_req_valid = iv; i_cache_req_addr = IBASE | (32'($urandom_range(255)) << 7);
            d_cache_req_valid = dv; d_cache_req_write = dw; d_cache_req_addr = DBASE | (32'($urandom_range(255)) << 7);
            if (iv && dv && k_dly > 0) begin          // D$ arrives late, while I$'s command is stalled
                d_cache_req_valid = 1'b0;
                repeat (k_dly) begin junk; tick; end
                d_cache_req_valid = 1'b1;
            end

            while (i_cache_req_valid || d_cache_req_valid) begin
                arb_cmd_ready = 1'b0;
                repeat (k_stall) begin junk; tick; end  // cmd FIFO full + junk responses in IDLE
                junk; arb_cmd_ready = 1'b1;
                #1;
                check(arb_cmd_valid === 1'b1, "round: cmd_valid must be high");
                check((i_cache_req_ready === 1'b1) !== (d_cache_req_ready === 1'b1), "round: exactly one cache must be granted");
                win  = (d_cache_req_ready === 1'b1);
                wr   = win ? d_cache_req_write : 1'b0;
                addr = win ? d_cache_req_addr  : i_cache_req_addr;
                check(arb_cmd_write === wr,  "round: forwarded cmd_write differs from winner's");
                check(arb_cmd_addr  === addr, "round: forwarded cmd_addr differs from winner's");
                tick;                                    // handshake edge
                arb_cmd_ready = $urandom;                // junk during the burst
                if (win) d_cache_req_valid = 1'b0; else i_cache_req_valid = 1'b0;

                if (wr) begin wphase(addr); srv_wr = srv_wr + 1; if (win) d_nw = d_nw + 1; else i_nw = i_nw + 1; end
                else    begin rphase(addr);      srv_rd = srv_rd + 1; if (win) d_nr = d_nr + 1; else i_nr = i_nr + 1; end

                if (left > 0) begin                      // winner immediately asks again
                    left = left - 1; n_again = n_again + 1;
                    if (win) begin d_cache_req_valid = 1; d_cache_req_addr = DBASE | (32'($urandom_range(255)) << 7);
                                   if (k_rnd) d_cache_req_write = $urandom; end
                    else     begin i_cache_req_valid = 1; i_cache_req_addr = IBASE | (32'($urandom_range(255)) << 7); end
                end
            end
            arb_cmd_ready = 1'b0; tick;
        end
    endtask

    // Test sequence
    integer k, seed, extra_cmd = 0, extra_rbeat = 0;
    logic iv, dv;

    initial begin
        seed = 1;
        void'($urandom(seed));

        reset = 1;
        i_cache_req_valid = 0; d_cache_req_valid = 0; d_cache_req_write = 0;
        i_cache_req_addr = 0; d_cache_req_addr = 0;
        arb_cmd_ready = 0; arb_wready = 0; rsp_valid = 0; rsp_last = 0; rsp_data = 0;
        repeat (3) @(posedge clk);
        #1 reset = 0;
        tick;

        $display("1. single requester, ideal FIFOs (I$ rd, D$ rd, D$ wr, D$ wr+rd)");
        knobs(0, 0, 0, 0, 0);
        round(1, 0, 0);
        round(0, 1, 0);
        round(0, 1, 1);
        round(1, 0, 0);
        round(0, 1, 1);  round(0, 1, 0);

        $display("2. single requester, hostile FIFOs (cmd stalls, wready stalls, wvalid bubbles, read gaps)");
        knobs(3, 0, 1, 0, 0);
        round(0, 1, 0);  round(0, 1, 1);  round(1, 0, 0);  round(1, 0, 0);

        $display("3. contention - ties, alternation under re-request, mixed rd/wr, late arrival");
        knobs(0, 3, 0, 0, 0);   round(1, 1, 0);        // D,I,D,I,.. while both keep asking
        knobs(0, 1, 0, 0, 0);   round(1, 1, 1);
        knobs(2, 2, 1, 0, 0);   round(1, 1, 1);
        knobs(2, 1, 0, 0, 2);   round(1, 1, 0);        // D$ shows up 2 cycles into I$'s stall

        $display("4. reset in the middle of a read burst, then a tie (must go to D$ again)");
        knobs(0, 0, 0, 0, 0);
        d_cache_req_valid = 1; d_cache_req_write = 0; d_cache_req_addr = DBASE | 32'h0000_1280;
        arb_cmd_ready = 1; #1;
        check(d_cache_req_ready === 1'b1, "4. D$ read granted");
        tick; d_cache_req_valid = 0; arb_cmd_ready = 0;
        rsp_valid = 1; rsp_data = rd_word(DBASE | 32'h0000_1280, 0); rsp_last = 0;
        tick;                                           // beat 0 delivered
        extra_cmd = 1; extra_rbeat = 1;
        rsp_valid = 0; reset = 1; tick;                 // reset lands mid-burst (last_owner was D$)
        reset = 0; rsp_valid = 1; rsp_last = 1; rsp_data = {4{32'hDEAD_BEEF}};
        tick;                                           // junk response after reset must not leak
        rsp_valid = 0;
        round(1, 1, 0);                                 // first tie after reset: model says D$ wins

        $display("5. random traffic (requesters, rd/wr, stalls, bubbles, re-requests, late arrival)");
        for (k = 0; k < 200; k = k + 1) begin
            knobs($urandom_range(0, 4), $urandom_range(0, 2), $urandom, 1'b1, $urandom_range(0, 3));
            iv = $urandom; dv = $urandom;
            if (!iv && !dv) iv = 1;
            round(iv, dv, $urandom);
        end

        // SCOREBOARD
        repeat (5) tick;
        $display("Scoreboard");
        check(!busy, "transaction still open at end");
        check(mon_cmds   == srv_rd + srv_wr + extra_cmd, "accepted command count mismatch");
        check(mon_rbeats == BEATS*srv_rd + extra_rbeat, "read beat count mismatch");
        check(mon_wbeats == BEATS*srv_wr, "write beat count mismatch");
        $display("Coverage");
        check(n_ties > 0, "no simultaneous requests happened");
        check(n_cmdstall > 0, "cmd channel never stalled");
        check(n_wstall > 0, "write channel never stalled");
        check(n_rgap > 0, "read return never had a gap");
        check(n_again > 0, "no back-to-back re-request happened");
        check(i_nr > 0 && d_nw > 0 && d_nr > 0, "I$ must read, D$ must read and write");
        check(i_nw == 0, "I$ must never write");

        $display("--------------------------------------------------");
        $display("txns %0d (I$: %0d wr %0d rd | D$: %0d wr %0d rd)  ties %0d  re-requests %0d",
                 mon_cmds, i_nw, i_nr, d_nw, d_nr, n_ties, n_again);
        $display("stall cycles: cmd %0d  wdata %0d  read gaps %0d   (%0d checks)", n_cmdstall, n_wstall, n_rgap, checks);
        $display("%s  (%0d errors)", errors == 0 ? "PASS" : "FAIL", errors);
        $display("--------------------------------------------------");
        if (errors != 0) $fatal(1, "FAIL");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL | timeout");
    end
endmodule
