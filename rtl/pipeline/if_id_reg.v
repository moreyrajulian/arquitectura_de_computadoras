`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// if_id_reg
//
// Registro de segmentación IF/ID (docs/spec/pipeline.md §2, §3.3, §8).
//
// Función:
//   Guarda los campos de IF/ID con las entradas comunes a los cuatro
//   registros de segmentación y la prioridad rst > en > flush (§2):
//     rst          -> burbuja (valid = 0)
//     en = 0       -> conserva todo, aunque flush = 1 (stall o core
//                     detenido: el HALT retenido no se pierde, §3.4)
//     en = 1       -> valid = ~flush; pc = i_pc
//   if_id_instr no tiene flip-flops: es el registro de salida de la
//   memoria de programa (decisión 009). Llega por i_instr y sale tal
//   cual; su ena es el mismo en_if_id que recibe este módulo. Como la
//   BRAM no se borra (decisión 022), el flush y el reset solo ponen
//   valid = 0 y la instrucción queda como burbuja.
//   if_id_pc no se resetea y se carga también durante un flush: los
//   datos de una burbuja no importan (§2), y así redirect solo llega al
//   flip-flop de valid (§5.3).
//
// Parámetros:
//   NB_PC    : ancho del PC
//   NB_INSTR : ancho de la instrucción
//
// Puertos:
//   i_clk   : reloj del sistema
//   i_rst   : reset síncrono, activo en alto; gana sobre i_en
//   i_en    : en_if_id = enable & ~stall (§10.4); en 0 conserva
//   i_flush : flush_if_id = redirect | stop_fetch (§3.3); carga burbuja
//   i_pc    : pc_reg, PC de la instrucción que se busca  [NB_PC-1:0]
//   i_instr : salida registrada de imem                  [NB_INSTR-1:0]
//   o_valid : if_id_valid, 1 = instrucción real, 0 = burbuja
//   o_pc    : if_id_pc                                   [NB_PC-1:0]
//   o_instr : if_id_instr (i_instr sin registrar)        [NB_INSTR-1:0]
//   o_latch : IF/ID agrupado para la Debug Unit, en el orden de §8:
//             {valid, pc, instr}, valid en el bit más alto [NB_PC+NB_INSTR:0]
//
// Latencia: 1 ciclo (i_pc, i_flush -> o_pc, o_valid); o_instr es
//           combinacional desde i_instr (la latencia la pone la BRAM).
// Reset   : o_valid = 0; o_pc no se resetea.
//======================================================================

module if_id_reg
#(
    parameter integer NB_PC    = 32,
    parameter integer NB_INSTR = 32
)
(
    input  wire                    i_clk,
    input  wire                    i_rst,
    input  wire                    i_en,
    input  wire                    i_flush,
    input  wire [NB_PC-1:0]        i_pc,
    input  wire [NB_INSTR-1:0]     i_instr,
    output wire                    o_valid,
    output wire [NB_PC-1:0]        o_pc,
    output wire [NB_INSTR-1:0]     o_instr,
    output wire [NB_PC+NB_INSTR:0] o_latch      // 1 + 32 + 32 = 65 bits (§8)
);

    reg             if_id_valid_reg;
    reg [NB_PC-1:0] if_id_pc_reg;

    // valid: único campo con reset; prioridad rst > en > flush (§2)
    always @(posedge i_clk) begin
        if (i_rst)
            if_id_valid_reg <= 1'b0;
        else if (i_en)
            if_id_valid_reg <= ~i_flush;
    end

    // pc: camino de datos, sin reset (decisión 010); el flush no lo toca
    always @(posedge i_clk) begin
        if (i_en)
            if_id_pc_reg <= i_pc;
    end

    assign o_valid = if_id_valid_reg;
    assign o_pc    = if_id_pc_reg;
    assign o_instr = i_instr;
    assign o_latch = {if_id_valid_reg, if_id_pc_reg, i_instr};

endmodule

`default_nettype wire
