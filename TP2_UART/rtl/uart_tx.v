`timescale 1ns / 1ps

//======================================================================
// UART transmitter (FSMD). Basado en Listado 8.3 de Chu.
// Espejo del receptor: carga un byte y lo saca bit por bit.
//   - no sobremuestrea: manda un bit cada 16 ticks
//   - tx_reg de 1 bit filtra glitches en la salida
//======================================================================
module uart_tx
#(
    parameter integer DBIT    = 8,
    parameter integer SB_TICK = 16
)
(
    input  wire            clk,
    input  wire            reset,
    input  wire            tx_start,     // pedido de transmision
    input  wire            s_tick,       // tick del baud generator
    input  wire [DBIT-1:0] din,          // byte a transmitir
    output reg             tx_done_tick, // pulso de 1 ciclo al terminar
    output wire            tx            // linea serie de salida
);
    localparam [1:0] idle  = 2'b00,
                     start = 2'b01,
                     data  = 2'b10,
                     stop  = 2'b11;

    reg [1:0]      state_reg, state_next;
    reg [3:0]      s_reg, s_next;
    reg [2:0]      n_reg, n_next;
    reg [DBIT-1:0] b_reg, b_next;
    reg            tx_reg, tx_next;      // buffer de salida (evita glitches)

    always @(posedge clk) begin
        if (reset) begin
            state_reg <= idle;
            s_reg <= 0; n_reg <= 0; b_reg <= 0;
            tx_reg <= 1'b1;              // en reposo la linea es 1
        end else begin
            state_reg <= state_next;
            s_reg <= s_next; n_reg <= n_next; b_reg <= b_next;
            tx_reg <= tx_next;
        end
    end

    always @(*) begin
        state_next   = state_reg;
        tx_done_tick = 1'b0;
        s_next = s_reg; n_next = n_reg; b_next = b_reg;
        tx_next = tx_reg;

        case (state_reg)
            idle: begin
                tx_next = 1'b1;                 // linea en reposo
                if (tx_start) begin
                    state_next = start;
                    s_next = 0;
                    b_next = din;              // engancho el byte
                end
            end
            start: begin
                tx_next = 1'b0;                // start bit = 0
                if (s_tick)
                    if (s_reg == 15) begin
                        state_next = data;
                        s_next = 0; n_next = 0;
                    end else
                        s_next = s_reg + 1;
            end
            data: begin
                tx_next = b_reg[0];           // saco el LSB
                if (s_tick)
                    if (s_reg == 15) begin
                        s_next = 0;
                        b_next = b_reg >> 1;   // corro para el proximo bit
                        if (n_reg == (DBIT-1))
                            state_next = stop;
                        else
                            n_next = n_reg + 1;
                    end else
                        s_next = s_reg + 1;
            end
            stop: begin
                tx_next = 1'b1;               // stop bit = 1
                if (s_tick)
                    if (s_reg == (SB_TICK-1)) begin
                        state_next = idle;
                        tx_done_tick = 1'b1;
                    end else
                        s_next = s_reg + 1;
            end
        endcase
    end

    assign tx = tx_reg;
endmodule