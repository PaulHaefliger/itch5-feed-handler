`default_nettype none

// Self-checking testbench for next_best (bid and offer instances).
//
// Expected behaviour:
//   bid   (IS_BID=1): highest set bit of bitmap strictly BELOW L
//   offer (IS_BID=0): lowest  set bit of bitmap strictly ABOVE L
//   found = 0 if there is no such bit (next_level is then not checked).
//
// Compile:  iverilog -g2012 -o next_best_tb.out rtl/next_best.sv tb/next_best_tb.sv
// Run:      vvp next_best_tb.out

module next_best_tb;
    localparam int N = 1024;
    localparam int N_RANDOM = 20000;

    logic [N-1:0] bitmap;
    logic [9:0]   L;
    logic [9:0]   bid_next, offer_next;
    logic         bid_found, offer_found;

    next_best #(.IS_BID(1)) bid_dut   (.bitmap(bitmap), .L(L), .next_level(bid_next),   .found(bid_found));
    next_best #(.IS_BID(0)) offer_dut (.bitmap(bitmap), .L(L), .next_level(offer_next), .found(offer_found));

    int checks = 0, errors = 0;

    // Reference model: plain scans, written independently of the DUT.
    task automatic expect_bid(output bit f, output int lvl);
        f = 0; lvl = 0;
        // scan upward; the last set bit below L wins
        for (int i = 0; i < int'(L); i++)
            if (bitmap[i]) begin f = 1; lvl = i; end
    endtask

    task automatic expect_offer(output bit f, output int lvl);
        f = 0; lvl = 0;
        // scan downward; the last set bit above L wins
        for (int i = N - 1; i > int'(L); i--)
            if (bitmap[i]) begin f = 1; lvl = i; end
    endtask

    task automatic check(input string what);
        bit bf, of;
        int bl, ol;
        #1;
        expect_bid(bf, bl);
        expect_offer(of, ol);
        checks++;
        if (bid_found !== bf || (bf && bid_next !== bl) ||
            offer_found !== of || (of && offer_next !== ol)) begin
            errors++;
            if (errors <= 12) begin
                $display("FAIL %s: L=%0d  popcount=%0d", what, L, $countones(bitmap));
                $display("     bid   expected found=%0b level=%0d   got found=%0b level=%0d",
                         bf, bl, bid_found, bid_next);
                $display("     offer expected found=%0b level=%0d   got found=%0b level=%0d",
                         of, ol, offer_found, offer_next);
            end
        end
    endtask

    // Random bitmap with roughly `pct` percent of bits set.
    task automatic rand_bitmap(input int pct);
        for (int i = 0; i < N; i++) bitmap[i] = ($urandom_range(0, 99) < pct);
    endtask

    initial begin
        // ---- 1. hand-picked cases ----
        $display("-- test 1: directed");
        bitmap = '0; bitmap[6] = 1; bitmap[4] = 1; bitmap[3] = 1; bitmap[0] = 1;
        L = 6;    check("example: best 6, expect bid 4 / offer none");
        L = 4;    check("L itself set, must be excluded both ways");
        L = 0;    check("L=0: nothing below");
        bitmap = '0; L = 500;  check("empty bitmap");
        bitmap = '1; L = 0;    check("full bitmap, L=0");
        bitmap = '1; L = 1023; check("full bitmap, L=1023");
        bitmap = '1; L = 512;  check("full bitmap, L=512");
        bitmap = '0; bitmap[1023] = 1; bitmap[0] = 1;
        L = 500;  check("only the two extreme bits set");
        bitmap = '0; bitmap[40] = 1; L = 41;
        check("bit 40 below L=41 (catches 32-bit shift truncation)");
        bitmap = '0; bitmap[600] = 1; L = 599;
        check("bit 600 just above L=599");

        // ---- 2. every L, sparse random bitmaps ----
        $display("-- test 2: every L, sparse bitmaps");
        for (int l = 0; l < N; l++) begin
            rand_bitmap(1);
            L = l;
            check("sweep");
        end

        // ---- 3. random L, varying densities ----
        $display("-- test 3: %0d random cases", N_RANDOM);
        repeat (N_RANDOM) begin
            rand_bitmap($urandom_range(0, 3) == 0 ? 50 : $urandom_range(0, 2));
            L = $urandom;
            check("random");
        end

        $display("");
        $display("checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end
endmodule
