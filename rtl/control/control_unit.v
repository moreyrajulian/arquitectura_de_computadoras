`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// control_unit
//
// Unidad de control principal de la etapa ID (docs/spec/pipeline.md
// §4.4 y §4.5).
//
// Función:
//   Decodifica if_id_instr en las señales de control de la tabla de
//   verdad de §4.4. Decodifica solo por opcode; el HALT se compara
//   contra la palabra completa (decisión 001). La operación de la ALU
//   se decide completa acá (§4.5):
//     R-type       : alu_ctrl = {instr[30], funct3}
//     I aritmética : alu_ctrl = {instr[30] solo si funct3 = 101, funct3}
//     load, store, jalr, lui: ADD;  branch: SUB
//   Las "x" de la tabla valen 0. Todas las salidas valen 0 (NOP, sin
//   efectos) con:
//     - i_valid = 0: burbuja o basura de la BRAM después del reset
//       (decisión 009); por eso o_halt solo se activa con valid = 1
//     - opcode que no está en la tabla, o SYSTEM distinto del HALT
//       (0x0000_0000, ecall, auipc, ...)
//   Con opcode conocido y funct3/funct7 fuera de isa.md la palabra no
//   se anula: recibe la fila de su opcode (decisión 024).
//
// Parámetros:
//   NB_INSTR    : ancho de la instrucción
//   NB_IMM_SEL  : ancho de imm_sel (códigos IMM_* de riscv_defs.vh)
//   NB_ALU_CTRL : ancho de alu_ctrl (códigos ALU_* de riscv_defs.vh)
//
// Puertos:
//   i_valid      : if_id_valid; en 0 todas las salidas valen 0
//   i_instr      : if_id_instr                            [NB_INSTR-1:0]
//   o_imm_sel    : formato del inmediato, hacia imm_gen   [NB_IMM_SEL-1:0]
//   o_alu_ctrl   : operación de la ALU                    [NB_ALU_CTRL-1:0]
//   o_alu_src_a  : operando A: 0 = rs1, 1 = cero (lui)
//   o_alu_src_b  : operando B: 0 = rs2, 1 = inmediato
//   o_branch     : beq/bne (el tipo lo da funct3)
//   o_jal        : jal
//   o_jalr       : jalr
//   o_mem_read   : load (lo usa la detección de load-use, §10.3)
//   o_mem_write  : store
//   o_reg_write  : escribe rd
//   o_mem_to_reg : rd recibe el dato de memoria (0 = resultado de EX)
//   o_halt       : HALT en ID (id_is_halt de pipeline.md §3.4)
//
// Latencia: combinacional.
// Reset   : no tiene estado.
//======================================================================

module control_unit
#(
    parameter integer NB_INSTR    = 32,
    parameter integer NB_IMM_SEL  = 3,
    parameter integer NB_ALU_CTRL = 4
)
(
    input  wire                   i_valid,
    input  wire [NB_INSTR-1:0]    i_instr,
    output reg  [NB_IMM_SEL-1:0]  o_imm_sel,
    output reg  [NB_ALU_CTRL-1:0] o_alu_ctrl,
    output reg                    o_alu_src_a,
    output reg                    o_alu_src_b,
    output reg                    o_branch,
    output reg                    o_jal,
    output reg                    o_jalr,
    output reg                    o_mem_read,
    output reg                    o_mem_write,
    output reg                    o_reg_write,
    output reg                    o_mem_to_reg,
    output reg                    o_halt
);

    `include "riscv_defs.vh"

    // Campos de la instrucción (pipeline.md §4.1)
    wire [6:0] opcode  = i_instr[6:0];
    wire [2:0] funct3  = i_instr[14:12];
    wire       instr30 = i_instr[30];

    always @(*) begin
        // Por defecto todo en 0: burbuja, no reconocida y las "x" de §4.4
        o_imm_sel    = IMM_I;
        o_alu_ctrl   = ALU_ADD;
        o_alu_src_a  = 1'b0;
        o_alu_src_b  = 1'b0;
        o_branch     = 1'b0;
        o_jal        = 1'b0;
        o_jalr       = 1'b0;
        o_mem_read   = 1'b0;
        o_mem_write  = 1'b0;
        o_reg_write  = 1'b0;
        o_mem_to_reg = 1'b0;
        o_halt       = 1'b0;

        if (i_valid) begin
            if (i_instr == INSTR_HALT) begin
                o_halt = 1'b1;
            end
            else begin
                case (opcode)
                    OPCODE_OP: begin
                        o_alu_ctrl  = {instr30, funct3};
                        o_reg_write = 1'b1;
                    end
                    OPCODE_OP_IMM: begin
                        // instr[30] es un bit del inmediato salvo en srli/srai:
                        // tomarlo siempre haría de un addi negativo una resta
                        o_imm_sel   = IMM_I;
                        o_alu_ctrl  = {(funct3 == FUNCT3_SRL_SRA) & instr30, funct3};
                        o_alu_src_b = 1'b1;
                        o_reg_write = 1'b1;
                    end
                    OPCODE_LOAD: begin
                        o_imm_sel    = IMM_I;
                        o_alu_ctrl   = ALU_ADD;
                        o_alu_src_b  = 1'b1;
                        o_mem_read   = 1'b1;
                        o_reg_write  = 1'b1;
                        o_mem_to_reg = 1'b1;
                    end
                    OPCODE_STORE: begin
                        o_imm_sel   = IMM_S;
                        o_alu_ctrl  = ALU_ADD;
                        o_alu_src_b = 1'b1;
                        o_mem_write = 1'b1;
                    end
                    OPCODE_BRANCH: begin
                        o_imm_sel  = IMM_B;
                        o_alu_ctrl = ALU_SUB;
                        o_branch   = 1'b1;
                    end
                    OPCODE_JAL: begin
                        // escribe PC + 4, que sale de EX como resultado
                        o_imm_sel   = IMM_J;
                        o_jal       = 1'b1;
                        o_reg_write = 1'b1;
                    end
                    OPCODE_JALR: begin
                        o_imm_sel   = IMM_I;
                        o_alu_ctrl  = ALU_ADD;
                        o_alu_src_b = 1'b1;
                        o_jalr      = 1'b1;
                        o_reg_write = 1'b1;
                    end
                    OPCODE_LUI: begin
                        // 0 + inmediato
                        o_imm_sel   = IMM_U;
                        o_alu_ctrl  = ALU_ADD;
                        o_alu_src_a = 1'b1;
                        o_alu_src_b = 1'b1;
                        o_reg_write = 1'b1;
                    end
                    default: begin
                        // no reconocida (incluye SYSTEM distinto del HALT): NOP
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
