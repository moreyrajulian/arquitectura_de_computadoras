`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// hazard_unit
//
// Unidad de detección de riesgos de la etapa ID (docs/spec/pipeline.md
// §10.3 y §10.4). Esta versión tiene el detector de carga-uso (I-41);
// los enables y el flush de §10.4 los calcula riscv_core hasta I-42.
//
// Función:
//   Detecta una instrucción en ID que lee el registro que carga el load
//   que está en EX. El dato del load recién sale de la BRAM en WB
//   (decisión 009), así que esa instrucción tiene que esperar un ciclo:
//     load_use = id_ex_mem_read && id_ex_rd != 0 && if_id_valid &&
//                (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
//   - Conservadora (decisión 011): compara los campos rs1 = instr[19:15]
//     y rs2 = instr[24:20] sin mirar si la instrucción los usa. Puede
//     frenar de más (lui, jal, el inmediato de una I-type o el HALT, con
//     rs2 = 1), nunca de menos. Son los mismos campos que compara
//     forwarding_unit (§10.2), y por eso nunca se reenvía la dirección
//     de un load desde EX/MEM.
//   - Un sw que guarda el dato recién cargado también frena: no hay
//     forwarding hacia MEM (decisión 011).
//   - x0 nunca frena: un load a x0 no deja ningún valor.
//   - Una burbuja en IF/ID (if_id_valid = 0) no lee registros.
//   - No mira valid de ID/EX: una burbuja tiene mem_read = 0 (§2).
//   Después del stall, el load está en WB y la instrucción frenada en
//   EX recibe el dato por forwarding desde MEM/WB (fwd = 01).
//
// Parámetros:
//   NB_ADDR : ancho del número de registro
//
// Puertos:
//   i_if_id_valid    : IF/ID tiene una instrucción real
//   i_if_id_rs1      : campo rs1 de la instrucción en ID   [NB_ADDR-1:0]
//   i_if_id_rs2      : campo rs2 de la instrucción en ID   [NB_ADDR-1:0]
//   i_id_ex_mem_read : la instrucción en EX es un load
//   i_id_ex_rd       : destino de la instrucción en EX     [NB_ADDR-1:0]
//   o_load_use       : hay que frenar a la instrucción en ID un ciclo
//
// Latencia: 0 ciclos (combinacional).
// Reset   : no tiene.
//======================================================================

module hazard_unit
#(
    parameter integer NB_ADDR = 5
)
(
    input  wire               i_if_id_valid,
    input  wire [NB_ADDR-1:0] i_if_id_rs1,
    input  wire [NB_ADDR-1:0] i_if_id_rs2,
    input  wire               i_id_ex_mem_read,
    input  wire [NB_ADDR-1:0] i_id_ex_rd,
    output wire               o_load_use
);

    localparam [NB_ADDR-1:0] REG_X0 = {NB_ADDR{1'b0}};

    // El load en EX deja un valor en un registro distinto de x0
    wire load_writes = i_id_ex_mem_read & (i_id_ex_rd != REG_X0);

    // La instrucción en ID nombra ese registro en alguno de sus campos
    wire rs1_match = (i_id_ex_rd == i_if_id_rs1);
    wire rs2_match = (i_id_ex_rd == i_if_id_rs2);

    assign o_load_use = load_writes & i_if_id_valid & (rs1_match | rs2_match);

endmodule

`default_nettype wire
