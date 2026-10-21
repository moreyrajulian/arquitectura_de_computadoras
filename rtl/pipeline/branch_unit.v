`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// branch_unit
//
// Resolución de saltos de la etapa EX (docs/spec/pipeline.md §5.3,
// decisión 012).
//
// Función:
//   Decide si hay que cambiar el flujo y a dónde, con las ecuaciones de
//   §5.3:
//     taken       = branch & (zero ^ funct3[0])   beq: salta si zero = 1
//                                                 bne: salta si zero = 0
//     redirect    = taken | jal | jalr
//     redirect_pc = jalr ? {alu_out[31:1], 1'b0}  (rs1 + imm, bit 0 en 0)
//                        : pc + imm               (branch y jal)
//   La ALU compara con una resta (zero) o calcula rs1 + imm para jalr;
//   el sumador pc + imm es propio, así la ALU queda libre.
//   No mira valid: una burbuja trae branch, jal y jalr en 0 (§2).
//   La dirección de retorno (pc + 4) es el mux de resultado de §5.4 y
//   no sale de acá. redirect y redirect_pc llegan a IF en I-36.
//
// Parámetros:
//   NB_PC     : ancho del PC y de las direcciones
//   NB_DATA   : ancho de los datos (imm, alu_out)
//   NB_FUNCT3 : ancho de funct3
//
// Puertos:
//   i_branch      : id_ex_branch (beq/bne)
//   i_jal         : id_ex_jal
//   i_jalr        : id_ex_jalr
//   i_funct3      : id_ex_funct3; solo se usa el bit 0    [NB_FUNCT3-1:0]
//   i_pc          : id_ex_pc                              [NB_PC-1:0]
//   i_imm         : id_ex_imm                             [NB_DATA-1:0]
//   i_zero        : 1 si alu_out == 0 (ALU, §5.2)
//   i_alu_out     : resultado de la ALU; rs1 + imm en jalr [NB_DATA-1:0]
//   o_redirect    : hay que cambiar el flujo (a IF, §3.1)
//   o_redirect_pc : destino ya calculado (a IF, §3.1)     [NB_PC-1:0]
//
// Latencia: 0 ciclos (combinacional).
// Reset   : no tiene.
//======================================================================

module branch_unit
#(
    parameter integer NB_PC     = 32,
    parameter integer NB_DATA   = 32,
    parameter integer NB_FUNCT3 = 3
)
(
    input  wire                 i_branch,
    input  wire                 i_jal,
    input  wire                 i_jalr,
    input  wire [NB_FUNCT3-1:0] i_funct3,
    input  wire [NB_PC-1:0]     i_pc,
    input  wire [NB_DATA-1:0]   i_imm,
    input  wire                 i_zero,
    input  wire [NB_DATA-1:0]   i_alu_out,
    output wire                 o_redirect,
    output wire [NB_PC-1:0]     o_redirect_pc
);

    wire             taken;
    wire [NB_PC-1:0] pc_imm;

    // funct3[0] distingue beq (0) de bne (1)
    assign taken  = i_branch & (i_zero ^ i_funct3[0]);
    assign pc_imm = i_pc + i_imm;

    assign o_redirect    = taken | i_jal | i_jalr;
    assign o_redirect_pc = i_jalr ? {i_alu_out[NB_PC-1:1], 1'b0} : pc_imm;

endmodule

`default_nettype wire
