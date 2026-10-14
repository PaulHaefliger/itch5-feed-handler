`default_nettype none
import book_pkg::*;

// Real-data replay for feed_handler.
//
// Reads a binary stream file written by itch_replay_prep.py (2-byte big-endian
// length + ITCH message, repeated), drives it byte by byte (itch_start with the
// first length byte, back to back), and logs the BBO to a text file every time
// it changes, in the same format as the Python reference trace:
//     bid_valid bid_px bid_qty offer_valid offer_px offer_qty
// (px and qty printed as 0 when that side is empty). Then compare:
//     diff msft_ref_bbo.txt msft_sim_bbo.txt
//
// IMPORTANT: book_top's BASE must equal the --base given to the Python script.
//
// Plusargs:
//     +stream=<file>   input stream      (default msft_stream.bin)
//     +trace=<file>    output BBO trace  (default sim_bbo.txt)
//     +locate=<n>      stock locate, decimal (printed by the Python script)
//     +gaps            insert random idle cycles between and inside messages
//
// Compile:  iverilog -g2012 -o replay.out rtl/book_pkg.sv rtl/itch_decoder.sv rtl/ref_table.sv \
//               rtl/price_to_level.sv rtl/next_best.sv rtl/book_side.sv rtl/book_top.sv \
//               rtl/feed_handler.sv tb/feed_handler_replay_tb.sv
// Run:      vvp replay.out +locate=5291 +stream=data/msft_stream.bin +trace=msft_sim_bbo.txt

module feed_handler_replay_tb;
    // ---------------- DUT ----------------
    logic        clk, rst, itch_start, in_valid;
    logic [7:0]  in_byte;
    logic [15:0] stock_locate;
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

    // ---------------- BBO logger ----------------
    integer      fout;
    logic        l_bv = 0, l_ov = 0;
    logic [31:0] l_bpx = 0, l_opx = 0;
    logic [35:0] l_bq = 0, l_oq = 0;
    logic        n_bv, n_ov;
    logic [31:0] n_bpx, n_opx;
    logic [35:0] n_bq, n_oq;
    longint      cycles = 0, n_changes = 0, degraded_at = -1;
    bit          logging = 0;

    always @(negedge clk) begin
        cycles++;
        if (logging) begin
            // normalise an empty side to 0 0 0, like the reference
            n_bv = bid_valid;   n_bpx = bid_valid   ? best_bid_px   : 0;  n_bq = bid_valid   ? best_bid_qty   : 0;
            n_ov = offer_valid; n_opx = offer_valid ? best_offer_px : 0;  n_oq = offer_valid ? best_offer_qty : 0;
            if (^{n_bv, n_bpx, n_bq, n_ov, n_opx, n_oq} === 1'bx)
                $display("WARNING cycle %0d: X on a BBO output", cycles);
            if ({n_bv, n_bpx, n_bq, n_ov, n_opx, n_oq} !== {l_bv, l_bpx, l_bq, l_ov, l_opx, l_oq}) begin
                $fwrite(fout, "%0d %0d %0d %0d %0d %0d\n", n_bv, n_bpx, n_bq, n_ov, n_opx, n_oq);
                {l_bv, l_bpx, l_bq, l_ov, l_opx, l_oq} = {n_bv, n_bpx, n_bq, n_ov, n_opx, n_oq};
                n_changes++;
            end
            if (degraded === 1'b1 && degraded_at < 0) begin
                degraded_at = cycles;
                $display("note: book_degraded went high at cycle %0d (ref-table overflow)", cycles);
            end
        end
    end

    // ---------------- stream driver ----------------
    string  stream_file, trace_file;
    integer fin, c, hi, lo, len;
    int     loc;
    bit     gaps, done;
    longint n_msgs = 0;

    task automatic drive_byte(input logic [7:0] b, input bit start);
        if (gaps && $urandom_range(0, 99) < 5) begin
            @(posedge clk);
            itch_start <= 0; in_valid <= 0; in_byte <= $urandom;
        end
        @(posedge clk);
        itch_start <= start;
        in_valid   <= 1;
        in_byte    <= b;
    endtask

    initial begin
        if (!$value$plusargs("stream=%s", stream_file)) stream_file = "msft_stream.bin";
        if (!$value$plusargs("trace=%s",  trace_file))  trace_file  = "sim_bbo.txt";
        if (!$value$plusargs("locate=%d", loc)) begin
            $display("ERROR: give the stock locate with +locate=<n>");
            $finish;
        end
        gaps = $test$plusargs("gaps");
        stock_locate = loc;

        fin = $fopen(stream_file, "rb");
        if (fin == 0) begin $display("ERROR: cannot open %s", stream_file); $finish; end
        fout = $fopen(trace_file, "w");
        if (fout == 0) begin $display("ERROR: cannot open %s", trace_file); $finish; end

        rst = 1; itch_start = 0; in_valid = 0; in_byte = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);
        logging = 1;

        // (no 'break': not supported by every Icarus version)
        done = 0;
        while (!done) begin
            hi = $fgetc(fin);
            lo = (hi < 0) ? -1 : $fgetc(fin);
            if (hi < 0) done = 1;                                        // clean end of file
            else if (lo < 0) begin $display("ERROR: truncated length prefix"); done = 1; end
            else begin
                len = (hi << 8) | lo;
                drive_byte(hi[7:0], 1);
                drive_byte(lo[7:0], 0);
                for (int i = 0; i < len && !done; i++) begin
                    c = $fgetc(fin);
                    if (c < 0) begin $display("ERROR: truncated message %0d", n_msgs); done = 1; end
                    else drive_byte(c[7:0], 0);
                end
                n_msgs++;
                if (n_msgs % 100000 == 0) $display("  %0d messages, %0d BBO changes", n_msgs, n_changes);
            end
        end

        // let the last message drain through decoder + book
        @(posedge clk);
        itch_start <= 0; in_valid <= 0;
        repeat (20) @(posedge clk);

        $fclose(fin);
        $fclose(fout);
        $display("");
        $display("replayed %0d messages in %0d cycles; %0d BBO changes written to %s",
                 n_msgs, cycles, n_changes, trace_file);
        if (degraded_at < 0) $display("book_degraded: never set");
        else                 $display("book_degraded: SET (see note above)");
        $finish;
    end
endmodule
