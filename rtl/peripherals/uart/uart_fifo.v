`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// uart_fifo
//
// FIFO de recepción de la UART de la Debug Unit (decisión 035,
// docs/spec/protocolo_debug.md §1). Guarda los bytes que llegan mientras
// la FSM de protocolo está transmitiendo (por ejemplo, un EVT_HALTED).
//
// Función:
//   Cola de 2^NB_ADDR palabras. i_push escribe i_data al final; i_pop saca
//   la más vieja, que está siempre en o_data (lectura asíncrona: o_data
//   es válido mientras o_empty = 0).
//   - Push con la FIFO llena: se descarta el dato, salvo que en el mismo
//     ciclo haya un pop, que libera un lugar.
//   - Pop con la FIFO vacía: no tiene efecto. Un push y un pop en el mismo
//     ciclo con la FIFO vacía dejan el dato nuevo adentro.
//   Los punteros tienen un bit más que la dirección: con los mismos bits
//   bajos, la FIFO está vacía si el bit alto coincide y llena si no.
//
// Parámetros:
//   NB_DATA : ancho de cada palabra
//   NB_ADDR : bits de dirección; la profundidad es 2^NB_ADDR
//
// Puertos:
//   i_clk   : reloj del sistema
//   i_rst   : reset síncrono, activo en alto; vacía la FIFO
//   i_push  : escribe i_data al final (si hay lugar)
//   i_data  : dato a escribir                     [NB_DATA-1:0]
//   i_pop   : saca el dato más viejo (si hay alguno)
//   o_data  : dato más viejo                      [NB_DATA-1:0]
//   o_empty : no hay datos
//   o_full  : no hay lugar
//
// Latencia: un dato escrito aparece en o_data (con o_empty = 0) en el
//           ciclo siguiente al push.
// Reset   : punteros en 0 (o_empty = 1, o_full = 0). La memoria no se
//           resetea: con la FIFO vacía su contenido no se lee.
//======================================================================

module uart_fifo
#(
    parameter integer NB_DATA = 8,
    parameter integer NB_ADDR = 5
)
(
    input  wire               i_clk,
    input  wire               i_rst,
    input  wire               i_push,
    input  wire [NB_DATA-1:0] i_data,
    input  wire               i_pop,
    output wire [NB_DATA-1:0] o_data,
    output wire               o_empty,
    output wire               o_full
);

    localparam integer DEPTH = 1 << NB_ADDR;

    reg [NB_DATA-1:0] mem [0:DEPTH-1];
    reg [NB_ADDR:0]   wr_ptr_reg;
    reg [NB_ADDR:0]   rd_ptr_reg;

    wire same_addr = (wr_ptr_reg[NB_ADDR-1:0] == rd_ptr_reg[NB_ADDR-1:0]);
    wire same_lap  = (wr_ptr_reg[NB_ADDR] == rd_ptr_reg[NB_ADDR]);
    wire empty     = same_addr & same_lap;
    wire full      = same_addr & ~same_lap;

    wire do_pop  = i_pop & ~empty;
    wire do_push = i_push & (~full | do_pop);

    // Memoria: solo escritura sincrónica, sin reset (memoria distribuida)
    always @(posedge i_clk) begin
        if (do_push)
            mem[wr_ptr_reg[NB_ADDR-1:0]] <= i_data;
    end

    // Punteros
    always @(posedge i_clk) begin
        if (i_rst) begin
            wr_ptr_reg <= {(NB_ADDR+1){1'b0}};
            rd_ptr_reg <= {(NB_ADDR+1){1'b0}};
        end
        else begin
            if (do_push)
                wr_ptr_reg <= wr_ptr_reg + 1'b1;
            if (do_pop)
                rd_ptr_reg <= rd_ptr_reg + 1'b1;
        end
    end

    assign o_data  = mem[rd_ptr_reg[NB_ADDR-1:0]];
    assign o_empty = empty;
    assign o_full  = full;

endmodule

`default_nettype wire
