`default_nettype none

module price_to_level(
    input  logic [31:0] price,
    input  logic [31:0] base,
    output logic [9:0]  level,
    output logic        in_range
);
    localparam int W_RAW = 102400;
    logic [16:0] diff;
    logic [27:0] product;

    always_comb begin
        in_range = '1;
        if (price < base || base + W_RAW <= price) begin
            in_range = '0;
        end
    end

    always_comb begin
        diff = price - base;
        product = diff * 1311;
    end

    assign level = product[26:17];
endmodule
