`default_nettype none
import book_pkg::*;

module itch_decoder (
    input  logic        rst,
    input  logic        clk,
    input  logic        itch_start,
    input  logic        in_valid,
    input  logic [7:0]  in_byte,
    input  logic [15:0] stock_locate,
    output logic        out_valid,
    output op_t         op,
    output logic [63:0] ref_num,
    output side_t       side,
    output logic [31:0] price,
    output logic [31:0] shares
);
    logic        busy, last_byte;
    logic [15:0] count;

    logic        read_len, read_type, read_px, read_ref, read_new_ref, read_shares, read_sd, read_loc,
                 replace_pending, replace_phase, decoded;
    logic [63:0] new_ref;
    logic [15:0] msg_len, cur_loc;
    logic [7:0]  msg_type, sd;

    always_comb begin
        case (sd)
            8'h42:   side = BID;
            8'h53:   side = OFFER;
            default: side = BID;
        endcase
        case (msg_type)
            default: op = OP_ADD;
            MSG_ADD, MSG_ADD_MPID: begin
                op = OP_ADD;
            end
            MSG_EXECUTED, MSG_EXECUTED_PX, MSG_CANCEL: begin
                op = OP_CANCEL;
            end
            MSG_DELETE: begin
                op = OP_DELETE;
            end
            MSG_REPLACE: begin
                if (replace_phase) op = OP_REPLACE;
                else               op = OP_DELETE;
            end
        endcase
    end

    always_comb begin
        read_len     = '0;
        read_type    = '0;
        read_px      = '0;
        read_ref     = '0;
        read_new_ref = '0;
        read_shares  = '0;
        read_sd      = '0;
        read_loc     = '0;
        decoded      = '0;
        last_byte    = in_valid && (busy || itch_start) && count == msg_len + 1 && count >= 2;
        if (in_valid && (busy || itch_start)) begin
            if (count <= 1)      read_len  = '1;
            else if (count == 2) read_type = '1;
            else if (count <= 4) read_loc  = '1;
            else begin
                case (msg_type)
                    MSG_ADD, MSG_ADD_MPID: begin
                        decoded = '1;
                        if (count >= 13 && count <= 20) read_ref     = '1;
                        if (count == 21)                read_sd      = '1;
                        if (count >= 22 && count <= 25) read_shares  = '1;
                        if (count >= 34 && count <= 37) read_px      = '1;
                    end
                    MSG_EXECUTED, MSG_EXECUTED_PX, MSG_CANCEL: begin
                        decoded = '1;
                        if (count >= 13 && count <= 20) read_ref     = '1;
                        if (count >= 21 && count <= 24) read_shares  = '1;
                    end
                    MSG_DELETE: begin
                        decoded = '1;
                        if (count >= 13 && count <= 20) read_ref     = '1;
                    end
                    MSG_REPLACE: begin
                        decoded = '1;
                        if (count >= 13 && count <= 20) read_ref     = '1;
                        if (count >= 21 && count <= 28) read_new_ref = '1;
                        if (count >= 29 && count <= 32) read_shares  = '1;
                        if (count >= 33 && count <= 36) read_px      = '1;
                    end
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (read_len) begin
            msg_len <= {msg_len[7:0], in_byte};
        end else if (read_type)    msg_type <= in_byte;
        else if (read_loc)         cur_loc  <= {cur_loc[7:0], in_byte};
        else if (read_px)          price    <= {price[23:0], in_byte};
        else if (read_ref)         ref_num  <= {ref_num[55:0], in_byte};
        else if (read_new_ref)     new_ref  <= {new_ref[55:0], in_byte};
        else if (read_shares)      shares   <= {shares[23:0], in_byte};
        else if (read_sd)          sd       <= in_byte;
        if (replace_pending) ref_num <= new_ref;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            out_valid       <= '0;
            busy            <= '0;
            count           <= '0;
            replace_pending <= '0;
            replace_phase   <= '0;
        end else begin
            if (itch_start) begin
                busy  <= '1;
                count <= 1;
            end else if (last_byte) begin
                busy  <= '0;
                count <= '0;
            end else if (!busy) begin
                count <= '0;
            end else if (in_valid) begin
                count <= count + 1;
            end
            replace_pending <= last_byte && msg_type == MSG_REPLACE;
            replace_phase   <= replace_pending;
            out_valid       <= ((last_byte && decoded) || replace_pending) && cur_loc == stock_locate;
        end
    end

endmodule