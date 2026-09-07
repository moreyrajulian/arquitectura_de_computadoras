`timescale 1ns / 1ps

//======================================================================
// UART receiver (FSMD con sobremuestreo 16x).
// Basado en Listado 8.1 de Chu "FPGA Prototyping by Verilog Examples".
//   - 4 estados: idle, start, data, stop
//   - s_reg cuenta ticks de muestreo (a 7 = medio del start, a 15 = un bit)
//   - n_reg cuenta bits de datos recibidos
//   - b_reg reensambla el byte por desplazamiento (LSB primero)
//======================================================================
module uart_rx
#(
    parameter integer NB_DATA = 8,   // bits de datos
    parameter integer SB_TICK = 16   // ticks para el stop bit (16 = 1 stop)
)
(
    input  wire            clk,
    input  wire            reset,
    input  wire            rx,          // linea serie de entrada
    input  wire            s_tick,      // tick del baud generator (16x baud)
    output reg             rx_done_tick,// pulso de 1 ciclo: byte listo
    output wire [NB_DATA-1:0] dout         // byte reensamblado
);
    // estados simbolicos
    localparam [1:0] idle  = 2'b00,
                     start = 2'b01,
                     data  = 2'b10,
                     stop  = 2'b11;

    // registros de estado y datos
    reg [1:0]      state_reg, state_next;
    reg [3:0]      s_reg, s_next;   // cuenta ticks (0..15)
    reg [2:0]      n_reg, n_next;   // cuenta bits de datos (0..7)
    reg [NB_DATA-1:0] b_reg, b_next;   // registro de desplazamiento

    // --- registros de estado y datos (secuencial, corre a clk) ---
    always @(posedge clk) begin
        if (reset) begin
            state_reg <= idle;
            s_reg     <= 0;
            n_reg     <= 0;
            b_reg     <= 0;
        end else begin
            state_reg <= state_next;
            s_reg     <= s_next;
            n_reg     <= n_next;
            b_reg     <= b_next;
        end
    end

    // --- logica de proximo estado (combinacional) ---
    always @(*) begin
        // valores por defecto: todo se queda como esta
        state_next   = state_reg;
        rx_done_tick = 1'b0;
        s_next       = s_reg;
        n_next       = n_reg;
        b_next       = b_reg;

        case (state_reg)
            idle:
                if (~rx) begin          // la linea bajo a 0 -> empieza start bit
                    state_next = start;
                    s_next     = 0;
                end
            start:
                if (s_tick)
                    if (s_reg == 7) begin   // medio del start bit
                        state_next = data;
                        s_next     = 0;
                        n_next     = 0;
                    end else
                        s_next = s_reg + 1;
            data:
                if (s_tick)
                    if (s_reg == 15) begin  // paso un bit completo
                        s_next = 0;
                        b_next = {rx, b_reg[NB_DATA-1:1]};  // meto el bit por arriba
                        if (n_reg == (NB_DATA-1))
                            state_next = stop;
                        else
                            n_next = n_reg + 1;
                    end else
                        s_next = s_reg + 1;
            stop:
                if (s_tick)
                    if (s_reg == (SB_TICK-1)) begin  // termino el stop bit
                        state_next   = idle;
                        rx_done_tick = 1'b1;         // aviso: byte listo
                    end else
                        s_next = s_reg + 1;
        endcase
    end

    assign dout = b_reg;
endmodule