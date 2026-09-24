module uart_rx
#(
    parameter integer NB_DATA = 8,
    parameter integer SB_TICK = 16
)
(
    input  wire               clk,
    input  wire               reset,
    input  wire               rx,
    input  wire               s_tick,
    output wire               rx_done_tick,
    output wire [NB_DATA-1:0] dout
);
    wire s_clr, s_inc, n_clr, n_inc, b_shift, b_clr;
    wire s_eq_7, s_eq_15, s_eq_stop, n_last;

    uart_fsm u_fsm (
        .clk(clk), .reset(reset), .s_tick(s_tick),
        .go(~rx), .stop_ok(rx),
        .start_done(s_eq_7), .bit_done(s_eq_15),
        .stop_done(s_eq_stop), .n_last(n_last),
        .s_clr(s_clr), .s_inc(s_inc), .n_clr(n_clr), .n_inc(n_inc),
        .b_load(), .b_shift(b_shift), .b_clr(b_clr),
        .done_tick(rx_done_tick),
        .st_idle(), .st_start(), .st_data(), .st_stop()
    );

    uart_rx_datapath #(.NB_DATA(NB_DATA), .SB_TICK(SB_TICK)) u_dp (
        .clk(clk), .reset(reset), .rx(rx),
        .s_clr(s_clr), .s_inc(s_inc), .n_clr(n_clr), .n_inc(n_inc),
        .b_shift(b_shift), .b_clr(b_clr),
        .s_eq_7(s_eq_7), .s_eq_15(s_eq_15), .s_eq_stop(s_eq_stop), .n_last(n_last),
        .dout(dout)
    );
endmodule
