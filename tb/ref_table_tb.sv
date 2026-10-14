`default_nettype none
import book_pkg::*;

// Set-collision testbench for ref_table v2 (4-way set-associative).
//
// The refs deliberately SHARE sets: every ref in the pool has one of only
// NSETS distinct low-12-bit indices, with PER_SET different tags per set. So
// ways 1-3, free_way, hit_way > 0, forwarding with w_way != 0 and set overflow
// are all exercised.
//
// Also covers:
//   - book_degraded: checked every cycle against a sticky model of overflow
//   - OP_REPLACE: the TB plays the dispatcher, driving Delete(original ref) and
//     then OP_REPLACE(new ref, price, shares) on the next cycle. The replace-add
//     must use the side saved from that Delete, and be skipped (overflow = 1)
//     if the Delete missed.
//
// Checks ref_table's outputs directly (1 cycle after each message) against a
// reference model, plus the valid row of a set at a few points.
//
// Compile:  iverilog -g2012 -o sets.out rtl/book_pkg.sv rtl/ref_table.sv tb/ref_table_tb.sv
// Run:      vvp sets.out

module ref_table_tb;
    localparam int          INDEX_BITS = 12;
    localparam int          WAYS       = 4;
    localparam int          LAT        = 1;      // message -> ref_table outputs
    localparam int          NSETS      = 3;      // distinct sets used
    localparam int          PER_SET    = 8;      // refs per set (> WAYS: overflow happens)
    localparam int          POOL       = NSETS * PER_SET;
    localparam int          N_RANDOM   = 20000;
    localparam logic [11:0] SET0       = 12'h0A5; // sets used: SET0, SET0+1, SET0+2
    localparam logic [31:0] BASE       = 980000;

    // ---------------- DUT ----------------
    logic        clk, rst, in_valid;
    op_t         op;
    side_t       side;
    logic [63:0] ref_num;
    logic [31:0] price, shares;
    logic        out_valid, out_add, degraded;
    logic        overflow;
    assign overflow = dut.overflow;   // internal to ref_table (it only feeds book_degraded)
    side_t       out_side;
    logic [31:0] out_price, out_shares;

    ref_table #(.INDEX_BITS(INDEX_BITS)) dut (
        .rst           (rst),
        .clk           (clk),
        .in_valid      (in_valid),
        .op            (op),
        .side          (side),
        .ref_num       (ref_num),
        .price         (price),
        .shares        (shares),
        .out_valid     (out_valid),
        .out_side      (out_side),
        .out_add       (out_add),
        .out_price     (out_price),
        .out_shares    (out_shares),
        .book_degraded (degraded)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------- reference model ----------------
    // Pool ref p lives in set p / PER_SET; its tag is unique (bits [31:12] = p+1).
    logic [63:0] pool_ref [POOL];
    bit          o_live   [POOL];
    side_t       o_side   [POOL];
    logic [31:0] o_price  [POOL];
    logic [31:0] o_shares [POOL];
    int          set_count[NSETS];   // live orders per set

    bit          m_degraded    = 0;  // sticky: any overflow so far
    bit          m_saved_valid = 0;  // previous message was a Delete / Cancel-to-zero that hit
    side_t       m_saved_side  = BID;

    int cycle = 0, checks = 0, errors = 0;
    int n_add = 0, n_ovf = 0, n_cancel = 0, n_delete = 0, n_miss = 0;
    int n_repl = 0, n_repl_skip = 0;

    function automatic int set_of(input int p);
        return p / PER_SET;
    endfunction

    function automatic int P(input int s, input int j);   // pool index: set s, slot j
        return s * PER_SET + j;
    endfunction

    function automatic logic [31:0] px_of(input int p);
        return BASE + p * 100;
    endfunction

    // ---------------- expected outputs, one slot per cycle ----------------
    bit          e_known  [4];
    bit          e_valid  [4], e_add [4], e_ovf [4], e_degr [4];
    side_t       e_side   [4];
    logic [31:0] e_price  [4], e_shares [4];

    task automatic check(input int c);
        int k;
        bit bad;
        if (c >= 1) begin
            k = c % 4;
            if (e_known[k]) begin
                checks++;
                bad = 0;
                if (out_valid !== e_valid[k]) bad = 1;
                if (overflow  !== e_ovf[k])   bad = 1;
                if (degraded  !== e_degr[k])  bad = 1;
                if (e_valid[k] && (out_add    !== e_add[k]   || out_side   !== e_side[k] ||
                                   out_price  !== e_price[k] || out_shares !== e_shares[k])) bad = 1;
                if (bad) begin
                    errors++;
                    if (errors <= 15) begin
                        $display("FAIL cycle %0d (outputs for message of cycle %0d)", cycle, c);
                        $display("     expected: v=%0b ovf=%0b degr=%0b add=%0b side=%0d px=%0d sh=%0d",
                                 e_valid[k], e_ovf[k], e_degr[k], e_add[k], e_side[k], e_price[k], e_shares[k]);
                        $display("     got     : v=%0b ovf=%0b degr=%0b add=%0b side=%0d px=%0d sh=%0d",
                                 out_valid, overflow, degraded, out_add, out_side, out_price, out_shares);
                    end
                end
            end
        end
    endtask

    // Check the 4 valid bits of set s (an implementation check: lowest free way is used).
    task automatic expect_row(input int s, input logic [3:0] row, input string what);
        checks++;
        if (dut.valid[SET0 + s] !== row) begin
            errors++;
            $display("FAIL cycle %0d: set %0d valid row = %b, expected %b (%s)",
                     cycle, s, dut.valid[SET0 + s], row, what);
        end
    endtask

    // ---------------- driving one cycle ----------------
    // Drive the message, update the model and record the expected outputs,
    // then check the outputs of the message LAT cycles back.
    //
    // book_degraded timing: when message c's outputs are checked, the flag
    // reflects overflows of messages up to c-1 (it is set one edge after the
    // overflow output), so e_degr is the model's flag BEFORE message c.
    task automatic send(input bit v, input op_t o, input int p,
                        input side_t s, input logic [31:0] px, input logic [31:0] sh);
        int    k, st;
        bit    nxt_saved_valid;
        side_t nxt_saved_side;
        @(posedge clk);
        cycle++;
        in_valid <= v;
        op       <= v ? o : op_t'($urandom_range(0, 3));
        ref_num  <= v ? pool_ref[p] : {$urandom, $urandom};
        side     <= s;
        price    <= px;
        shares   <= sh;

        k = cycle % 4;
        e_known[k] = 1; e_valid[k] = 0; e_add[k] = 0; e_ovf[k] = 0;
        e_side[k] = BID; e_price[k] = 0; e_shares[k] = 0;
        e_degr[k] = m_degraded;
        nxt_saved_valid = 0;
        nxt_saved_side  = BID;

        if (v) begin
            st = set_of(p);
            case (o)
                OP_ADD: begin
                    if (set_count[st] < WAYS) begin
                        e_valid[k] = 1; e_add[k] = 1;
                        e_side[k] = s; e_price[k] = px; e_shares[k] = sh;
                        o_live[p] = 1; o_side[p] = s; o_price[p] = px; o_shares[p] = sh;
                        set_count[st]++;
                        n_add++;
                    end else begin
                        e_ovf[k] = 1;      // set full: dropped, book untouched
                        n_ovf++;
                    end
                end
                OP_DELETE: begin
                    if (o_live[p]) begin
                        e_valid[k] = 1;
                        e_side[k] = side_t'(o_side[p]); e_price[k] = o_price[p]; e_shares[k] = o_shares[p];
                        nxt_saved_valid = 1; nxt_saved_side = side_t'(o_side[p]);
                        o_live[p] = 0;
                        set_count[st]--;
                        n_delete++;
                    end else n_miss++;
                end
                OP_CANCEL: begin
                    if (o_live[p]) begin
                        e_valid[k] = 1;
                        e_side[k] = side_t'(o_side[p]); e_price[k] = o_price[p]; e_shares[k] = sh;
                        o_shares[p] -= sh;
                        if (o_shares[p] == 0) begin
                            nxt_saved_valid = 1; nxt_saved_side = side_t'(o_side[p]);
                            o_live[p] = 0;
                            set_count[st]--;
                        end
                        n_cancel++;
                    end else n_miss++;
                end
                OP_REPLACE: begin
                    // The Add half of a Replace: side comes from the Delete one cycle earlier.
                    if (!m_saved_valid) begin
                        e_ovf[k] = 1;      // that Delete missed: skip, flag
                        n_repl_skip++;
                    end else if (set_count[st] < WAYS) begin
                        e_valid[k] = 1; e_add[k] = 1;
                        e_side[k] = m_saved_side; e_price[k] = px; e_shares[k] = sh;
                        o_live[p] = 1; o_side[p] = m_saved_side; o_price[p] = px; o_shares[p] = sh;
                        set_count[st]++;
                        n_repl++;
                    end else begin
                        e_ovf[k] = 1;      // new ref's set is full
                        n_ovf++;
                    end
                end
                default: ;
            endcase
        end

        if (e_ovf[k]) m_degraded = 1;
        m_saved_valid = nxt_saved_valid;
        m_saved_side  = nxt_saved_side;

        @(negedge clk);
        check(cycle - LAT);
    endtask

    task automatic idle(input int n = 1);
        repeat (n) send(0, OP_ADD, 0, BID, 0, 0);
    endtask

    // Callers never Add a live ref (ITCH refs are unique while live).
    task automatic do_add(input int p, input side_t s, input logic [31:0] sh);
        if (o_live[p]) idle();
        else send(1, OP_ADD, p, s, px_of(p), sh);
    endtask

    // Cancel sh shares (0 = everything left). Side/price driven with garbage.
    task automatic do_cancel(input int p, input logic [31:0] sh);
        if (o_live[p] && (sh == 0 || sh > o_shares[p])) sh = o_shares[p];
        if (!o_live[p] && sh == 0) sh = 1;
        send(1, OP_CANCEL, p, side_t'($urandom), $urandom, sh);
    endtask

    task automatic do_delete(input int p);
        send(1, OP_DELETE, p, side_t'($urandom), $urandom, $urandom);
    endtask

    // Replace p_old by p_new, as the dispatcher will: Delete(p_old), then on the
    // very next cycle OP_REPLACE(p_new). The side input is garbage on purpose.
    task automatic do_replace(input int p_old, input int p_new, input logic [31:0] sh);
        if (o_live[p_new]) idle();
        else begin
            do_delete(p_old);
            send(1, OP_REPLACE, p_new, side_t'($urandom), px_of(p_new), sh);
        end
    endtask

    // ---------------- stimulus ----------------
    int p, q, r;
    logic [3:0] row;

    initial begin
        for (int i = 0; i < POOL; i++) begin
            pool_ref[i] = {$urandom, 20'(i + 1), 12'(SET0 + i / PER_SET)};
            o_live[i] = 0;
        end
        for (int s = 0; s < NSETS; s++) set_count[s] = 0;
        for (int i = 0; i < 4; i++) e_known[i] = 0;

        rst = 1; in_valid = 0; op = OP_ADD; ref_num = 0; side = BID; price = 0; shares = 0;
        repeat (3) @(posedge clk);
        rst = 0;

        // ---- directed, sets 0..2 ----
        $display("-- test 1: fill one set back-to-back, 5th add overflows");
        do_add(P(0,0), BID,   100);
        do_add(P(0,1), OFFER, 200);
        do_add(P(0,2), BID,   300);
        do_add(P(0,3), OFFER, 400);
        idle(2);
        expect_row(0, 4'b1111, "after 4 adds");
        do_add(P(0,4), BID,   500);            // set full -> overflow, book_degraded from here on
        idle(2);
        expect_row(0, 4'b1111, "after overflowing add");

        $display("-- test 2: hit every way (cancel 1 share each, back-to-back)");
        do_cancel(P(0,0), 1);
        do_cancel(P(0,1), 1);
        do_cancel(P(0,2), 1);
        do_cancel(P(0,3), 1);
        idle(2);

        $display("-- test 3: free a middle way, next add reuses it");
        do_delete(P(0,1));                     // was in way 1
        idle(2);
        expect_row(0, 4'b1101, "after deleting the order in way 1");
        do_add(P(0,5), OFFER, 600);            // lowest free way = 1
        idle(2);
        expect_row(0, 4'b1111, "after re-adding into way 1");
        do_cancel(P(0,5), 10);                 // and it is retrievable
        idle(2);

        $display("-- test 4: back-to-back on different ways of one set (forwarding by way)");
        do_cancel(P(0,2), 5);
        do_cancel(P(0,3), 5);
        do_cancel(P(0,2), 5);                  // previous write was way 3, not 2
        do_cancel(P(0,3), 5);
        do_cancel(P(0,3), 5);                  // same way twice in a row
        idle(2);

        $display("-- test 5: add then cancel the same order back-to-back, in a non-zero way");
        do_delete(P(0,3));                     // frees way 3
        do_add(P(0,6), BID, 70);               // next cycle: lands in way 3
        do_cancel(P(0,6), 20);                 // next cycle: needs forwarding with w_way = 3
        do_cancel(P(0,6), 0);                  // cancel the rest: frees way 3
        do_add(P(0,7), OFFER, 80);             // next cycle: way 3 reused at once
        idle(2);
        expect_row(0, 4'b1111, "after cancel-to-zero and immediate re-add");

        $display("-- test 6: misses in a busy set (same index, unknown tag)");
        do_cancel(P(0,4), 7);                  // overflowed earlier: never stored
        do_delete(P(0,1));                     // deleted earlier
        do_cancel(P(1,0), 3);                  // other set, never added
        idle(2);

        $display("-- test 7: empty set 0 completely, valid row returns to 0000");
        for (int j = 0; j < PER_SET; j++) begin
            p = P(0, j);
            if (o_live[p]) do_delete(p);
        end
        idle(2);
        expect_row(0, 4'b0000, "after deleting everything");

        $display("-- test 8: replace");
        do_add(P(1,0), OFFER, 100);
        idle(2);
        do_replace(P(1,0), P(1,1), 150);       // delete hits: new order rests on OFFER
        do_cancel(P(1,1), 10);                 // right after: stored side must be OFFER
        idle(2);
        do_replace(P(1,2), P(1,3), 40);        // original never existed: replace-add skipped
        idle(2);
        do_cancel(P(1,3), 5);                  // so the new ref is absent: miss
        idle(2);
        do_add(P(2,0), BID, 10);               // fill set 2
        do_add(P(2,1), BID, 20);
        do_add(P(2,2), BID, 30);
        do_add(P(2,3), BID, 40);
        idle(2);
        do_replace(P(1,1), P(2,4), 60);        // new ref's set is full: overflow
        idle(2);
        do_replace(P(2,0), P(2,5), 70);        // same full set: the delete frees the way the add needs
        idle(2);
        expect_row(2, 4'b1111, "after a same-set replace into a full set");
        do_cancel(P(2,5), 0);                  // and the new order is there, on BID
        idle(2);

        $display("   directed: %0d checks, %0d errors", checks, errors);

        // ---- random: 3 sets, 8 refs each, 4 ways -> frequent full sets ----
        $display("-- test 9: %0d random cycles over %0d shared sets", N_RANDOM, NSETS);
        repeat (N_RANDOM) begin
            r = $urandom_range(0, 99);
            p = $urandom_range(0, POOL - 1);
            if (r < 10) begin
                idle();
            end else if (!o_live[p]) begin
                if ($urandom_range(0, 99) < 5) do_cancel(p, $urandom_range(1, 50));  // a miss
                else do_add(p, side_t'($urandom_range(0, 1)), $urandom_range(1, 500));
            end else if (r < 55) begin
                do_cancel(p, $urandom_range(0, 1) ? 0 : $urandom_range(1, o_shares[p]));
            end else if (r < 80) begin
                do_delete(p);
            end else begin
                q = $urandom_range(0, POOL - 1);
                if (q == p || o_live[q]) do_delete(p);
                else do_replace(p, q, $urandom_range(1, 500));
            end
        end
        idle(LAT + 2);

        // Final occupancy: each set's valid row must hold exactly set_count[s] bits.
        for (int s = 0; s < NSETS; s++) begin
            row = dut.valid[SET0 + s];
            checks++;
            if (row[0] + row[1] + row[2] + row[3] != set_count[s]) begin
                errors++;
                $display("FAIL: set %0d valid row %b, model has %0d live orders", s, row, set_count[s]);
            end
        end

        $display("");
        $display("checks=%0d  errors=%0d", checks, errors);
        $display("(adds=%0d overflows=%0d cancels=%0d deletes=%0d misses=%0d replaces=%0d replace-skips=%0d)",
                 n_add, n_ovf, n_cancel, n_delete, n_miss, n_repl, n_repl_skip);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end
endmodule