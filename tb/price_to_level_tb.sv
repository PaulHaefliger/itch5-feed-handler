`default_nettype none

// Self-checking testbench for price_to_level.
//
// Checks, for two different bases:
//   - every level 0..1023: price = base + l*100 must give level l, in_range = 1
//   - the edges: one tick past the top, one tick and one raw unit below the
//     bottom, all out of range
//   - two example prices ($99.98 -> level 198, $40.00 -> out of range)
// The second base proves the base input is really used, not hardwired.
// Uses !== so an X or Z on an output counts as a failure.
//
// Compile:  iverilog -g2012 -o p2l.out rtl/price_to_level.sv tb/price_to_level_tb.sv
// Run:      vvp p2l.out

module price_to_level_tb;

    // ---- DUT signals ----
    logic [31:0] price, base;
    logic [9:0]  level;
    logic        in_range;

    int checks = 0, errors = 0;

    price_to_level dut (
        .price    (price),
        .base     (base),
        .level    (level),
        .in_range (in_range)
    );

    // Apply one price, wait for the combinational logic to settle, then check.
    // exp_lvl is only checked when the price is expected to be in range.
    task automatic check(input logic [31:0] p, input logic exp_in, input int exp_lvl);
        price = p;
        #1;
        checks++;
        if (in_range !== exp_in) begin
            $display("FAIL base=%0d price=%0d: in_range=%0b, expected %0b", base, p, in_range, exp_in);
            errors++;
        end else if (exp_in && level !== exp_lvl) begin
            $display("FAIL base=%0d price=%0d: level=%0d, expected %0d", base, p, level, exp_lvl);
            errors++;
        end
    endtask

    // Sweep every level for the current base, plus the out-of-range edges.
    task automatic sweep();
        for (int l = 0; l < 1024; l++)
            check(base + l*100, 1'b1, l);   // every level 0..1023 must be exact
        check(base + 102400, 1'b0, 0);      // one tick past the top edge
        check(base - 100,    1'b0, 0);      // one tick below the bottom edge
        check(base - 1,      1'b0, 0);      // one raw unit below the bottom edge
    endtask

    initial begin
        // Window base $98.00
        base = 32'd980000;
        sweep();
        check(32'd999800, 1'b1, 198);       // $99.98 -> level 198
        check(32'd400000, 1'b0, 0);         // $40.00 -> far below the window

        // A different base ($152.00, the MSFT replay window)
        base = 32'd1520000;
        sweep();

        $display("checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule
