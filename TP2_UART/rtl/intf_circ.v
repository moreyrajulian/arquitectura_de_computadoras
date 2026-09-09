module intf_circ #(
    parameter NB_DATA = 8
)(
    input  wire clk, reset,
    // lado Rx
    input  wire [NB_DATA-1:0] rx_d_out,
    input  wire rx_done_tick,
    input  wire rd,
    output wire [NB_DATA-1:0] r_data,
    output wire rx_empty,
    // lado Tx
    input  wire [NB_DATA-1:0] w_data,
    input  wire wr,
    input  wire tx_done,
    output wire [NB_DATA-1:0] tx_d_in,
    output wire tx_full,
    output wire tx_start
);
    wire rx_flag;
    reg  tx_start_reg;

    flag_buff #(.NB_DATA(NB_DATA)) rx_unit (
        .clk(clk), .reset(reset),
        .set_flag(rx_done_tick), .clr_flag(rd),
        .d_in(rx_d_out), .flag(rx_flag), .d_out(r_data)
    );
    assign rx_empty = ~rx_flag;

    flag_buff #(.NB_DATA(NB_DATA)) tx_unit (
        .clk(clk), .reset(reset),
        .set_flag(wr), .clr_flag(tx_done),
        .d_in(w_data), .flag(tx_full), .d_out(tx_d_in)
    );

    always @(posedge clk)
        if (reset) tx_start_reg <= 1'b0;
        else       tx_start_reg <= wr;
    assign tx_start = tx_start_reg;

endmodule
