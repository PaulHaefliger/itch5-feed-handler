`default_nettype none

// Top level: ITCH byte stream in, best bid and offer out.
// itch_decoder -> book_top, 5 cycles from the last byte of a message to the BBO.

module feed_handler (
    input  logic        rst,
    input  logic        clk,
    input  logic        itch_start,
    input  logic        in_valid,
    input  logic [7:0]  in_byte,
    input  logic [15:0] stock_locate,
    output logic        bid_valid,
    output logic        offer_valid,
    output logic [31:0] best_bid_px,
    output logic [31:0] best_offer_px,
    output logic [35:0] best_bid_qty,
    output logic [35:0] best_offer_qty,
    output logic        book_degraded
);
    logic        out_valid;
    logic [63:0] ref_num;
    logic [31:0] price, shares;
    op_t         op;
    side_t       side;

    // Parses ITCH messages for one stock into book operations
    itch_decoder u_decoder (
        .rst          (rst),
        .clk          (clk),
        .itch_start   (itch_start),
        .in_valid     (in_valid),
        .in_byte      (in_byte),
        .stock_locate (stock_locate),
        .out_valid    (out_valid),
        .op           (op),
        .ref_num      (ref_num),
        .side         (side),
        .price        (price),
        .shares       (shares)
    );

    // Order book
    book_top u_book (
        .rst            (rst),
        .clk            (clk),
        .in_valid       (out_valid),
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
        .best_offer_qty (best_offer_qty),
        .book_degraded  (book_degraded)
    );

endmodule