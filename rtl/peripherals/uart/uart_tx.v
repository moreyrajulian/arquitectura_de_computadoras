module uart_tx
#(
    parameter integer NB_DATA = 8,
    parameter integer SB_TICK = 16
)
(
    input  wire               clk,
    input  wire               reset,
    input  wire               tx_start,
    input  wire               s_tick,
    input  wire [NB_DATA-1:0] din,
    output wire               tx_done_tick,
    output wire               tx
);
    wire s_clr, s_inc, n_clr, n_inc, b_load, b_shift, b_clr;
    wire start_done, bit_done, stop_done, n_last;
    wire st_idle, st_start, st_data, st_stop;

    uart_fsm u_fsm (
        .clk(clk), .reset(reset), .s_tick(s_tick),
        .go(tx_start), .stop_ok(1'b1),
        .start_done(start_done), .bit_done(bit_done),
        .stop_done(stop_done), .n_last(n_last),
        .s_clr(s_clr), .s_inc(s_inc), .n_clr(n_clr), .n_inc(n_inc),
        .b_load(b_load), .b_shift(b_shift), .b_clr(b_clr),
        .done_tick(tx_done_tick),
        .st_idle(st_idle), .st_start(st_start), .st_data(st_data), .st_stop(st_stop)
    );

    uart_tx_datapath #(.NB_DATA(NB_DATA), .SB_TICK(SB_TICK)) u_dp (
        .clk(clk), .reset(reset), .din(din),
        .s_clr(s_clr), .s_inc(s_inc), .n_clr(n_clr), .n_inc(n_inc),
        .b_load(b_load), .b_shift(b_shift),
        .st_start(st_start), .st_data(st_data),
        .start_done(start_done), .bit_done(bit_done),
        .stop_done(stop_done), .n_last(n_last),
        .tx(tx)
    );
endmodule
