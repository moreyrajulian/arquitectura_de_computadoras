module uart_tx_datapath
#(
    parameter integer NB_DATA = 8,
    parameter integer SB_TICK = 16
)
(
    input  wire               clk,
    input  wire               reset,
    input  wire [NB_DATA-1:0] din,
    // control
    input  wire               s_clr, s_inc,
    input  wire               n_clr, n_inc,
    input  wire               b_load, b_shift,
    input  wire               st_start, st_data,
    // estado
    output wire               start_done,
    output wire               bit_done,
    output wire               stop_done,
    output wire               n_last,
    output wire               tx
);
    localparam integer NB_N = (NB_DATA > 1) ? $clog2(NB_DATA) : 1;

    reg [3:0]         s_reg;
    reg [NB_N-1:0]    n_reg;
    reg [NB_DATA-1:0] b_reg;
    reg               tx_reg;

    always @(posedge clk) begin
        if (reset) begin
            s_reg  <= 0;
            n_reg  <= 0;
            b_reg  <= 0;
            tx_reg <= 1'b1;
        end else begin
            if      (s_clr) s_reg <= 0;
            else if (s_inc) s_reg <= s_reg + 1'b1;

            if      (n_clr) n_reg <= 0;
            else if (n_inc) n_reg <= n_reg + 1'b1;

            if      (b_load)  b_reg <= din;
            else if (b_shift) b_reg <= b_reg >> 1;

            // salida registrada segun el estado (sin glitches)
            if      (st_start) tx_reg <= 1'b0;
            else if (st_data)  tx_reg <= b_reg[0];
            else               tx_reg <= 1'b1;   // idle y stop
        end
    end

    assign start_done = (s_reg == 4'd15);
    assign bit_done   = (s_reg == 4'd15);
    assign stop_done  = (s_reg == SB_TICK-1);
    assign n_last     = (n_reg == NB_DATA-1);
    assign tx         = tx_reg;
endmodule 
