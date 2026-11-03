`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// forwarding_unit
//
// Unidad de forwarding de la etapa EX (docs/spec/pipeline.md §10.2).
//
// Función:
//   Genera los selectores de los muxes de operandos de EX (§5.1), los
//   ForwardA / ForwardB del libro:
//     fwd_a = (ex_mem_reg_write && ex_mem_rd != 0 && ex_mem_rd == id_ex_rs1) ? FWD_EX_MEM :
//             (mem_wb_reg_write && mem_wb_rd != 0 && mem_wb_rd == id_ex_rs1) ? FWD_WB     :
//                                                                              FWD_ID_EX
//     fwd_b = ídem con id_ex_rs2
//   - EX/MEM tiene prioridad: si las dos instrucciones anteriores
//     escriben el mismo registro, el valor más reciente es el suyo.
//   - x0 nunca se reenvía.
//   - No mira valid: una burbuja tiene reg_write = 0 (§2).
//   - Compara rs1 y rs2 aunque la instrucción no los use; si coincide,
//     el valor reenviado entra a un operando que el control descarta.
//   - No filtra loads en EX/MEM: la detección de carga-uso (§10.3)
//     compara los mismos campos y frena antes a la instrucción que los
//     usa, así que nunca se reenvía la dirección de un load.
//   El dato a guardar de un store y los operandos de beq/bne salen de
//   rs2_val y rs1_val, así que también quedan con forwarding.
//
// Parámetros:
//   NB_ADDR : ancho del número de registro
//   NB_FWD  : ancho de fwd_a / fwd_b (códigos FWD_* de riscv_defs.vh)
//
// Puertos:
//   i_id_ex_rs1        : registro fuente 1 de la instrucción en EX   [NB_ADDR-1:0]
//   i_id_ex_rs2        : registro fuente 2 de la instrucción en EX   [NB_ADDR-1:0]
//   i_ex_mem_rd        : destino de la instrucción en MEM            [NB_ADDR-1:0]
//   i_ex_mem_reg_write : la instrucción en MEM escribe rd
//   i_mem_wb_rd        : destino de la instrucción en WB             [NB_ADDR-1:0]
//   i_mem_wb_reg_write : la instrucción en WB escribe rd
//   o_fwd_a            : selector del mux de rs1 (§5.1)              [NB_FWD-1:0]
//   o_fwd_b            : selector del mux de rs2 (§5.1)              [NB_FWD-1:0]
//
// Latencia: 0 ciclos (combinacional).
// Reset   : no tiene.
//======================================================================

module forwarding_unit
#(
    parameter integer NB_ADDR = 5,
    parameter integer NB_FWD  = 2
)
(
    input  wire [NB_ADDR-1:0] i_id_ex_rs1,
    input  wire [NB_ADDR-1:0] i_id_ex_rs2,
    input  wire [NB_ADDR-1:0] i_ex_mem_rd,
    input  wire               i_ex_mem_reg_write,
    input  wire [NB_ADDR-1:0] i_mem_wb_rd,
    input  wire               i_mem_wb_reg_write,
    output wire [NB_FWD-1:0]  o_fwd_a,
    output wire [NB_FWD-1:0]  o_fwd_b
);

    `include "riscv_defs.vh"

    localparam [NB_ADDR-1:0] REG_X0 = {NB_ADDR{1'b0}};

    // La instrucción en MEM / en WB escribe un registro distinto de x0
    wire ex_mem_writes = i_ex_mem_reg_write & (i_ex_mem_rd != REG_X0);
    wire mem_wb_writes = i_mem_wb_reg_write & (i_mem_wb_rd != REG_X0);

    // Coincidencias con cada registro fuente
    wire ex_mem_rs1 = ex_mem_writes & (i_ex_mem_rd == i_id_ex_rs1);
    wire ex_mem_rs2 = ex_mem_writes & (i_ex_mem_rd == i_id_ex_rs2);
    wire mem_wb_rs1 = mem_wb_writes & (i_mem_wb_rd == i_id_ex_rs1);
    wire mem_wb_rs2 = mem_wb_writes & (i_mem_wb_rd == i_id_ex_rs2);

    // EX/MEM primero: es el valor más reciente
    assign o_fwd_a = ex_mem_rs1 ? FWD_EX_MEM :
                     mem_wb_rs1 ? FWD_WB     :
                                  FWD_ID_EX;
    assign o_fwd_b = ex_mem_rs2 ? FWD_EX_MEM :
                     mem_wb_rs2 ? FWD_WB     :
                                  FWD_ID_EX;

endmodule

`default_nettype wire
