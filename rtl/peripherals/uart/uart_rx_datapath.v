module uart_rx_datapath
#(
    parameter integer NB_DATA = 8,
    parameter integer SB_TICK = 16
)
(
    input  wire               clk,
    input  wire               reset,
    input  wire               rx,
    // control
    input  wire               s_clr, s_inc,
    input  wire               n_clr, n_inc,
    input  wire               b_shift, b_clr,
    // estado
    output wire               s_eq_7,
    output wire               s_eq_15,
    output wire               s_eq_stop,
    output wire               n_last,
    output wire [NB_DATA-1:0] dout
);
    localparam integer NB_N = (NB_DATA > 1) ? $clog2(NB_DATA) : 1;

    reg [3:0]         s_reg;
    reg [NB_N-1:0]    n_reg;
    reg [NB_DATA-1:0] b_reg;

    always @(posedge clk) begin
        if (reset) begin
            s_reg <= 0;
            n_reg <= 0;
            b_reg <= 0;
        end else begin
            // contador de ticks
            if      (s_clr) s_reg <= 0;
            else if (s_inc) s_reg <= s_reg + 1'b1;
            // contador de bits
            if      (n_clr) n_reg <= 0;
            else if (n_inc) n_reg <= n_reg + 1'b1;
            // registro de desplazamiento (LSB primero)
            if      (b_clr)   b_reg <= {NB_DATA{1'b0}};
            else if (b_shift) b_reg <= {rx, b_reg[NB_DATA-1:1]};
        end
    end

    assign s_eq_7    = (s_reg == 4'd7);
    assign s_eq_15   = (s_reg == 4'd15);
    assign s_eq_stop = (s_reg == SB_TICK-1);
    assign n_last    = (n_reg == NB_DATA-1);
    assign dout      = b_reg;
endmodule
