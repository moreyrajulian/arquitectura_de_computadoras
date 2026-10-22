`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// alu
//
// ALU de 32 bits de la etapa EX (docs/spec/pipeline.md §5.2).
//
// Función:
//   Opera i_a e i_b con la operación de i_alu_ctrl, una de las 10 de
//   §4.5 (códigos ALU_* de riscv_defs.vh):
//     ADD, SUB      : suma y resta módulo 2^32, sin acarreo ni desborde
//     SLT, SLTU     : 1 si i_a < i_b, con signo y sin signo; si no, 0
//     XOR, OR, AND  : bit a bit
//     SLL, SRL, SRA : desplazan i_a según i_b[4:0]; SRA replica el signo
//   o_zero vale 1 si o_result es 0 (beq y bne comparan con SUB, §5.3).
//   Un código de i_alu_ctrl que no está en §4.5 da 0: su resultado no
//   está especificado (decisión 024).
//   Los puertos no tienen signo: solo SLT y SRA lo miran, con $signed
//   dentro de la operación, para que no se cuele en las demás.
//
// Parámetros:
//   NB_DATA     : ancho de los operandos y del resultado
//   NB_ALU_CTRL : ancho de alu_ctrl (pipeline.md §4.4)
//
// Puertos:
//   i_a        : operando A (alu_a: rs1_val, o 0 en lui)    [NB_DATA-1:0]
//   i_b        : operando B (alu_b: rs2_val o inmediato)    [NB_DATA-1:0]
//   i_alu_ctrl : operación, de la unidad de control         [NB_ALU_CTRL-1:0]
//   o_result   : resultado (alu_out)                        [NB_DATA-1:0]
//   o_zero     : 1 si o_result es 0
//
// Latencia: 0 ciclos (combinacional).
// Reset   : no tiene.
//======================================================================

module alu
#(
    parameter integer NB_DATA     = 32,
    parameter integer NB_ALU_CTRL = 4
)
(
    input  wire [NB_DATA-1:0]     i_a,
    input  wire [NB_DATA-1:0]     i_b,
    input  wire [NB_ALU_CTRL-1:0] i_alu_ctrl,
    output wire [NB_DATA-1:0]     o_result,
    output wire                   o_zero
);

    `include "riscv_defs.vh"

    // Los desplazamientos usan solo los bits bajos de i_b: [4:0] con 32 bits
    localparam integer NB_SHAMT = $clog2(NB_DATA);

    wire [NB_SHAMT-1:0] shamt = i_b[NB_SHAMT-1:0];

    reg [NB_DATA-1:0] result;

    // El default cubre los códigos sin operación y evita latches
    always @(*) begin
        case (i_alu_ctrl)
            ALU_ADD:  result = i_a + i_b;
            ALU_SUB:  result = i_a - i_b;
            ALU_SLL:  result = i_a << shamt;
            ALU_SLT:  result = {{(NB_DATA-1){1'b0}}, $signed(i_a) < $signed(i_b)};
            ALU_SLTU: result = {{(NB_DATA-1){1'b0}}, i_a < i_b};
            ALU_XOR:  result = i_a ^ i_b;
            ALU_SRL:  result = i_a >> shamt;
            ALU_SRA:  result = $signed(i_a) >>> shamt;
            ALU_OR:   result = i_a | i_b;
            ALU_AND:  result = i_a & i_b;
            default:  result = {NB_DATA{1'b0}};
        endcase
    end

    assign o_result = result;
    assign o_zero   = (result == {NB_DATA{1'b0}});

endmodule

`default_nettype wire
