`default_nettype none

// Price to book level: level = (price - base) / 100 for a 1024-level window of
// $0.01 ticks starting at base. Purely combinational.

module price_to_level(
    input  logic [31:0] price,
    input  logic [31:0] base,
    output logic [9:0]  level,
    output logic        in_range
);
    // Window width in price units (1024 ticks x 100)
    localparam int W_RAW = 102400;
    logic [16:0] diff;
    logic [27:0] product;

    // Range check on the raw price, before the subtraction can wrap
    always_comb begin
        in_range = '1;
        if (price < base || base + W_RAW <= price) begin
            in_range = '0;
        end
    end

    // Divide by 100 as multiply by 1311 and shift right by 17 (exact for 0..1023)
    always_comb begin
        diff    = price - base;
        product = diff * 1311;
    end

    assign level = product[26:17];

endmodule