module uart_fsm
(
    input  wire clk,
    input  wire reset,
    input  wire s_tick,
    // condiciones externas
    input  wire go,          // RX: ~rx      | TX: tx_start
    input  wire stop_ok,     // RX: rx       | TX: 1'b1
    // estado desde el datapath
    input  wire start_done,  // RX: s==7     | TX: s==15
    input  wire bit_done,    // s==15
    input  wire stop_done,   // s==SB_TICK-1
    input  wire n_last,      // n==NB_DATA-1
    // control hacia el datapath
    output reg  s_clr, s_inc,
    output reg  n_clr, n_inc,
    output reg  b_load, b_shift, b_clr,
    output reg  done_tick,
    // estado actual decodificado (salidas Moore)
    output wire st_idle, st_start, st_data, st_stop
);
    localparam [1:0] idle  = 2'b00,
                     start = 2'b01,
                     data  = 2'b10,
                     stop  = 2'b11;

    reg [1:0] state_reg, state_next;

    always @(posedge clk) begin
        if (reset) state_reg <= idle;
        else       state_reg <= state_next;
    end

    always @(*) begin
        state_next = state_reg;
        s_clr = 1'b0;  s_inc = 1'b0;
        n_clr = 1'b0;  n_inc = 1'b0;
        b_load = 1'b0; b_shift = 1'b0; b_clr = 1'b0;
        done_tick = 1'b0;

        case (state_reg)
            idle:
                if (go) begin
                    state_next = start;
                    s_clr      = 1'b1;
                    b_load     = 1'b1;
                end
            start:
                if (s_tick)
                    if (start_done) begin
                        state_next = data;
                        s_clr      = 1'b1;
                        n_clr      = 1'b1;
                    end else
                        s_inc = 1'b1;
            data:
                if (s_tick)
                    if (bit_done) begin
                        s_clr   = 1'b1;
                        b_shift = 1'b1;
                        if (n_last) state_next = stop;
                        else        n_inc      = 1'b1;
                    end else
                        s_inc = 1'b1;
            stop:
                if (s_tick)
                    if (stop_done) begin
                        state_next = idle;
                        if (stop_ok) done_tick = 1'b1;
                        else         b_clr     = 1'b1;
                    end else
                        s_inc = 1'b1;
        endcase
    end

    assign st_idle  = (state_reg == idle);
    assign st_start = (state_reg == start);
    assign st_data  = (state_reg == data);
    assign st_stop  = (state_reg == stop);
endmodule
