`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// imm_gen
//
// Generador de inmediatos de la etapa ID (docs/spec/pipeline.md §4.3).
//
// Función:
//   Reconstruye el inmediato del formato que indica i_imm_sel y lo
//   extiende con signo a 32 bits usando instr[31] (isa.md, figura de
//   formatos):
//     IMM_I : {{20{i[31]}}, i[31:20]}
//     IMM_S : {{20{i[31]}}, i[31:25], i[11:7]}
//     IMM_B : {{19{i[31]}}, i[31], i[7], i[30:25], i[11:8], 1'b0}
//     IMM_U : {i[31:12], 12'b0}
//     IMM_J : {{11{i[31]}}, i[31], i[19:12], i[20], i[30:21], 1'b0}
//   Un código de i_imm_sel sin formato da 0. La codificación de IMM_*
//   está en riscv_defs.vh (la fija la unidad de control, pipeline.md §4.4).
//
// Parámetros:
//   NB_INSTR   : ancho de la instrucción
//   NB_IMM     : ancho del inmediato extendido
//   NB_IMM_SEL : ancho de imm_sel (pipeline.md §4.4)
//
// Puertos:
//   i_instr   : instrucción en ID (if_id_instr)            [NB_INSTR-1:0]
//   i_imm_sel : formato del inmediato, de la unidad de control [NB_IMM_SEL-1:0]
//   o_imm     : inmediato extendido con signo (a id_ex_imm) [NB_IMM-1:0]
//
// Latencia: 0 ciclos (combinacional).
// Reset   : no tiene.
//======================================================================

module imm_gen
#(
    parameter integer NB_INSTR   = 32,
    parameter integer NB_IMM     = 32,
    parameter integer NB_IMM_SEL = 3
)
(
    input  wire [NB_INSTR-1:0]   i_instr,
    input  wire [NB_IMM_SEL-1:0] i_imm_sel,
    output wire [NB_IMM-1:0]     o_imm
);

    `include "riscv_defs.vh"

    // Un cable por formato: los bits salen siempre del mismo lugar, sin
    // depender de la instrucción (pipeline.md §4.1)
    wire [NB_IMM-1:0] imm_i = {{20{i_instr[31]}}, i_instr[31:20]};
    wire [NB_IMM-1:0] imm_s = {{20{i_instr[31]}}, i_instr[31:25], i_instr[11:7]};
    wire [NB_IMM-1:0] imm_b = {{19{i_instr[31]}}, i_instr[31], i_instr[7],
                               i_instr[30:25], i_instr[11:8], 1'b0};
    wire [NB_IMM-1:0] imm_u = {i_instr[31:12], 12'b0};
    wire [NB_IMM-1:0] imm_j = {{11{i_instr[31]}}, i_instr[31], i_instr[19:12],
                               i_instr[20], i_instr[30:21], 1'b0};

    reg [NB_IMM-1:0] imm;

    // Mux de formato; el default cubre los códigos sin uso y evita latches
    always @(*) begin
        case (i_imm_sel)
            IMM_I:   imm = imm_i;
            IMM_S:   imm = imm_s;
            IMM_B:   imm = imm_b;
            IMM_U:   imm = imm_u;
            IMM_J:   imm = imm_j;
            default: imm = {NB_IMM{1'b0}};
        endcase
    end

    assign o_imm = imm;

endmodule

`default_nettype wire
