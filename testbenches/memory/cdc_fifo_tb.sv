`timescale 1ns/1ps
module cdc_fifo_tb;
    localparam int DATA_WIDTH = 128;
    localparam int DEPTH = 16;

    // clocks
    real w_half = 5.0;      // 100 MHz
    real r_half = 6.154;    // ~81.25 MHz
    logic wclk = 0, rclk = 0;
    always #(w_half) wclk = ~wclk;
    always #(r_half) rclk = ~rclk;

    // DUT
    logic wrst = 1, rrst = 1;
    logic wen = 0, ren = 0;
    logic full, empty;
    logic [DATA_WIDTH-1:0] wdata = '0;
    logic [DATA_WIDTH-1:0] rdata;

    cdc_fifo #(.DATA_WIDTH(DATA_WIDTH), .DEPTH(DEPTH)) dut (
        .wclk(wclk),
        .wrst(wrst),
        .wen(wen),
        .wdata(wdata),
        .full(full),
        .rclk(rclk),
        .rrst(rrst),
        .ren(ren),
        .empty(empty),
        .rdata(rdata)
    );

    // scoreboard
    logic [DATA_WIDTH-1:0] sb [$];
    int unsigned  wr_seq = 0;
    int errors = 0, n_wr = 0, n_rd = 0, n_wblocked = 0, n_rblocked = 0;
    bit saw_full = 0, saw_empty = 0;
    int wr_prob = 0, rd_prob = 0;

    // write side
    always @(posedge wclk) begin
        if (!wrst) begin
            // values seen here are the pre-edge values
            if (wen && !full) begin
                sb.push_back(wdata);
                n_wr++;
                wr_seq++;
                if (sb.size() > DEPTH) begin
                    $error("[%0t] OVERFLOW: %0d entries in a %0d-deep FIFO", $time, sb.size(), DEPTH);
                    errors++;
                end
            end
            if (wen && full) n_wblocked++;
            if (full) saw_full = 1;

            wen <= ($urandom_range(99) < wr_prob);
            wdata <= {$urandom, $urandom, $urandom, wr_seq};
        end
    end

    // read side, rdata is valid whenever !empty
    logic [DATA_WIDTH-1:0] exp;
    always @(posedge rclk) begin
        if (!rrst) begin
            if (ren && !empty) begin
                if (sb.size() == 0) begin
                    $error("[%0t] UNDERFLOW: read while scoreboard empty", $time);
                    errors++;
                end else begin
                    exp = sb.pop_front();
                    if (rdata !== exp) begin
                        $error("[%0t] DATA MISMATCH: got %h expected %h", $time, rdata, exp);
                        errors++;
                    end
                end
                n_rd++;
            end
            if (ren && empty) n_rblocked++;
            if (empty) saw_empty = 1;

            ren <= ($urandom_range(99) < rd_prob);
        end
    end

    // reset
    initial begin
        fork
            begin repeat (10) @(posedge wclk); wrst <= 0; end
            begin repeat (10) @(posedge rclk); rrst <= 0; end
        join
        @(posedge rclk);
        if (empty !== 1'b1 || full !== 1'b0) begin
            $error("Error during reset reset: empty = %b full = %b (expected 1,0)", empty, full);
            errors++;
        end
    end

    // test phases
    initial begin
        wait (!wrst && !rrst);
        @(posedge wclk);

        // 1: writer fast, reader slow -> must hit full
        wr_prob = 90; rd_prob = 10;  repeat (200)  @(posedge wclk);
        // 2: reader fast, writer slow -> must hit empty
        wr_prob = 10; rd_prob = 90;  repeat (200)  @(posedge wclk);
        // 3: swap the clock ratio: slow writer (62.5 MHz), fast reader (166 MHz)
        w_half = 8.0; r_half = 3.0;
        wr_prob = 100; rd_prob = 100; repeat (1000) @(posedge wclk);
        wr_prob = 50;  rd_prob = 50;  repeat (1000) @(posedge wclk);
        wr_prob = 100; rd_prob = 20;  repeat (300)  @(posedge wclk);   // fill again at new ratio
        // 4: restore ratio and randomize probabilities every 50 cycles
        w_half = 5.0; r_half = 6.154;
        repeat (400) begin
            wr_prob = $urandom_range(100);
            rd_prob = $urandom_range(100);
            repeat (50) @(posedge wclk);
        end

        // 5: drain
        wr_prob = 0; rd_prob = 100;
        begin
            int t = 0;
            while (!(sb.size() == 0 && empty) && t < 1000) begin
                @(posedge rclk);
                t++;
            end
        end
        repeat (20) @(posedge rclk);

        if (sb.size() != 0) begin
            $error("Drain failed: %0d entries left in scoreboard", sb.size());
            errors++;
        end
        if (!saw_full)  begin $error("Coverage: FIFO never reached full");  errors++; end
        if (!saw_empty) begin $error("Coverage: FIFO never reached empty"); errors++; end

        $display("\nwrites accepted: %0d   reads accepted: %0d", n_wr, n_rd);
        $display("writes blocked by full: %0d   reads blocked by empty: %0d", n_wblocked, n_rblocked);
        $display("%s  (%0d errors)", (errors == 0) ? "PASS" : "FAIL", errors);
        if (errors != 0) $fatal(1, "FAIL");

        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "Timeout");
    end
endmodule
