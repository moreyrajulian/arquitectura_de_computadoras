`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// pc_logic
//
// Registro PC y selección de la próxima dirección de la etapa IF
// (docs/spec/pipeline.md §3.1).
//
// Función:
//   Mantiene pc_reg y calcula pc_next con la prioridad de §3.1:
//     redirect   -> pc_next = i_redirect_pc   (salto tomado: gana siempre)
//     stop_fetch -> pc_next = pc_reg          (HALT en vuelo, §3.4)
//     si no      -> pc_next = pc_reg + 4
//   pc_reg solo se actualiza con i_en_pc = 1 (stall o core detenido,
//   decisión 018). No enmascara bits: un destino desalineado o fuera de
//   rango llega a o_pc tal cual para que IF lo informe (memoria.md §6).
//
// Parámetros:
//   NB_PC : ancho del PC
//
// Puertos:
//   i_clk         : reloj del sistema
//   i_rst         : reset síncrono, activo en alto; gana sobre i_en_pc
//   i_en_pc       : en 0 el PC no cambia (en_pc = enable & ~stall, §10.4)
//   i_redirect    : salto tomado resuelto en EX (§5.3)
//   i_redirect_pc : destino del salto                          [NB_PC-1:0]
//   i_stop_fetch  : HALT en el pipeline; retiene el PC (§3.4)
//   o_pc          : pc_reg, dirección de la memoria de programa [NB_PC-1:0]
//
// Latencia: 1 ciclo (entradas -> o_pc).
// Reset   : o_pc = 0x0000_0000 (memoria.md §1).
//======================================================================

module pc_logic
#(
    parameter integer NB_PC = 32
)
(
    input  wire             i_clk,
    input  wire             i_rst,
    input  wire             i_en_pc,
    input  wire             i_redirect,
    input  wire [NB_PC-1:0] i_redirect_pc,
    input  wire             i_stop_fetch,
    output wire [NB_PC-1:0] o_pc
);

    localparam [NB_PC-1:0] PC_RST  = {NB_PC{1'b0}};   // primera palabra de imem
    localparam [NB_PC-1:0] PC_STEP = 4;               // instrucciones de 4 bytes

    reg [NB_PC-1:0] pc_reg;
    reg [NB_PC-1:0] pc_next;

    // Secuencial: reset síncrono con prioridad sobre el enable (decisión 018)
    always @(posedge i_clk) begin
        if (i_rst)
            pc_reg <= PC_RST;
        else if (i_en_pc)
            pc_reg <= pc_next;
    end

    // Próximo PC: redirect > stop_fetch > +4. La asignación por defecto
    // evita latches; redirect queda último en el mux, el más cerca de pc_reg.
    always @(*) begin
        pc_next = pc_reg + PC_STEP;
        if (i_redirect)
            pc_next = i_redirect_pc;
        else if (i_stop_fetch)
            pc_next = pc_reg;
    end

    assign o_pc = pc_reg;

endmodule

`default_nettype wire
