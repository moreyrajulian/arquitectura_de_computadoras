module flag_buff #(
    parameter NB_DATA = 8
)(
    input  wire clk, reset,
    input  wire clr_flag, set_flag,
    input  wire [NB_DATA-1:0] d_in,
    output wire flag,
    output wire [NB_DATA-1:0] d_out
);
    reg [NB_DATA-1:0] buf_reg, buf_next;
    reg flag_reg, flag_next;

    always @(posedge clk) begin
        if (reset) begin
            buf_reg  <= 0;
            flag_reg <= 1'b0;
        end else begin
            buf_reg  <= buf_next;
            flag_reg <= flag_next;
        end
    end

    always @(*) begin
        buf_next  = buf_reg;
        flag_next = flag_reg;
        if (set_flag) begin
            buf_next  = d_in;
            flag_next = 1'b1;
        end else if (clr_flag)
            flag_next = 1'b0;
    end

    assign d_out = buf_reg;
    assign flag  = flag_reg;
endmodule
