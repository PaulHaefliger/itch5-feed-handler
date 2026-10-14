`default_nettype none

module next_best #(
    parameter logic IS_BID = 1
)(
    input  logic [1023:0] bitmap,
    input  logic [9:0]    L,
    output logic [9:0]    next_level,
    output logic          found
);
    logic [1023:0] masked;
    logic [1023:0] mask;
    always_comb begin
        if (IS_BID) begin
            mask = ((1 << L) - 1);
        end else begin
            mask = ~((1 << (L+1)) - 1);
        end
        masked = mask & bitmap;
        found = '0;
        next_level = '0;
        
        case (IS_BID)
            1'b1: begin
                for (int i = 0; i < 1024; i++) begin
                    if (masked[i]) begin
                        found = 1;
                        next_level = i;
                    end
                end
            end
            1'b0: begin
                for (int i = 1023; i >= 0; i--) begin
                    if (masked[i]) begin
                        found = 1;
                        next_level = i[9:0];
                    end
                end
            end
        endcase
    end
endmodule
