`default_nettype none

package book_pkg;
    typedef enum logic {BID, OFFER} side_t;

    typedef enum logic [1:0] {
        OP_ADD     = 2'b00,
        OP_DELETE  = 2'b01,
        OP_CANCEL  = 2'b10,
        OP_REPLACE = 2'b11
    } op_t;

    typedef enum logic [7:0] {
        MSG_ADD          = 8'h41,  // 'A' Add Order
        MSG_ADD_MPID     = 8'h46,  // 'F' Add Order with MPID attribution
        MSG_EXECUTED     = 8'h45,  // 'E' Order Executed
        MSG_EXECUTED_PX  = 8'h43,  // 'C' Order Executed With Price
        MSG_CANCEL       = 8'h58,  // 'X' Order Cancel
        MSG_DELETE       = 8'h44,  // 'D' Order Delete
        MSG_REPLACE      = 8'h55   // 'U' Order Replace
    } itch_msg_t;
endpackage
