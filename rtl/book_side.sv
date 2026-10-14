`default_nettype none

module book_side #(
    parameter logic IS_BID = 1
)(
    input  logic        rst,
    input  logic        clk,
    input  logic        in_valid,
    input  logic [9:0]  level,
    input  logic [31:0] shares,
    input  logic        add,
    output logic        best_valid,
    output logic [9:0]  best_level,
    output logic [35:0] best_quantity
);
    logic [9:0]    level1, wlevel, best_level1, next_level;
    logic [31:0]   shares1;
    logic          v1, wv, wins, add1, loses, best_valid1, found, changes_best;
    logic [35:0]   rdata, wdata, sum, best_quantity1, rBdata;
    logic [35:0]   qty_mem  [0:1023];
    logic [35:0]   qty_memB [0:1023];
    logic [1023:0] bitmap;

    next_best #(.IS_BID(IS_BID)) find_changed_best (
        .bitmap     (bitmap),
        .L          (level1),
        .next_level (next_level),
        .found      (found)
    );

    initial for (int i = 0; i < 1024; i++) qty_mem[i] = '0;
    initial for (int i = 0; i < 1024; i++) qty_memB[i] = '0;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < 1024; i++) begin
                bitmap[i] <= '0;
            end
            v1 <= '0;
            wv <= '0;
        end else begin
            v1 <= in_valid;
            wv <= v1;
            if (v1) begin
                if (add1) begin
                    bitmap[level1] <= '1;
                end else begin
                    if (sum == '0)
                        bitmap[level1] <= '0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        level1  <= level;
        wlevel  <= level1;
        shares1 <= shares;
        wdata   <= sum;
        add1    <= add;
    end

    always_ff @(posedge clk) begin
        if (v1) begin
            qty_mem[level1]  <= sum;
            qty_memB[level1] <= sum;
        end
        rdata <= qty_mem[level];
    end

    always_comb begin
        case (add1)
            1'b1: begin
                if (wv && wlevel == level1) begin
                    sum = wdata + shares1;
                end else begin
                    sum = rdata + shares1;
                end
            end
            1'b0: begin
                if (wv && wlevel == level1) begin
                    sum = wdata - shares1;
                end else begin
                    sum = rdata - shares1;
                end
            end
        endcase
    end

    always_comb begin
        wins = 0;
        if (add1) begin
            if (IS_BID) wins = !best_valid1 || (level1 >= best_level1);
            else        wins = !best_valid1 || (level1 <= best_level1);
        end
    end

    always_comb begin
        loses = 0;
        if (!add1) begin
            loses = (sum == '0 && level1 == best_level1);
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            changes_best   <= '0;
            best_valid1    <= '0;
            best_level1    <= '0;
            best_quantity1 <= '0;
        end else begin
            changes_best <= v1 && loses;
            if (v1 && wins) begin
                best_level1    <= level1;
                best_quantity1 <= sum;
                changes_best   <= '0;
                best_valid1    <= '1;
            end else if (v1 && loses) begin
                best_level1 <= next_level;
                best_valid1 <= found;
            end else if (v1 && !add1 && level1 == best_level1) begin
                best_quantity1 <= sum;
                changes_best   <= '0;
            end else if (changes_best)
                best_quantity1 <= rBdata;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            best_valid    <= '0;
            best_quantity <= '0;
            best_level    <= '0;
        end else begin
            best_valid    <= best_valid1;
            best_level    <= best_level1;
            best_quantity <= changes_best ? rBdata : best_quantity1;
        end
    end

    always_ff @(posedge clk) rBdata <= qty_memB[next_level];

endmodule