`default_nettype none
import book_pkg::*;

module ref_table #(
    parameter int INDEX_BITS = 12
)(
    input  logic        rst,
    input  logic        clk,
    input  logic        in_valid,
    input  op_t         op,
    input  side_t       side,
    input  logic [31:0] price,
    input  logic [31:0] shares,
    input  logic [63:0] ref_num,
    output logic        out_valid,
    output side_t       out_side,
    output logic        out_add,
    output logic [31:0] out_price,
    output logic [31:0] out_shares,
    output logic        book_degraded
);
    localparam int TAG_WIDTH = 64 - INDEX_BITS;
    logic [2**INDEX_BITS-1:0][3:0] valid;
    typedef struct packed {
        side_t                side;
        logic [TAG_WIDTH-1:0] tag_num;
        logic [31:0]          price;
        logic [31:0]          shares;
    } hash_slot_t;
    hash_slot_t hash_table [4][0:2**INDEX_BITS-1];

    logic [TAG_WIDTH-1:0]  tag_in;
    logic [INDEX_BITS-1:0] index_in;
    assign index_in = ref_num[INDEX_BITS-1:0];
    assign tag_in   = ref_num[63:INDEX_BITS];

    hash_slot_t r_data [4];
    hash_slot_t w_data;
    hash_slot_t cur_way [4];
    hash_slot_t new_slot;

    logic [INDEX_BITS-1:0] index1;
    logic [TAG_WIDTH-1:0]  tag1;
    logic                  v1;
    op_t                   op1;
    side_t                 side1;
    logic [31:0]           price1;
    logic [31:0]           shares1;

    logic                  wv;
    logic [1:0]            w_way;
    logic [1:0]            wr_way;
    logic                  do_write;
    logic [INDEX_BITS-1:0] w_index;
    logic                  set_valid;
    logic                  clr_valid;

    logic [3:0]            hit_vec;
    logic [1:0]            hit_way;
    logic                  hit;

    logic [3:0]            free_vec;
    logic [1:0]            free_way;
    logic                  any_free;
    logic                  overflow;

    side_t                 saved_side;
    logic                  saved_valid;

    // iverilog workarounds: copy the struct out of the array before selecting a field,
    // and read the valid row into a flat vector before indexing by way
    hash_slot_t tmp_way;
    logic [3:0] valid_row;

    always_comb begin
        valid_row = valid[index1];
        free_way  = '0;
        for (int i = 0; i < 4; i++) begin
            cur_way[i] = r_data[i];
            if (wv && w_index == index1 && w_way == i) begin
                cur_way[i] = w_data;
            end
            tmp_way    = cur_way[i];
            hit_vec[i] = tmp_way.tag_num == tag1 && valid_row[i];
        end
        hit_way[0] = hit_vec[1] | hit_vec[3];
        hit_way[1] = hit_vec[2] | hit_vec[3];
        hit        = |hit_vec;
        free_vec   = ~valid_row;
        any_free   = |free_vec;
        for (int i = 3; i >= 0; i--) begin
            if (free_vec[i]) free_way = i;
        end
    end

    hash_slot_t hit_slot;
    always_comb begin
        out_valid  = '0;
        overflow   = '0;
        wr_way     = hit_way;
        hit_slot   = cur_way[hit_way];
        new_slot   = hit_slot;
        do_write   = 1'b0;
        set_valid  = 1'b0;
        clr_valid  = 1'b0;
        out_shares = '0;
        out_price  = '0;
        out_side   = BID;
        out_add    = '0;

        if (v1) begin
            case (op1)
                OP_ADD: begin
                    if (any_free) begin
                        do_write         = '1;
                        new_slot.side    = side1;
                        new_slot.tag_num = tag1;
                        new_slot.price   = price1;
                        new_slot.shares  = shares1;
                        set_valid        = '1;
                        out_add          = '1;
                        out_valid        = '1;
                        out_shares       = shares1;
                        out_price        = price1;
                        out_side         = side1;
                        wr_way           = free_way;
                    end else begin
                        overflow = '1;
                    end
                end
                OP_DELETE: begin
                    if (hit) begin
                        clr_valid  = '1;
                        out_valid  = '1;
                        out_shares = hit_slot.shares;
                        out_side   = hit_slot.side;
                        out_price  = hit_slot.price;
                    end
                end
                OP_CANCEL: begin
                    if (hit) begin
                        do_write        = '1;
                        new_slot.shares = hit_slot.shares - shares1;
                        if (new_slot.shares == '0) begin
                            clr_valid = '1;
                        end
                        out_shares = shares1;
                        out_valid  = '1;
                        out_side   = hit_slot.side;
                        out_price  = hit_slot.price;
                    end
                end
                OP_REPLACE: begin
                    if (any_free && saved_valid) begin
                        do_write         = '1;
                        new_slot.side    = saved_side;
                        new_slot.tag_num = tag1;
                        new_slot.price   = price1;
                        new_slot.shares  = shares1;
                        set_valid        = '1;
                        out_add          = '1;
                        out_valid        = '1;
                        out_shares       = shares1;
                        out_price        = price1;
                        out_side         = saved_side;
                        wr_way           = free_way;
                    end else begin
                        overflow = '1;
                    end
                end
            endcase
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            valid         <= '0;
            v1            <= '0;
            wv            <= '0;
            book_degraded <= '0;
            saved_valid   <= '0;
        end else begin
            v1          <= in_valid;
            wv          <= do_write;
            saved_valid <= clr_valid;
            if (set_valid) begin
                valid[index1] <= valid[index1] | 4'b1 << wr_way;
            end else if (clr_valid) begin
                valid[index1] <= valid[index1] & ~(4'b1 << wr_way);
            end
            if (overflow) book_degraded <= '1;
        end
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < 4; i++) begin
            r_data[i] <= hash_table[i][index_in];
        end
        index1  <= index_in;
        tag1    <= tag_in;
        op1     <= op;
        side1   <= side;
        price1  <= price;
        shares1 <= shares;
        if (do_write) begin
            hash_table[wr_way][index1] <= new_slot;
            w_index <= index1;
            w_data  <= new_slot;
            w_way   <= wr_way;
        end
        saved_side <= hit_slot.side;
    end

endmodule