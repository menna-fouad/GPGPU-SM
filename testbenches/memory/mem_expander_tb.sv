`timescale 1ns/1ps
`define ERR(msg) begin $display("[%0t] ERROR: %s", $time, msg); errors = errors + 1; end
module mem_expander_tb;

    // clock / reset
    logic ui_clk = 0;
    always #6.154 ui_clk = ~ui_clk;                 // ~81.25 MHz

    logic ui_rst = 1;
    logic init_calib_complete = 0;

    logic cmd_empty, cmd_pop;
    logic [25:0] cmd_rdata;

    logic wr_empty, wr_pop;
    logic [127:0] wr_data;

    logic rd_wen, rd_full = 1'b0;
    logic [128:0] rd_wdata;
    
    logic app_en;
    logic [2:0] app_cmd;
    logic [26:0] app_addr;
    logic app_rdy = 0;
    logic [127:0] app_wdf_data; logic app_wdf_wren, app_wdf_end; logic [15:0] app_wdf_mask;
    logic         app_wdf_rdy = 0;
    logic [127:0] app_rd_data = '0;  logic app_rd_data_valid = 0;

    mem_expander dut (.*);

    // behavioral FIFO models
    logic [25:0] cmd_q [0:1023];
    int cmd_wr = 0, cmd_rd = 0;
    logic [127:0] wr_q [0:4095];
    int wr_wr = 0, wr_rd  = 0;
    assign cmd_empty = (cmd_wr == cmd_rd);
    assign cmd_rdata = cmd_q[cmd_rd];
    assign wr_empty  = (wr_wr == wr_rd);
    assign wr_data   = wr_q[wr_rd];

    // expectations
    bit exp_is_wr [0:4095];
    logic [26:0]  exp_addr  [0:4095];
    logic [127:0] exp_wd    [0:4095];
    int exp_cmd_n = 0;
    logic [127:0] exp_rd_data [0:4095];
    int exp_rd_n = 0;
    logic [127:0] ref_mem [0:127];                  // 16 lines x 8 beats
    logic [127:0] wstage  [0:4095];                 // write beats generated, not yet pushed
    int wstage_n = 0, wstage_pushed = 0;

    // MIG model
    logic [127:0] mig_mem [0:2047]; // indexed by app_addr[13:3]
    logic [127:0] pend_data [0:4095];
    int           pend_t    [0:4095];
    int           pend_head = 0, pend_tail = 0, last_t = 0;

    int p_rdy = 100, p_wdf = 100, p_ret = 100, lat_min = 3, lat_rng = 1;

    // stats
    int errors = 0, cyc = 0;
    int cmd_done = 0, rd_got = 0;
    int n_wr_cmds = 0, n_rd_cmds = 0, n_data_stall = 0, n_rdy_stall = 0;

    // monitor + MIG model
    always @(posedge ui_clk) begin
        cyc = cyc + 1;

        // drive random readiness / read-return (visible after this edge)
        app_rdy     <= ($urandom_range(99) < p_rdy);
        app_wdf_rdy <= ($urandom_range(99) < p_wdf);
        app_rd_data_valid <= 1'b0;
        if (!ui_rst && pend_head != pend_tail && cyc >= pend_t[pend_head]
            && ($urandom_range(99) < p_ret)) begin
            app_rd_data       <= pend_data[pend_head];
            app_rd_data_valid <= 1'b1;
            pend_head = pend_head + 1;
        end

        if (!ui_rst) begin
            // X/Z check on every control output
            if ((^{cmd_pop, wr_pop, rd_wen, app_en, app_wdf_wren, app_wdf_end}) === 1'bx)
                `ERR("X/Z on a control output")
            if (app_en === 1'b1 && (^{app_cmd, app_addr}) === 1'bx)
                `ERR("X/Z on app_cmd/app_addr while app_en is high")

            // FIFO pops
            if (cmd_pop) begin
                if (cmd_empty) `ERR("cmd_pop while cmd FIFO empty")
                cmd_rd <= cmd_rd + 1;
            end
            if (wr_pop) begin
                if (wr_empty) `ERR("wr_pop while wdata FIFO empty")
                wr_rd <= wr_rd + 1;
            end

            // nothing may happen before calibration
            if (!init_calib_complete && (cmd_pop === 1'b1 || app_en === 1'b1))
                `ERR("activity before init_calib_complete")

            // MIG protocol
            if (app_en === 1'b1 && !app_rdy)            `ERR("app_en high while app_rdy low")
            if (app_wdf_wren === 1'b1 && !app_wdf_rdy)  `ERR("app_wdf_wren high while app_wdf_rdy low")
            if (app_wdf_wren === 1'b1 && !(app_en === 1'b1 && app_cmd === 3'b000))
                `ERR("write data without a write command in the same cycle")
            if (app_en === 1'b1 && app_cmd === 3'b000 && !(app_wdf_wren === 1'b1 && app_wdf_end === 1'b1))
                `ERR("write command without data+end in the same cycle")
            if (app_wdf_wren === 1'b1 && app_wdf_mask !== 16'h0000)
                `ERR("app_wdf_mask not zero")

            // coverage-ish stats
            if (dut.state == 1'b1 && dut.is_wr && wr_empty) n_data_stall = n_data_stall + 1;
            if (dut.state == 1'b1 && !app_rdy)              n_rdy_stall  = n_rdy_stall + 1;

            // command accepted by MIG
            if (app_en === 1'b1 && app_rdy) begin
                if (cmd_done >= exp_cmd_n) begin
                    `ERR("unexpected MIG command (more than were requested)")
                end else begin
                    if (app_cmd !== (exp_is_wr[cmd_done] ? 3'b000 : 3'b001))
                        begin $display("[%0t] cmd #%0d: wrong app_cmd %b", $time, cmd_done, app_cmd); errors = errors + 1; end
                    if (app_addr !== exp_addr[cmd_done])
                        begin $display("[%0t] cmd #%0d: wrong app_addr %h expected %h", $time, cmd_done, app_addr, exp_addr[cmd_done]); errors = errors + 1; end
                    if (exp_is_wr[cmd_done]) begin
                        n_wr_cmds = n_wr_cmds + 1;
                        if (app_wdf_data !== exp_wd[cmd_done])
                            begin $display("[%0t] cmd #%0d: wrong write data %h expected %h", $time, cmd_done, app_wdf_data, exp_wd[cmd_done]); errors = errors + 1; end
                        mig_mem[app_addr[13:3]] = app_wdf_data;
                    end else begin
                        n_rd_cmds = n_rd_cmds + 1;
                        begin : sched
                            int t;
                            t = cyc + lat_min + $urandom_range(lat_rng);
                            if (pend_tail != pend_head && t <= last_t) t = last_t + 1;
                            last_t = t;
                            pend_data[pend_tail] = mig_mem[app_addr[13:3]];
                            pend_t[pend_tail]    = t;
                            pend_tail = pend_tail + 1;
                        end
                    end
                    cmd_done = cmd_done + 1;
                end
            end

            // read beat pushed toward the cache
            if (rd_wen === 1'b1) begin
                if (rd_got >= exp_rd_n) begin
                    `ERR("unexpected read beat (more than requested)")
                end else begin
                    if (rd_wdata[127:0] !== exp_rd_data[rd_got])
                        begin $display("[%0t] read beat #%0d: data %h expected %h", $time, rd_got, rd_wdata[127:0], exp_rd_data[rd_got]); errors = errors + 1; end
                    if (rd_wdata[128] !== ((rd_got % 8) == 7))
                        begin $display("[%0t] read beat #%0d: rlast=%b wrong", $time, rd_got, rd_wdata[128]); errors = errors + 1; end
                end
                rd_got = rd_got + 1;
            end
        end
    end

    // helpers
    task push_cmd(input bit wr, input int line);
        int b;
        logic [127:0] w;
        begin
            for (b = 0; b < 8; b = b + 1) begin
                exp_is_wr[exp_cmd_n] = wr;
                exp_addr[exp_cmd_n]  = (line*128 + 16*b) / 2;
                if (wr) begin
                    w = {$urandom, $urandom, $urandom, $urandom};
                    ref_mem[line*8 + b]  = w;
                    exp_wd[exp_cmd_n]    = w;
                    wstage[wstage_n]     = w;
                    wstage_n = wstage_n + 1;
                end else begin
                    exp_rd_data[exp_rd_n] = ref_mem[line*8 + b];
                    exp_rd_n = exp_rd_n + 1;
                end
                exp_cmd_n = exp_cmd_n + 1;
            end
            @(posedge ui_clk); #1;
            cmd_q[cmd_wr] = {wr, line[24:0]};
            cmd_wr = cmd_wr + 1;
        end
    endtask

    // Push every staged write beat, each cycle with probability p percent.
    task flush_wdata(input int p);
        begin
            while (wstage_pushed < wstage_n) begin
                @(posedge ui_clk); #1;
                if ($urandom_range(99) < p) begin
                    wr_q[wr_wr] = wstage[wstage_pushed];
                    wr_wr = wr_wr + 1;
                    wstage_pushed = wstage_pushed + 1;
                end
            end
        end
    endtask

    task wait_drain;
        int t;
        begin
            t = 0;
            while (!(cmd_done == exp_cmd_n && rd_got == exp_rd_n && cmd_empty && wr_empty) && t < 8000) begin
                @(posedge ui_clk); t = t + 1;
            end
            if (t >= 8000) `ERR("drain timeout (a command or read beat never completed)")
            repeat (20) @(posedge ui_clk);          // let any stray extra activity show up
        end
    endtask

    task set_speed(input int rdy, input int wdf, input int ret, input int lmin, input int lrng);
        begin p_rdy = rdy; p_wdf = wdf; p_ret = ret; lat_min = lmin; lat_rng = lrng; end
    endtask

    // tests
    int i, k, op_wr, line, done_before;
    logic [31:0] pat;

    initial begin
        for (i = 0; i < 128;  i = i + 1) begin pat = 32'hC0DE0000 + i; ref_mem[i] = {4{pat}}; end
        for (i = 0; i < 2048; i = i + 1) begin pat = 32'hC0DE0000 + i; mig_mem[i] = {4{pat}}; end

        repeat (10) @(posedge ui_clk);
        ui_rst <= 0;
        repeat (3) @(posedge ui_clk);

        // Phase 1: a command is waiting but calibration is not done -> nothing may happen
        $display("1. nothing before calibration");
        set_speed(100, 100, 100, 3, 1);
        push_cmd(0, 2);
        repeat (20) @(posedge ui_clk);
        if (cmd_done != 0 || cmd_empty) `ERR("1. cmd should still be waiting in the FIFO, untouched")
        init_calib_complete <= 1;
        wait_drain();

        // 2/ write then read back, MIG always ready
        $display("2. write then read, no stalls");
        push_cmd(1, 3);  flush_wdata(100);
        push_cmd(0, 3);
        wait_drain();

        // 3. heavy random stalls on every MIG handshake and slow reads
        $display("3. random stalls");
        set_speed(30, 30, 50, 5, 10);
        push_cmd(1, 5);  flush_wdata(60);
        push_cmd(0, 5);
        push_cmd(1, 9);  flush_wdata(40);
        push_cmd(0, 9);
        wait_drain();

        // 4. commands arrive long before their data -> expander must wait, MIG sees nothing
        $display("4. cmd far ahead of data");
        set_speed(100, 100, 100, 3, 1);
        done_before = cmd_done;
        push_cmd(1, 6);  push_cmd(1, 7);  push_cmd(0, 6);  push_cmd(0, 7);
        repeat (40) @(posedge ui_clk);
        if (cmd_done != done_before) `ERR("expander issued a write command before its data was available")
        flush_wdata(100);
        wait_drain();

        // 5. random mix of reads/writes, random push timing, stall levels change every 25 ops
        $display("phase 5: random mix");
        for (k = 0; k < 150; k = k + 1) begin
            if (k % 25 == 0)
                set_speed($urandom_range(20,100), $urandom_range(20,100), $urandom_range(20,100),
                          $urandom_range(2,6), $urandom_range(1,12));
            op_wr = $urandom_range(1);
            line  = $urandom_range(15);
            push_cmd(op_wr, line);
            if (op_wr && $urandom_range(3) != 0) flush_wdata($urandom_range(30,100));
            repeat ($urandom_range(6)) @(posedge ui_clk);
        end
        flush_wdata(100);
        wait_drain();

        // final consistency check
        if (cmd_done != exp_cmd_n) `ERR("not all commands were issued")
        if (rd_got   != exp_rd_n)  `ERR("not all read beats were returned")
        if (n_data_stall == 0)     `ERR("coverage: never stalled waiting for write data")
        if (n_rdy_stall  == 0)     `ERR("coverage: never stalled on app_rdy")

        $display("--------------------------------------------------");
        $display("commands issued: %0d (writes %0d, reads %0d)   read beats returned: %0d",
                 cmd_done, n_wr_cmds, n_rd_cmds, rd_got);
        $display("cycles stalled waiting for write data: %0d   stalled on app_rdy: %0d", n_data_stall, n_rdy_stall);
        $display("%s  (%0d errors)", (errors == 0) ? "PASS" : "FAIL", errors);
        $display("--------------------------------------------------");
        if (errors != 0) $fatal(1, "FAIL");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "TIMEOUT");
    end
endmodule
