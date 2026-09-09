`timescale 1ns / 1ps
//======================================================================
// Top level: UART (rx/tx) + Interface Circuit + ALU
// DVSR default = 326 -> clk=50MHz, baud=9600 (16x oversampling). Ajustar
// segun clk/baudrate reales del proyecto.
//======================================================================
module top
#(
    parameter integer NB_DATA = 8,
    parameter integer DVSR    = 326
)
(
    input  wire clk, reset,
    input  wire rx,
    output wire tx
);
    // señales entre baud_gen y rx/tx
    wire s_tick;

    // señales entre uart_rx y intf_circ (lado Rx)
    wire [NB_DATA-1:0] rx_dout;
    wire rx_done_tick;
    wire [NB_DATA-1:0] r_data;
    wire rx_empty;
    wire rd;

    // señales entre intf_circ y uart_tx (lado Tx)
    wire [NB_DATA-1:0] tx_din;
    wire tx_done_tick;
    wire tx_start;
    wire [NB_DATA-1:0] w_data;
    wire wr;
    wire tx_full;

    baud_gen #(.DVSR(DVSR)) BAUD_GEN (
        .clk(clk), .reset(reset),
        .tick(s_tick)
    );

    uart_rx #(.NB_DATA(NB_DATA)) UART_RX (
        .clk(clk), .reset(reset),
        .rx(rx), .s_tick(s_tick),
        .rx_done_tick(rx_done_tick),
        .dout(rx_dout)
    );

    uart_tx #(.NB_DATA(NB_DATA)) UART_TX (
        .clk(clk), .reset(reset),
        .tx_start(tx_start), .s_tick(s_tick),
        .din(tx_din),
        .tx_done_tick(tx_done_tick),
        .tx(tx)
    );

    intf_circ #(.NB_DATA(NB_DATA)) INTF_CIRC (
        .clk(clk), .reset(reset),
        // lado Rx
        .rx_d_out(rx_dout), .rx_done_tick(rx_done_tick),
        .rd(rd), .r_data(r_data), .rx_empty(rx_empty),
        // lado Tx
        .w_data(w_data), .wr(wr), .tx_done(tx_done_tick),
        .tx_d_in(tx_din), .tx_full(tx_full), .tx_start(tx_start)
    );

    alu #(.NB_DATA(NB_DATA)) ALU (
        .clk(clk), .reset(reset),
        .r_data(r_data), .rx_empty(rx_empty), .rd(rd),
        .tx_full(tx_full), .wr(wr), .w_data(w_data)
    );

endmodule
