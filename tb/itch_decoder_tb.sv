`default_nettype none
import book_pkg::*;

// Testbench for itch_decoder.
//
// Input stream: for each message, the 2-byte big-endian length prefix, then the
// ITCH message bytes (type byte first). itch_start is high with the FIRST
// length byte (same cycle), in_valid high on every byte.
//
// stock_locate is fixed to OUR_LOC. Messages for other stocks (another locate
// at message offsets 1-2) must produce no output at all, including both halves
// of a U.
//
// Expected outputs, per the decoder's contract:
//   - one cycle after the last byte is consumed, out_valid is high for one
//     cycle with the decoded op and fields;
//   - a U produces TWO consecutive output cycles: OP_DELETE (original ref),
//     then OP_REPLACE (new ref, new price, new shares);
//   - types the decoder ignores (S, R, H, P, I here) produce no output;
//   - out_valid is 0 in every other cycle.
// Only the fields an op uses are compared:
//   OP_ADD     ref, side, price, shares
//   OP_CANCEL  ref, shares          (E, C, X)
//   OP_DELETE  ref                  (D, and the first half of U)
//   OP_REPLACE ref, price, shares   (second half of U)
//
// Message layouts (offsets from the type byte) follow the ITCH 5.0 spec.
//
// Compile:  iverilog -g2012 -o dec.out rtl/book_pkg.sv rtl/itch_decoder.sv tb/itch_decoder_tb.sv
// Run:      vvp dec.out

module itch_decoder_tb;
    localparam int          N_RANDOM = 3000;     // random messages in the last test
    localparam logic [15:0] OUR_LOC  = 16'h1234; // the stock this decoder tracks

    // ---------------- DUT ----------------
    logic        clk, rst, itch_start, in_valid;
    logic [7:0]  in_byte;
    logic [15:0] stock_locate = OUR_LOC;
    logic        out_valid;
    op_t         op;
    logic [63:0] ref_num;
    side_t       side;
    logic [31:0] price, shares;

    itch_decoder dut (
        .rst        (rst),
        .clk        (clk),
        .itch_start (itch_start),
        .in_valid   (in_valid),
        .in_byte      (in_byte),
        .stock_locate (stock_locate),
        .out_valid  (out_valid),
        .op         (op),
        .ref_num    (ref_num),
        .side       (side),
        .price      (price),
        .shares     (shares)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------- cycle count and expected outputs ----------------
    // mcyc counts negedges. A byte driven after the posedge where the driver
    // sees mcyc = n is consumed on the next posedge, so an output registered
    // on that edge is checked at the negedge where mcyc = n + 1.
    int mcyc = 0;
    int checks = 0, errors = 0, n_expected = 0, n_got = 0;
    int n_msgs = 0, n_skipped = 0;
    bit other   = 0;               // messages are for another stock: no output expected
    int n_other = 0;

    bit          d_valid [64];
    op_t         d_op    [64];
    logic [63:0] d_ref   [64];
    side_t       d_side  [64];
    logic [31:0] d_px    [64], d_sh [64];

    task automatic expect_out(input int at, input op_t o, input logic [63:0] r,
                              input side_t s, input logic [31:0] px, input logic [31:0] sh);
        int k;
        if (!other) begin                      // another stock's message: filtered, no output
            k = at % 64;
            if (d_valid[k]) begin
                errors++;
                $display("TB ERROR: two expected outputs in cycle %0d", at);
            end
            d_valid[k] = 1; d_op[k] = o; d_ref[k] = r; d_side[k] = s; d_px[k] = px; d_sh[k] = sh;
            n_expected++;
        end
    endtask

    int  mk;
    bit  bad;
    always @(negedge clk) begin
        if (!rst) begin
            mk = mcyc % 64;
            if (d_valid[mk]) begin
                checks++;
                bad = 0;
                if (out_valid !== 1'b1 || op !== d_op[mk] || ref_num !== d_ref[mk]) bad = 1;
                case (d_op[mk])
                    OP_ADD:     if (side !== d_side[mk] || price !== d_px[mk] || shares !== d_sh[mk]) bad = 1;
                    OP_CANCEL:  if (shares !== d_sh[mk]) bad = 1;
                    OP_REPLACE: if (price !== d_px[mk] || shares !== d_sh[mk]) bad = 1;
                    default: ;
                endcase
                if (bad) begin
                    errors++;
                    if (errors <= 15) begin
                        $display("FAIL cycle %0d", mcyc);
                        $display("     expected: v=1 op=%0d ref=%h side=%0d px=%0d sh=%0d",
                                 d_op[mk], d_ref[mk], d_side[mk], d_px[mk], d_sh[mk]);
                        $display("     got     : v=%0b op=%0d ref=%h side=%0d px=%0d sh=%0d",
                                 out_valid, op, ref_num, side, price, shares);
                    end
                end
                if (out_valid === 1'b1) n_got++;
                d_valid[mk] = 0;
            end else begin
                checks++;
                if (out_valid !== 1'b0) begin
                    errors++;
                    if (errors <= 15)
                        $display("FAIL cycle %0d: unexpected out_valid=%b (op=%0d ref=%h)",
                                 mcyc, out_valid, op, ref_num);
                end
            end
        end
        mcyc++;
    end

    // ---------------- building and sending messages ----------------
    logic [7:0] mbuf [0:63];   // the ITCH message, type byte at index 0
    bit         gaps_on = 0;   // insert random idle cycles inside messages

    // Big-endian field of n bytes at offset off.
    task automatic put(input int off, input logic [63:0] v, input int n);
        for (int b = 0; b < n; b++) mbuf[off + b] = v[8*(n-1-b) +: 8];
    endtask

    function automatic logic [15:0] other_loc();
        logic [15:0] l;
        l = $urandom;
        if (l == OUR_LOC) l = ~l;
        return l;
    endfunction

    // Random header and body; stock locate = ours, or another one if 'other' is set.
    task automatic fill(input logic [7:0] typ, input int len);
        for (int i = 0; i < len; i++) mbuf[i] = $urandom;
        mbuf[0] = typ;
        put(1, other ? other_loc() : OUR_LOC, 2);
        if (other) n_other++;
    endtask

    task automatic idle(input int n = 1);
        repeat (n) begin
            @(posedge clk);
            itch_start <= 0;
            in_valid   <= 0;
            in_byte    <= $urandom;
        end
    endtask

    // Send length prefix + message. Returns the mcyc seen when the last byte was driven.
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

    function automatic logic [7:0] side_byte(input side_t s);
        return (s == BID) ? 8'h42 : 8'h53;   // 'B' / 'S'
    endfunction

    // ---- one task per message type ----
    task automatic msg_add(input logic [63:0] r, input side_t s,
                           input logic [31:0] sh, input logic [31:0] px, input bit mpid);
        int len, last;
        len = mpid ? 40 : 36;
        fill(mpid ? MSG_ADD_MPID : MSG_ADD, len);
        put(11, r, 8);
        mbuf[19] = side_byte(s);
        put(20, sh, 4);
        put(32, px, 4);
        send(len, last);
        expect_out(last + 1, OP_ADD, r, s, px, sh);
    endtask

    task automatic msg_exec(input logic [63:0] r, input logic [31:0] sh, input bit with_px);
        int len, last;
        len = with_px ? 36 : 31;
        fill(with_px ? MSG_EXECUTED_PX : MSG_EXECUTED, len);
        put(11, r, 8);
        put(19, sh, 4);
        if (with_px) mbuf[31] = 8'h59;          // printable 'Y'; match number and price stay random
        send(len, last);
        expect_out(last + 1, OP_CANCEL, r, BID, 0, sh);
    endtask

    task automatic msg_cancel(input logic [63:0] r, input logic [31:0] sh);
        int last;
        fill(MSG_CANCEL, 23);
        put(11, r, 8);
        put(19, sh, 4);
        send(23, last);
        expect_out(last + 1, OP_CANCEL, r, BID, 0, sh);
    endtask

    task automatic msg_delete(input logic [63:0] r);
        int last;
        fill(MSG_DELETE, 19);
        put(11, r, 8);
        send(19, last);
        expect_out(last + 1, OP_DELETE, r, BID, 0, 0);
    endtask

    task automatic msg_replace(input logic [63:0] orig, input logic [63:0] nref,
                               input logic [31:0] sh, input logic [31:0] px);
        int last;
        fill(MSG_REPLACE, 35);
        put(11, orig, 8);
        put(19, nref, 8);
        put(27, sh, 4);
        put(31, px, 4);
        send(35, last);
        expect_out(last + 1, OP_DELETE,  orig, BID, 0,  0);
        expect_out(last + 2, OP_REPLACE, nref, BID, px, sh);
    endtask

    // A type the decoder must ignore. Its body is random, including bytes at
    // the offsets where a decoded type would carry fields.
    task automatic msg_skip(input logic [7:0] typ, input int len);
        int last;
        fill(typ, len);
        send(len, last);
        n_skipped++;
    endtask

    function automatic logic [63:0] rnd64();
        return {$urandom, $urandom};
    endfunction

    task automatic random_msg();
        int r;
        r = $urandom_range(0, 99);
        if      (r < 25) msg_add(rnd64(), side_t'($urandom_range(0, 1)), $urandom, $urandom, $urandom_range(0, 1));
        else if (r < 40) msg_exec(rnd64(), $urandom, $urandom_range(0, 1));
        else if (r < 52) msg_cancel(rnd64(), $urandom);
        else if (r < 64) msg_delete(rnd64());
        else if (r < 76) msg_replace(rnd64(), rnd64(), $urandom, $urandom);
        else begin
            case ($urandom_range(0, 4))
                0: msg_skip(8'h53, 12);   // 'S' system event
                1: msg_skip(8'h52, 39);   // 'R' stock directory
                2: msg_skip(8'h48, 25);   // 'H' trading action
                3: msg_skip(8'h50, 44);   // 'P' trade
                4: msg_skip(8'h49, 50);   // 'I' NOII
            endcase
        end
    endtask

    // ---------------- stimulus ----------------
    initial begin
        for (int i = 0; i < 64; i++) d_valid[i] = 0;
        rst = 1; itch_start = 0; in_valid = 0; in_byte = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        idle(2);

        $display("-- test 1: one Delete");
        msg_delete(64'h1122334455667788);
        idle(3);

        $display("-- test 2: each decoded type once, with idle cycles between");
        msg_add(64'hA1A2A3A4A5A6A7A8, BID,   32'd100, 32'd1234500, 0);  idle(2);
        msg_add(64'hB1B2B3B4B5B6B7B8, OFFER, 32'd200, 32'd1234600, 1);  idle(2);   // F
        msg_exec(64'hC1C2C3C4C5C6C7C8, 32'd30, 0);                      idle(2);   // E
        msg_exec(64'hD1D2D3D4D5D6D7D8, 32'd40, 1);                      idle(2);   // C
        msg_cancel(64'hE1E2E3E4E5E6E7E8, 32'd50);                       idle(2);   // X
        msg_delete(64'hF1F2F3F4F5F6F7F8);                               idle(2);   // D
        msg_replace(64'h0102030405060708, 64'h1112131415161718, 32'd60, 32'd1234700);
        idle(3);

        $display("-- test 3: ignored types produce no output");
        msg_skip(8'h53, 12);  idle(1);
        msg_skip(8'h52, 39);  idle(1);
        msg_skip(8'h50, 44);  idle(3);

        $display("-- test 4: back-to-back messages, no idle cycles");
        msg_add(64'h2222222222222201, BID, 32'd7, 32'd990000, 0);
        msg_skip(8'h48, 25);
        msg_replace(64'h2222222222222201, 64'h2222222222222202, 32'd8, 32'd991000);
        msg_delete(64'h2222222222222202);                                // straight after a U
        msg_cancel(64'h2222222222222203, 32'd9);
        msg_replace(64'h3333333333333301, 64'h3333333333333302, 32'd10, 32'd992000);
        msg_replace(64'h4444444444444401, 64'h4444444444444402, 32'd11, 32'd993000);  // U after U
        idle(4);

        $display("-- test 5: idle cycles inside messages");
        gaps_on = 1;
        msg_add(64'h5555555555555501, OFFER, 32'd12, 32'd994000, 0);
        msg_replace(64'h5555555555555501, 64'h5555555555555502, 32'd13, 32'd995000);
        msg_exec(64'h5555555555555502, 32'd5, 1);
        msg_skip(8'h49, 50);
        msg_delete(64'h5555555555555502);
        gaps_on = 0;
        idle(4);

        $display("-- test 6: other stocks are filtered out (every type, including U)");
        other = 1;
        msg_add(64'h6666666666666601, BID, 32'd1, 32'd996000, 0);
        msg_add(64'h6666666666666602, OFFER, 32'd2, 32'd996100, 1);
        msg_exec(64'h6666666666666601, 32'd1, 0);
        msg_exec(64'h6666666666666601, 32'd1, 1);
        msg_cancel(64'h6666666666666602, 32'd1);
        msg_delete(64'h6666666666666601);
        msg_replace(64'h6666666666666602, 64'h6666666666666603, 32'd3, 32'd996200);
        other = 0;
        idle(3);
        // interleaved back-to-back: ours, other U, ours, other, ours
        msg_add(64'h7777777777777701, BID, 32'd4, 32'd997000, 0);
        other = 1; msg_replace(64'h7777777777777701, 64'h7777777777777702, 32'd5, 32'd997100); other = 0;
        msg_delete(64'h7777777777777701);
        other = 1; msg_cancel(64'h7777777777777701, 32'd6); other = 0;
        msg_replace(64'h7777777777777703, 64'h7777777777777704, 32'd7, 32'd997200);
        idle(4);

        $display("   directed: %0d checks, %0d errors", checks, errors);

        $display("-- test 7: %0d random messages (30%% other stocks), random idle cycles", N_RANDOM);
        repeat (N_RANDOM) begin
            gaps_on = ($urandom_range(0, 99) < 20);
            other   = ($urandom_range(0, 99) < 30);
            random_msg();
            if ($urandom_range(0, 99) < 50) idle($urandom_range(1, 3));
        end
        gaps_on = 0;
        other   = 0;
        idle(5);

        for (int i = 0; i < 64; i++)
            if (d_valid[i]) begin
                errors++;
                $display("FAIL: an expected output never came (slot %0d)", i);
            end

        $display("");
        $display("checks=%0d  errors=%0d  outputs expected=%0d got=%0d", checks, errors, n_expected, n_got);
        $display("(messages=%0d, of which ignored types=%0d, other stocks=%0d)", n_msgs, n_skipped, n_other);
        if (errors == 0 && n_got == n_expected) $display("PASS");
        else                                     $display("FAIL");
        $finish;
    end
endmodule
