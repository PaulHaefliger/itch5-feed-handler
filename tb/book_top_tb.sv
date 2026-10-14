`default_nettype none
import book_pkg::*;

// End-to-end testbench for book_top (ref_table + price_to_level + book_side).
//
// Sends book operations (Add with ref/side/price/shares, Cancel with
// ref/shares, Delete with ref) and checks the BBO against a reference model,
// LAT cycles after each message:
//   the negedge after posedge k shows the book as of message k-LAT.
//
// The refs are chosen with distinct low 12 bits, so ref_table never overflows
// here and the test fails if it does (set collisions and overflow are covered
// by ref_table_sets_tb). Assumes book_top's BASE = 1520000 ($152.00), the same window as the MSFT replay.
//
// Compile:  iverilog -g2012 -o e2e.out rtl/book_pkg.sv rtl/ref_table.sv rtl/next_best.sv \
//               rtl/book_side.sv rtl/price_to_level.sv rtl/book_top.sv tb/book_top_tb.sv
// Run:      vvp e2e.out

module book_top_tb;
    localparam logic [31:0] BASE     = 1520000;  // must equal book_top's BASE ($152.00)
    localparam int          LEVELS   = 1024;
    localparam int          POOL     = 400;      // distinct order refs
    localparam int          N_RANDOM = 20000;
    localparam int          LAT      = 4;        // message-to-BBO latency


    // ---------------- DUT ----------------
    logic        clk, rst, in_valid;
    logic [1:0]  op;
    logic [63:0] ref_num;
    side_t       side;
    logic [31:0] price, shares;
    logic        bid_valid, offer_valid;
    logic [31:0] best_bid_px, best_offer_px;
    logic [35:0] best_bid_qty, best_offer_qty;

    book_top dut (
        .rst            (rst),
        .clk            (clk),
        .in_valid       (in_valid),
        .op             (op),
        .ref_num        (ref_num),
        .side           (side),
        .price          (price),
        .shares         (shares),
        .bid_valid      (bid_valid),
        .offer_valid    (offer_valid),
        .best_bid_px    (best_bid_px),
        .best_offer_px  (best_offer_px),
        .best_bid_qty   (best_bid_qty),
        .best_offer_qty (best_offer_qty)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------- reference model ----------------
    // Orders, one per pool ref. o_lvl = -1 means "price outside the window":
    // the order lives in ref_table but never touches the book.
    logic [63:0] pool_ref [POOL];
    bit          o_live   [POOL];
    side_t       o_side   [POOL];
    int          o_lvl    [POOL];
    logic [31:0] o_shares [POOL];

    // Quantity per level, per side, and the best of each side.
    logic [35:0] m_bid_qty   [LEVELS];
    logic [35:0] m_offer_qty [LEVELS];
    bit          m_bid_v, m_offer_v;
    int          m_bid_lvl, m_offer_lvl;

    // Counters (declared before any task that uses them).
    int cycle = 0, checks = 0, errors = 0, overflows = 0;
    int n_add = 0, n_cancel = 0, n_delete = 0, n_miss = 0, n_oor = 0, n_empty_best = 0;

    task automatic rescan(input side_t s);
        if (s == BID) begin
            m_bid_v = 0;
            for (int i = 0; i < LEVELS; i++)
                if (m_bid_qty[i] != 0) begin m_bid_v = 1; m_bid_lvl = i; end
        end else begin
            m_offer_v = 0;
            for (int i = LEVELS - 1; i >= 0; i--)
                if (m_offer_qty[i] != 0) begin m_offer_v = 1; m_offer_lvl = i; end
        end
    endtask

    task automatic book_add(input side_t s, input int l, input logic [31:0] sh);
        if (s == BID) begin
            m_bid_qty[l] += sh;
            if (!m_bid_v || l > m_bid_lvl) m_bid_lvl = l;
            m_bid_v = 1;
        end else begin
            m_offer_qty[l] += sh;
            if (!m_offer_v || l < m_offer_lvl) m_offer_lvl = l;
            m_offer_v = 1;
        end
    endtask

    task automatic book_sub(input side_t s, input int l, input logic [31:0] sh);
        if (s == BID) begin
            m_bid_qty[l] -= sh;
            if (m_bid_qty[l] == 0 && l == m_bid_lvl) begin n_empty_best++; rescan(BID); end
        end else begin
            m_offer_qty[l] -= sh;
            if (m_offer_qty[l] == 0 && l == m_offer_lvl) begin n_empty_best++; rescan(OFFER); end
        end
    endtask

    // ---------------- snapshots and checking ----------------
    bit          s_bid_v   [8], s_offer_v [8];
    logic [31:0] s_bid_px  [8], s_offer_px[8];
    logic [35:0] s_bid_qty [8], s_offer_qty[8];
    bit          s_known   [8];


    function automatic logic [31:0] px_of(input int l);
        return BASE + l * 100;
    endfunction

    task automatic snapshot(input int c);
        int k;
        k = c % 8;
        s_known[k]     = 1;
        s_bid_v[k]     = m_bid_v;
        s_bid_px[k]    = px_of(m_bid_lvl);
        s_bid_qty[k]   = m_bid_v ? m_bid_qty[m_bid_lvl] : 0;
        s_offer_v[k]   = m_offer_v;
        s_offer_px[k]  = px_of(m_offer_lvl);
        s_offer_qty[k] = m_offer_v ? m_offer_qty[m_offer_lvl] : 0;
    endtask

    task automatic check(input int c);
        int k;
        bit bad;
        k = (c < 0) ? 0 : c % 8;
        if (c >= 0 && s_known[k]) begin
            checks++;
            bad = 0;
            if (bid_valid !== s_bid_v[k]) bad = 1;
            if (s_bid_v[k] && (best_bid_px !== s_bid_px[k] || best_bid_qty !== s_bid_qty[k])) bad = 1;
            if (offer_valid !== s_offer_v[k]) bad = 1;
            if (s_offer_v[k] && (best_offer_px !== s_offer_px[k] || best_offer_qty !== s_offer_qty[k])) bad = 1;
            if (bad) begin
                errors++;
                if (errors <= 15) begin
                    $display("FAIL cycle %0d (book after message of cycle %0d)", cycle, c);
                    $display("     expected: bid v=%0b px=%0d qty=%0d | offer v=%0b px=%0d qty=%0d",
                             s_bid_v[k], s_bid_px[k], s_bid_qty[k], s_offer_v[k], s_offer_px[k], s_offer_qty[k]);
                    $display("     got     : bid v=%0b px=%0d qty=%0d | offer v=%0b px=%0d qty=%0d",
                             bid_valid, best_bid_px, best_bid_qty, offer_valid, best_offer_px, best_offer_qty);
                end
            end
        end
    endtask

    // overflow is internal to book_top: watch it hierarchically.
    always @(negedge clk)
        if (!rst && dut.u_ref_table.overflow === 1'b1) begin
            overflows++;
            if (overflows <= 3) $display("FAIL cycle %0d: ref_table overflow (should be impossible here)", cycle);
        end

    // ---------------- driving one cycle ----------------
    // Drive the message, update the model, then check the output LAT back.
    task automatic drive(input bit v, input logic [1:0] o, input int p,
                         input side_t s, input logic [31:0] px, input logic [31:0] sh);
        @(posedge clk);
        cycle++;
        in_valid <= v;
        op       <= v ? o : 2'($urandom);
        ref_num  <= v ? pool_ref[p] : {$urandom, $urandom};
        side     <= s;
        price    <= px;
        shares   <= sh;
        snapshot(cycle);
        @(negedge clk);
        check(cycle - LAT);
    endtask

    task automatic idle(input int n = 1);
        repeat (n) drive(0, 0, 0, side_t'($urandom), $urandom, $urandom);
    endtask


    // Add order p at level l (l < 0 or >= LEVELS: price outside the window).
    task automatic do_add(input int p, input side_t s, input int l, input logic [31:0] sh);
        logic [31:0] px;
        if (o_live[p]) idle();
        else begin
        if (l < 0)            px = BASE - 100 * (1 + $urandom_range(0, 50));
        else if (l >= LEVELS) px = BASE + 100 * (LEVELS + $urandom_range(0, 50));
        else                  px = px_of(l);
        o_live[p] = 1; o_side[p] = s; o_shares[p] = sh;
        o_lvl[p]  = (l >= 0 && l < LEVELS) ? l : -1;
        if (o_lvl[p] >= 0) book_add(s, l, sh); else n_oor++;
        n_add++;
        drive(1, OP_ADD, p, s, px, sh);
        end
    endtask

    // Cancel sh shares of order p (sh = 0: cancel everything left).
    // Side and price are driven with garbage: the DUT must take them from ref_table.
    task automatic do_cancel(input int p, input logic [31:0] sh);
        if (o_live[p]) begin
            if (sh == 0 || sh > o_shares[p]) sh = o_shares[p];
            if (o_lvl[p] >= 0) book_sub(o_side[p], o_lvl[p], sh);
            o_shares[p] -= sh;
            if (o_shares[p] == 0) o_live[p] = 0;
            n_cancel++;
        end else begin
            if (sh == 0) sh = 1;
            n_miss++;
        end
        drive(1, OP_CANCEL, p, side_t'($urandom), $urandom, sh);
    endtask

    task automatic do_delete(input int p);
        if (o_live[p]) begin
            if (o_lvl[p] >= 0) book_sub(o_side[p], o_lvl[p], o_shares[p]);
            o_live[p] = 0;
            n_delete++;
        end else n_miss++;
        drive(1, OP_DELETE, p, side_t'($urandom), $urandom, $urandom);
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

    // A live order, preferring ones resting at the current best of their side.
    function automatic int pick_live(input bit prefer_best);
        int p;
        if (prefer_best)
            for (int t = 0; t < 400; t++) begin
                p = $urandom_range(0, POOL - 1);
                if (o_live[p] && o_lvl[p] >= 0 &&
                    ((o_side[p] == BID   && m_bid_v   && o_lvl[p] == m_bid_lvl) ||
                     (o_side[p] == OFFER && m_offer_v && o_lvl[p] == m_offer_lvl)))
                    return p;
            end
        repeat (200) begin
            p = $urandom_range(0, POOL - 1);
            if (o_live[p]) return p;
        end
        return -1;
    endfunction

    // ---------------- stimulus ----------------
    int r, p, l;
    side_t sd = BID;

    initial begin
        // Pool refs: low 12 bits = pool index (distinct), high bits random.
        for (int i = 0; i < POOL; i++) begin
            pool_ref[i] = {$urandom, 20'($urandom), 12'(i)};
            o_live[i] = 0;
        end
        for (int i = 0; i < LEVELS; i++) begin m_bid_qty[i] = 0; m_offer_qty[i] = 0; end
        for (int i = 0; i < 8; i++) s_known[i] = 0;
        m_bid_v = 0; m_offer_v = 0; m_bid_lvl = 0; m_offer_lvl = 0;

        rst = 1; in_valid = 0; op = 0; ref_num = 0; side = BID; price = 0; shares = 0;
        repeat (3) @(posedge clk);
        rst = 0;

        // ---- directed ----
        $display("-- test 1: add, partial cancel, cancel rest");
        do_add(0, BID, 100, 300);   idle(5);
        do_cancel(0, 100);          idle(5);     // 200 left
        do_cancel(0, 0);            idle(5);     // all gone: bid side empty

        $display("-- test 2: delete");
        do_add(1, OFFER, 200, 50);  idle(5);
        do_delete(1);               idle(5);

        $display("-- test 3: cancel/delete of unknown refs (misses)");
        do_cancel(2, 10);           idle(2);
        do_delete(3);               idle(5);

        $display("-- test 4: back-to-back add then cancel of the same order");
        do_add(4, BID, 300, 80);
        do_cancel(4, 30);
        do_cancel(4, 20);
        do_delete(4);
        idle(6);

        $display("-- test 5: two orders at one level, remove one");
        do_add(5, BID, 310, 10);
        do_add(6, BID, 310, 20);
        do_add(7, BID, 305, 40);
        idle(5);
        do_delete(5);               idle(5);     // level 310 keeps 20
        do_delete(6);               idle(5);     // 310 empties -> best 305

        $display("-- test 6: empty the best, then add at the new best next cycle");
        do_add(8, OFFER, 500, 11);
        do_add(9, OFFER, 510, 22);
        idle(5);
        do_delete(8);                            // best offer -> 510
        do_add(10, OFFER, 510, 5);               // straight onto the new best
        idle(6);

        $display("-- test 7: out-of-window prices live in ref_table but not the book");
        do_add(11, BID, -1, 99);
        do_add(12, OFFER, LEVELS, 99);
        idle(5);
        do_cancel(11, 9);
        do_delete(12);
        idle(6);

        $display("   directed: %0d checks, %0d errors", checks, errors);

        // ---- random ----
        $display("-- test 8: %0d random cycles", N_RANDOM);
        repeat (N_RANDOM) begin
            r = $urandom_range(0, 99);
            if ($urandom_range(0, 99) < 20) sd = side_t'($urandom_range(0, 1));
            if (r < 8) begin
                idle();
            end else if (r < 50) begin
                p = pick_dead();
                if (p < 0) idle();
                else begin
                    if ($urandom_range(0, 99) < 3)
                        l = $urandom_range(0, 1) ? -1 : LEVELS;
                    else if ($urandom_range(0, 99) < 50)
                        l = (sd == BID) ? (m_bid_v   ? m_bid_lvl   + $urandom_range(0, 3) - 2 : 500)
                                        : (m_offer_v ? m_offer_lvl + $urandom_range(0, 3) - 1 : 520);
                    else
                        l = (sd == BID) ? $urandom_range(300, 520) : $urandom_range(500, 720);
                    if (l >= LEVELS && l != LEVELS) l = LEVELS - 1;
                    if (l < 0 && l != -1) l = 0;
                    do_add(p, sd, l, $urandom_range(1, 500));
                end
            end else if (r < 80) begin
                p = pick_live($urandom_range(0, 99) < 60);
                if (p < 0) idle();
                else do_cancel(p, $urandom_range(0, 1) ? 0 : $urandom_range(1, o_shares[p]));
            end else if (r < 95) begin
                p = pick_live($urandom_range(0, 99) < 60);
                if (p < 0) idle(); else do_delete(p);
            end else begin
                // a miss: cancel or delete a dead ref
                p = pick_dead();
                if (p < 0) idle();
                else if ($urandom_range(0, 1)) do_cancel(p, $urandom_range(1, 100));
                else do_delete(p);
            end
        end
        idle(LAT + 2);

        $display("");
        $display("checks=%0d  errors=%0d  overflows=%0d", checks, errors, overflows);
        $display("(adds=%0d cancels=%0d deletes=%0d misses=%0d out-of-window=%0d best-emptied=%0d)",
                 n_add, n_cancel, n_delete, n_miss, n_oor, n_empty_best);
        if (errors == 0 && overflows == 0) $display("PASS");
        else                               $display("FAIL");
        $finish;
    end

endmodule