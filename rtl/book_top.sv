`default_nettype none

module book_top (
    input  logic        rst,
    input  logic        clk,
    input  logic        in_valid,
    input  logic [1:0]  op,
    input  logic [63:0] ref_num,
    input  side_t       side,
    input  logic [31:0] price,
    input  logic [31:0] shares,
    output logic        bid_valid,
    output logic        offer_valid,
    output logic [31:0] best_bid_px,
    output logic [31:0] best_offer_px,
    output logic [35:0] best_bid_qty,
    output logic [35:0] best_offer_qty,
    output logic        book_degraded
);
    localparam logic [31:0] BASE = 1520000;

    logic        rt_valid, rt_add;
    side_t       rt_side;
    logic [31:0] rt_price, rt_shares;

    logic [9:0]  level, bid_level, offer_level;
    logic        in_range;

    ref_table u_ref_table (
        .rst        (rst),
        .clk        (clk),
        .in_valid   (in_valid),
        .op         (op),
        .side       (side),
        .ref_num    (ref_num),
        .price      (price),
        .shares     (shares),
        .out_valid  (rt_valid),
        .out_side   (rt_side),
        .out_add    (rt_add),
        .out_price  (rt_price),
        .out_shares (rt_shares),
        .book_degraded (book_degraded)
    );

    price_to_level u_price_to_level (
        .price    (rt_price),
        .base     (BASE),
        .level    (level),
        .in_range (in_range)
    );

    book_side #(.IS_BID(1)) u_bid_side (
        .rst           (rst),
        .clk           (clk),
        .in_valid      (rt_valid && in_range && rt_side == BID),
        .level         (level),
        .shares        (rt_shares),
        .add           (rt_add),
        .best_valid    (bid_valid),
        .best_level    (bid_level),
        .best_quantity (best_bid_qty)
    );

    book_side #(.IS_BID(0)) u_offer_side (
        .rst           (rst),
        .clk           (clk),
        .in_valid      (rt_valid && in_range && rt_side == OFFER),
        .level         (level),
        .shares        (rt_shares),
        .add           (rt_add),
        .best_valid    (offer_valid),
        .best_level    (offer_level),
        .best_quantity (best_offer_qty)
    );

    assign best_bid_px   = BASE + bid_level   * 100;
    assign best_offer_px = BASE + offer_level * 100;
endmodule
