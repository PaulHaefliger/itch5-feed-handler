`default_nettype none
import book_pkg::*;

// End-to-end testbench for feed_handler (itch_decoder -> book_top).
//
// Drives a raw byte stream (2-byte length prefix + ITCH message, itch_start
// with the first length byte) and checks the BBO against a reference model
// on EVERY cycle, so it also checks that the book changes at the right moment.
//
// Timing model (counted in the cycle where the message's last byte is on the
// input, call it L):
//   L+1  decoder out_valid -> the op is on book_top's input
//   L+5  BBO reflects it (book_top latency 4)
//   For U: Delete half at L+1 -> BBO at L+5, replace-add at L+2 -> BBO at L+6.
// So byte-to-BBO latency = 5 cycles from the last byte (6 for the add half of U).
// Test 1 measures it and prints it.
//
// Refs have distinct low 12 bits, so ref_table never overflows here:
// book_degraded must stay 0 throughout (overflow is covered by ref_table_sets_tb).
//
// Compile:  iverilog -g2012 -o fh.out rtl/book_pkg.sv rtl/itch_decoder.sv rtl/ref_table.sv \
//               rtl/price_to_level.sv rtl/next_best.sv rtl/book_side.sv rtl/book_top.sv \
//               rtl/feed_handler.sv tb/feed_handler_tb.sv
// Run:      vvp fh.out

module feed_handler_tb;
    localparam logic [31:0] BASE     = 1520000;  // must equal book_top's BASE ($152.00)
    localparam int          LEVELS   = 1024;
    localparam int          POOL     = 400;
    localparam int          N_RANDOM = 4000;   // random messages
    localparam int          BOOK_LAT = 4;      // book_top input -> BBO
    localparam logic [15:0] OUR_LOC  = 16'h1234; // the stock this book tracks

    // ---------------- DUT ----------------
    logic        clk, rst, itch_start, in_valid;
    logic [7:0]  in_byte;
    logic [15:0] stock_locate = OUR_LOC;
    logic        bid_valid, offer_valid, degraded;
    logic [31:0] best_bid_px, best_offer_px;
    logic [35:0] best_bid_qty, best_offer_qty;

    feed_handler dut (
        .rst            (rst),
        .clk            (clk),
        .itch_start     (itch_start),
        .in_valid       (in_valid),
        .in_byte        (in_byte),
        .stock_locate   (stock_locate),
        .bid_valid      (bid_valid),
        .offer_valid    (offer_valid),
        .best_bid_px    (best_bid_px),
        .best_offer_px  (best_offer_px),
        .best_bid_qty   (best_bid_qty),
        .best_offer_qty (best_offer_qty),
        .book_degraded  (degraded)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------- counters ----------------
    // mcyc counts negedges. The byte the driver puts on the input after the
    // posedge where it sees mcyc = n is "the input during cycle n".
    int mcyc = 0;
    int checks = 0, errors = 0;
    int n_msgs = 0, n_add = 0, n_exec = 0, n_cancel = 0, n_delete = 0, n_replace = 0;
    int n_miss = 0, n_skip = 0, n_oor = 0, n_deltas = 0;

    function automatic logic [31:0] px_of(input int l);
        return BASE + l * 100;
    endfunction

    // ---------------- book deltas, keyed by the cycle they hit book_top ----------------
    bit          dv   [64];
    side_t       ds   [64];
    int          dl   [64];
    logic [31:0] dsh  [64];
    bit          dadd [64];

    task automatic schedule(input int t, input side_t s, input int l,
                            input logic [31:0] sh, input bit add);
        int k;
        if (l >= 0) begin                      // out-of-window orders never touch the book
            k = t % 64;
            if (dv[k]) begin
                errors++;
                $display("TB ERROR: two book updates in cycle %0d", t);
            end
            dv[k] = 1; ds[k] = s; dl[k] = l; dsh[k] = sh; dadd[k] = add;
            n_deltas++;
        end
    endtask

    // ---------------- book model ----------------
    logic [35:0] m_bid [LEVELS], m_off [LEVELS];
    bit          m_bid_v = 0, m_off_v = 0;
    int          m_bid_lvl = 0, m_off_lvl = 0;

    task automatic rescan_bid();
        m_bid_v = 0;
        for (int i = 0; i < LEVELS; i++)
            if (m_bid[i] != 0) begin m_bid_v = 1; m_bid_lvl = i; end
    endtask

    task automatic rescan_off();
        m_off_v = 0;
        for (int i = LEVELS - 1; i >= 0; i--)
            if (m_off[i] != 0) begin m_off_v = 1; m_off_lvl = i; end
    endtask

    // Latency measurement for test 1.
    int  lat_from = -1, lat_measured = -1;

    int  mk;
    bit  bad;
    always @(negedge clk) begin
        if (!rst) begin
            // apply the update that entered book_top BOOK_LAT cycles ago
            if (mcyc >= BOOK_LAT) begin
                mk = (mcyc - BOOK_LAT) % 64;
                if (dv[mk]) begin
                    if (ds[mk] == BID) begin
                        if (dadd[mk]) m_bid[dl[mk]] += dsh[mk]; else m_bid[dl[mk]] -= dsh[mk];
                        rescan_bid();
                    end else begin
                        if (dadd[mk]) m_off[dl[mk]] += dsh[mk]; else m_off[dl[mk]] -= dsh[mk];
                        rescan_off();
                    end
                    dv[mk] = 0;
                end
            end

            // compare
            checks++;
            bad = 0;
            if (bid_valid !== m_bid_v) bad = 1;
            if (m_bid_v && (best_bid_px !== px_of(m_bid_lvl) || best_bid_qty !== m_bid[m_bid_lvl])) bad = 1;
            if (offer_valid !== m_off_v) bad = 1;
            if (m_off_v && (best_offer_px !== px_of(m_off_lvl) || best_offer_qty !== m_off[m_off_lvl])) bad = 1;
            if (degraded !== 1'b0) bad = 1;
            if (bad) begin
                errors++;
                if (errors <= 15) begin
                    $display("FAIL cycle %0d", mcyc);
                    $display("     expected: bid v=%0b px=%0d qty=%0d | offer v=%0b px=%0d qty=%0d | degraded=0",
                             m_bid_v, px_of(m_bid_lvl), m_bid_v ? m_bid[m_bid_lvl] : 0,
                             m_off_v, px_of(m_off_lvl), m_off_v ? m_off[m_off_lvl] : 0);
                    $display("     got     : bid v=%0b px=%0d qty=%0d | offer v=%0b px=%0d qty=%0d | degraded=%0b",
                             bid_valid, best_bid_px, best_bid_qty,
                             offer_valid, best_offer_px, best_offer_qty, degraded);
                end
            end

            if (lat_from >= 0 && lat_measured < 0 && bid_valid === 1'b1)
                lat_measured = mcyc - lat_from;
        end
        mcyc++;
    end

    // ---------------- message building and sending ----------------
    logic [7:0] mbuf [0:63];
    bit         gaps_on = 0;

    task automatic put(input int off, input logic [63:0] v, input int n);
        for (int b = 0; b < n; b++) mbuf[off + b] = v[8*(n-1-b) +: 8];
    endtask

    task automatic fill(input logic [7:0] typ, input int len);
        for (int i = 0; i < len; i++) mbuf[i] = $urandom;
        mbuf[0] = typ;
        put(1, OUR_LOC, 2);                    // stock locate (offsets 1-2)
    endtask

    function automatic logic [15:0] other_loc();
        logic [15:0] l;
        l = $urandom;
        if (l == OUR_LOC) l = ~l;
        return l;
    endfunction

    task automatic idle(input int n = 1);
        repeat (n) begin
            @(posedge clk);
            itch_start <= 0;
            in_valid   <= 0;
            in_byte    <= $urandom;
        end
    endtask

    // Send length prefix + message; 'last' = the cycle whose input holds the last byte.
    task automatic send(input int len, output int last);
        logic [7:0] b;
        for (int i = 0; i < len + 2; i++) begin
            if (gaps_on && i > 0 && $urandom_range(0, 99) < 10) idle();
            if (i == 0)      b = len[15:8];
            else if (i == 1) b = len[7:0];
            else             b = mbuf[i - 2];
            @(posedge clk);
            itch_start <= (i == 0);
            in_valid   <= 1;
            in_byte    <= b;
            last = mcyc;
        end
        n_msgs++;
    endtask

    // ---------------- order model (ref -> side, level, shares) ----------------
    // o_lvl = -1: price outside the window (lives in ref_table, not in the book).
    logic [63:0] pool_ref [POOL];
    bit          o_live   [POOL];
    side_t       o_side   [POOL];
    int          o_lvl    [POOL];
    logic [31:0] o_sh     [POOL];

    function automatic logic [31:0] price_for(input int l);
        if (l < 0)            return BASE - 100 * (1 + $urandom_range(0, 50));
        else if (l >= LEVELS) return BASE + 100 * (LEVELS + $urandom_range(0, 50));
        else                  return px_of(l);
    endfunction

    // ---- one task per message: build bytes, send, update model, schedule book delta ----

    // Add (A, or F with mpid = 1). l < 0 or l >= LEVELS: out of window.
    task automatic do_add(input int p, input side_t s, input int l,
                          input logic [31:0] sh, input bit mpid);
        int len, last;
        logic [31:0] px;
        if (o_live[p]) idle();
        else begin
            px  = price_for(l);
            len = mpid ? 40 : 36;
            fill(mpid ? MSG_ADD_MPID : MSG_ADD, len);
            put(11, pool_ref[p], 8);
            mbuf[19] = (s == BID) ? 8'h42 : 8'h53;
            put(20, sh, 4);
            put(32, px, 4);
            send(len, last);
            o_live[p] = 1; o_side[p] = s; o_sh[p] = sh;
            o_lvl[p]  = (l >= 0 && l < LEVELS) ? l : -1;
            if (o_lvl[p] < 0) n_oor++;
            schedule(last + 1, s, o_lvl[p], sh, 1);
            n_add++;
        end
    endtask

    // Shrink an order: kind 0 = E (executed), 1 = C (executed with price), 2 = X (cancel).
    // sh = 0: everything left. On a dead ref it is a miss (no book change).
    task automatic do_reduce(input int p, input logic [31:0] sh, input int kind);
        int len, last;
        if (o_live[p] && (sh == 0 || sh > o_sh[p])) sh = o_sh[p];
        if (!o_live[p] && sh == 0) sh = 1;
        len = (kind == 0) ? 31 : (kind == 1) ? 36 : 23;
        fill((kind == 0) ? MSG_EXECUTED : (kind == 1) ? MSG_EXECUTED_PX : MSG_CANCEL, len);
        put(11, pool_ref[p], 8);
        put(19, sh, 4);
        if (kind == 1) mbuf[31] = 8'h59;   // printable 'Y'
        send(len, last);
        if (o_live[p]) begin
            schedule(last + 1, o_side[p], o_lvl[p], sh, 0);
            o_sh[p] -= sh;
            if (o_sh[p] == 0) o_live[p] = 0;
            if (kind == 2) n_cancel++; else n_exec++;
        end else n_miss++;
    endtask

    task automatic do_delete(input int p);
        int last;
        fill(MSG_DELETE, 19);
        put(11, pool_ref[p], 8);
        send(19, last);
        if (o_live[p]) begin
            schedule(last + 1, o_side[p], o_lvl[p], o_sh[p], 0);
            o_live[p] = 0;
            n_delete++;
        end else n_miss++;
    endtask

    // Replace live p_old by dead p_new at level l (same side).
    task automatic do_replace(input int p_old, input int p_new, input int l, input logic [31:0] sh);
        int last;
        logic [31:0] px;
        if (!o_live[p_old] || o_live[p_new]) idle();
        else begin
            px = price_for(l);
            fill(MSG_REPLACE, 35);
            put(11, pool_ref[p_old], 8);
            put(19, pool_ref[p_new], 8);
            put(27, sh, 4);
            put(31, px, 4);
            send(35, last);
            schedule(last + 1, o_side[p_old], o_lvl[p_old], o_sh[p_old], 0);   // delete half
            o_live[p_new] = 1; o_side[p_new] = side_t'(o_side[p_old]); o_sh[p_new] = sh;
            o_lvl[p_new]  = (l >= 0 && l < LEVELS) ? l : -1;
            o_live[p_old] = 0;
            schedule(last + 2, o_side[p_new], o_lvl[p_new], sh, 1);             // add half
            n_replace++;
        end
    endtask

    // A message for ANOTHER stock that targets one of OUR pool refs (live or not).
    // Real refs are unique across stocks; reusing ours here makes any filter
    // leak visible as a wrong book. Must change nothing: no model update.
    int n_other = 0;
    task automatic do_other(input int p);
        int len, last, k;
        k = $urandom_range(0, 5);
        case (k)
            0: begin len = 36; fill(MSG_ADD, len);
                     put(11, pool_ref[p], 8); mbuf[19] = $urandom_range(0, 1) ? 8'h42 : 8'h53;
                     put(20, $urandom_range(1, 500), 4); put(32, px_of($urandom_range(480, 540)), 4); end
            1: begin len = 31; fill(MSG_EXECUTED, len);    put(11, pool_ref[p], 8); put(19, 1, 4); end
            2: begin len = 23; fill(MSG_CANCEL, len);      put(11, pool_ref[p], 8); put(19, 1, 4); end
            3: begin len = 19; fill(MSG_DELETE, len);      put(11, pool_ref[p], 8); end
            4: begin len = 35; fill(MSG_REPLACE, len);     put(11, pool_ref[p], 8);
                     put(19, pool_ref[(p + 1) % POOL], 8); put(27, 5, 4); put(31, px_of(500), 4); end
            default: begin len = 36; fill(MSG_EXECUTED_PX, len); put(11, pool_ref[p], 8); put(19, 1, 4); end
        endcase
        put(1, other_loc(), 2);                // the only difference: another stock locate
        send(len, last);
        n_other++;
    endtask

    task automatic do_skip();
        int last;
        case ($urandom_range(0, 4))
            0: begin fill(8'h53, 12); send(12, last); end   // 'S' system event
            1: begin fill(8'h52, 39); send(39, last); end   // 'R' stock directory
            2: begin fill(8'h48, 25); send(25, last); end   // 'H' trading action
            3: begin fill(8'h50, 44); send(44, last); end   // 'P' trade
            4: begin fill(8'h49, 50); send(50, last); end   // 'I' NOII
        endcase
        n_skip++;
    endtask

    // ---------------- pool helpers ----------------
    function automatic int pick_dead();
        int p;
        repeat (50) begin
            p = $urandom_range(0, POOL - 1);
            if (!o_live[p]) return p;
        end
        return -1;
    endfunction

    function automatic int pick_live();
        int p;
        repeat (200) begin
            p = $urandom_range(0, POOL - 1);
            if (o_live[p]) return p;
        end
        return -1;
    endfunction

    // A level near the current best of side s (often at or through it).
    function automatic int near_level(input side_t s);
        int l;
        if ($urandom_range(0, 99) < 3)
            l = $urandom_range(0, 1) ? -1 : LEVELS;
        else if (s == BID)
            l = m_bid_v ? m_bid_lvl + $urandom_range(0, 3) - 2 : $urandom_range(480, 510);
        else
            l = m_off_v ? m_off_lvl + $urandom_range(0, 3) - 1 : $urandom_range(510, 540);
        if (l < -1) l = 0;
        if (l > LEVELS) l = LEVELS - 1;
        return l;
    endfunction

    // ---------------- stimulus ----------------
    int p, q, r;
    side_t sd;

    initial begin
        for (int i = 0; i < POOL; i++) begin
            pool_ref[i] = {$urandom, 20'($urandom), 12'(i)};   // distinct low 12 bits
            o_live[i] = 0;
        end
        for (int i = 0; i < LEVELS; i++) begin m_bid[i] = 0; m_off[i] = 0; end
        for (int i = 0; i < 64; i++) dv[i] = 0;

        rst = 1; itch_start = 0; in_valid = 0; in_byte = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        idle(3);

        $display("-- test 1: one Add into an empty book, measure byte-to-BBO latency");
        do_add(0, BID, 500, 100, 0);
        lat_from = mcyc;                     // still the cycle whose input holds the last byte
        idle(10);
        $display("   last byte -> best bid valid: %0d cycles", lat_measured);

        $display("-- test 2: build both sides, then move the best with a Replace");
        do_add(1, BID,   498, 200, 1);       // F
        do_add(2, OFFER, 505, 300, 0);
        do_add(3, OFFER, 507, 400, 0);
        idle(6);
        do_replace(0, 4, 502, 150);          // best bid 500 -> 502 (same side, new ref)
        idle(7);

        $display("-- test 3: E, C and X shrink, D removes, best falls back");
        do_reduce(2, 100, 0);                // E: 300 -> 200 at 505
        do_reduce(2, 50, 1);                 // C: -> 150
        do_reduce(4, 150, 2);                // X: whole order at 502 -> best bid back to 498
        do_delete(2);                        // best offer 505 -> 507
        idle(7);

        $display("-- test 4: misses and ignored types change nothing");
        do_reduce(2, 10, 2);                 // dead ref
        do_delete(4);                        // dead ref
        do_skip(); do_skip(); do_skip();
        idle(7);

        $display("-- test 5: back-to-back messages, and idle cycles inside messages");
        do_add(5, BID, 503, 10, 0);
        do_replace(5, 6, 504, 20);
        do_reduce(6, 5, 0);
        do_delete(1);
        gaps_on = 1;
        do_add(7, OFFER, 506, 30, 1);
        do_replace(7, 8, 504 + 2, 40);
        do_delete(6);
        gaps_on = 0;
        idle(8);

        $display("-- test 6: out-of-window orders live in ref_table but not in the book");
        do_add(9,  BID,   -1,     70, 0);
        do_add(10, OFFER, LEVELS, 80, 0);
        do_replace(9, 11, -1, 90);
        do_reduce(10, 30, 2);
        do_delete(11);
        idle(8);

        $display("-- test 7: other stocks hitting our refs change nothing");
        do_add(12, BID,   501, 60, 0);
        do_add(13, OFFER, 509, 70, 0);
        idle(6);
        for (int k = 0; k < 12; k++) do_other((k % 2) ? 12 : 13);   // every type, back-to-back
        idle(6);
        do_reduce(12, 10, 2);                  // our own messages still work afterwards
        do_delete(13);
        idle(7);

        $display("   directed: %0d checks, %0d errors", checks, errors);

        $display("-- test 8: %0d random messages (some for other stocks)", N_RANDOM);
        sd = BID;
        repeat (N_RANDOM) begin
            gaps_on = ($urandom_range(0, 99) < 15);
            if ($urandom_range(0, 99) < 20) sd = side_t'($urandom_range(0, 1));
            r = $urandom_range(0, 99);
            if (r < 30) begin
                p = pick_dead();
                if (p < 0) idle(); else do_add(p, sd, near_level(sd), $urandom_range(1, 500), $urandom_range(0, 1));
            end else if (r < 55) begin
                p = pick_live();
                if (p < 0) idle();
                else do_reduce(p, $urandom_range(0, 1) ? 0 : $urandom_range(1, o_sh[p]), $urandom_range(0, 2));
            end else if (r < 70) begin
                p = pick_live();
                if (p < 0) idle(); else do_delete(p);
            end else if (r < 85) begin
                p = pick_live();
                q = pick_dead();
                if (p < 0 || q < 0) idle(); else do_replace(p, q, near_level(o_side[p]), $urandom_range(1, 500));
            end else if (r < 90) begin
                p = pick_dead();                             // a miss
                if (p < 0) idle();
                else if ($urandom_range(0, 1)) do_reduce(p, $urandom_range(1, 50), $urandom_range(0, 2));
                else do_delete(p);
            end else if (r < 95) begin
                do_other($urandom_range(0, POOL - 1));       // another stock, on one of our refs
            end else begin
                do_skip();
            end
            if ($urandom_range(0, 99) < 40) idle($urandom_range(1, 3));
        end
        gaps_on = 0;
        idle(10);

        for (int i = 0; i < 64; i++)
            if (dv[i]) begin
                errors++;
                $display("FAIL: a scheduled book update was never checked (slot %0d)", i);
            end

        $display("");
        $display("checks=%0d  errors=%0d  (BBO compared every cycle)", checks, errors);
        $display("(messages=%0d adds=%0d exec=%0d cancels=%0d deletes=%0d replaces=%0d misses=%0d ignored=%0d other-stock=%0d out-of-window=%0d book-updates=%0d)",
                 n_msgs, n_add, n_exec, n_cancel, n_delete, n_replace, n_miss, n_skip, n_other, n_oor, n_deltas);
        $display("byte-to-BBO latency (last byte -> BBO): %0d cycles", lat_measured);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end
endmodule