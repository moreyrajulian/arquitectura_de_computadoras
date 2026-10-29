`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// ex_stage
//
// Etapa EX completa: muxes de forwarding y de operandos, ALU, resolución
// de saltos, mux de resultado y registro EX/MEM (docs/spec/pipeline.md
// §5).
//
// Función:
//   Conecta alu, branch_unit y ex_mem_reg como fija pipeline.md §5, con
//   el mismo criterio que if_stage e id_stage (decisión 023):
//     - Forwarding (§5.1): rs1_val y rs2_val salen de un mux de tres
//       entradas elegido por fwd_a / fwd_b (códigos FWD_* de
//       riscv_defs.vh): lo leído en ID, ex_mem_result (la salida del
//       propio EX/MEM) o wb_data. El código 11 no existe en §5.1 y toma
//       lo leído en ID.
//     - Operandos (§5.1): alu_a = alu_src_a ? 0 : rs1_val
//                         alu_b = alu_src_b ? imm : rs2_val
//     - alu opera con alu_ctrl (§5.2); branch_unit decide redirect y
//       redirect_pc con zero y alu_out (§5.3).
//     - Resultado (§5.4): result = (jal | jalr) ? pc + 4 : alu_out
//     - ex_mem_reg guarda los 109 bits de §8 con rst > en > flush (§2);
//       store_data es rs2_val, ya con forwarding.
//   La etapa no calcula enables, flush ni forwarding: los recibe de quien
//   los genere (riscv_core; la unidad de forwarding llega en I-39):
//     en_ex_mem    = enable
//     flush_ex_mem = 0
//   rs1, rs2 y mem_read de ID/EX no entran: los usan la unidad de
//   forwarding (§10.2) y la detección de load-use (§10.3), no EX.
//   redirect y redirect_pc salen hacia IF (riscv_core los conecta desde
//   I-36).
//
// Parámetros:
//   NB_PC       : ancho del PC
//   NB_DATA     : ancho de los datos (operandos, inmediato, resultado)
//   NB_ADDR     : ancho del número de registro
//   NB_FUNCT3   : ancho de funct3
//   NB_ALU_CTRL : ancho de alu_ctrl (códigos ALU_* de riscv_defs.vh)
//   NB_FWD      : ancho de fwd_a / fwd_b (códigos FWD_* de riscv_defs.vh)
//
// Puertos:
//   i_clk            : reloj del sistema
//   i_rst            : reset síncrono, activo en alto (core_rst); EX/MEM
//                      en burbuja, gana sobre i_en_ex_mem
//   i_en_ex_mem      : en 0 EX/MEM no cambia
//   i_flush          : flush_ex_mem; EX/MEM carga burbuja
//   i_fwd_a          : selector del mux de rs1 (§5.1)    [NB_FWD-1:0]
//   i_fwd_b          : selector del mux de rs2 (§5.1)    [NB_FWD-1:0]
//   i_wb_data        : valor final de WB (§7.2)          [NB_DATA-1:0]
//   i_id_ex_valid ... i_id_ex_halt : id_ex_<campo> de §8 que usa EX o
//                      que pasan a EX/MEM
//   o_redirect       : hay que cambiar el flujo (a IF, §3.1)
//   o_redirect_pc    : destino del salto (a IF, §3.1)    [NB_PC-1:0]
//   o_ex_mem_valid ... o_ex_mem_halt : ex_mem_<campo> de §8, un puerto
//                      por campo
//   o_ex_mem_latch   : EX/MEM agrupado para la Debug Unit, en el orden de
//                      §8, valid en el bit más alto (decisión 023)
//                      [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+4:0]
//
// Latencia: 1 ciclo (ID/EX -> EX/MEM). o_redirect y o_redirect_pc son
//           combinacionales desde ID/EX, EX/MEM (fwd = 10) y wb_data.
// Reset   : o_ex_mem_valid = 0 y control de EX/MEM en 0; los campos de
//           datos de EX/MEM no se resetean.
//======================================================================

module ex_stage
#(
    parameter integer NB_PC       = 32,
    parameter integer NB_DATA     = 32,
    parameter integer NB_ADDR     = 5,
    parameter integer NB_FUNCT3   = 3,
    parameter integer NB_ALU_CTRL = 4,
    parameter integer NB_FWD      = 2
)
(
    input  wire                   i_clk,
    input  wire                   i_rst,
    input  wire                   i_en_ex_mem,
    input  wire                   i_flush,
    // Forwarding
    input  wire [NB_FWD-1:0]      i_fwd_a,
    input  wire [NB_FWD-1:0]      i_fwd_b,
    input  wire [NB_DATA-1:0]     i_wb_data,
    // ID/EX
    input  wire                   i_id_ex_valid,
    input  wire [NB_PC-1:0]       i_id_ex_pc,
    input  wire [NB_DATA-1:0]     i_id_ex_rs1_data,
    input  wire [NB_DATA-1:0]     i_id_ex_rs2_data,
    input  wire [NB_DATA-1:0]     i_id_ex_imm,
    input  wire [NB_ADDR-1:0]     i_id_ex_rd,
    input  wire [NB_FUNCT3-1:0]   i_id_ex_funct3,
    input  wire [NB_ALU_CTRL-1:0] i_id_ex_alu_ctrl,
    input  wire                   i_id_ex_alu_src_a,
    input  wire                   i_id_ex_alu_src_b,
    input  wire                   i_id_ex_branch,
    input  wire                   i_id_ex_jal,
    input  wire                   i_id_ex_jalr,
    input  wire                   i_id_ex_mem_write,
    input  wire                   i_id_ex_reg_write,
    input  wire                   i_id_ex_mem_to_reg,
    input  wire                   i_id_ex_halt,
    // Salto (a IF)
    output wire                   o_redirect,
    output wire [NB_PC-1:0]       o_redirect_pc,
    // EX/MEM: ex_mem_<campo>
    output wire                   o_ex_mem_valid,
    output wire [NB_PC-1:0]       o_ex_mem_pc,
    output wire [NB_DATA-1:0]     o_ex_mem_result,
    output wire [NB_DATA-1:0]     o_ex_mem_store_data,
    output wire [NB_ADDR-1:0]     o_ex_mem_rd,
    output wire [NB_FUNCT3-1:0]   o_ex_mem_funct3,
    output wire                   o_ex_mem_mem_write,
    output wire                   o_ex_mem_reg_write,
    output wire                   o_ex_mem_mem_to_reg,
    output wire                   o_ex_mem_halt,
    // 1 + 32 + 2*32 + 5 + 3 + 4 = 109 bits (§8)
    output wire [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+4:0] o_ex_mem_latch
);

    `include "riscv_defs.vh"

    //------------------------------------------------------------------
    // Forwarding (§5.1): la entrada 10 es la salida de EX/MEM
    //------------------------------------------------------------------
    reg [NB_DATA-1:0] ex_rs1_val;
    reg [NB_DATA-1:0] ex_rs2_val;

    always @(*) begin
        case (i_fwd_a)
            FWD_EX_MEM: ex_rs1_val = o_ex_mem_result;
            FWD_WB:     ex_rs1_val = i_wb_data;
            default:    ex_rs1_val = i_id_ex_rs1_data;     // FWD_ID_EX
        endcase
    end

    always @(*) begin
        case (i_fwd_b)
            FWD_EX_MEM: ex_rs2_val = o_ex_mem_result;
            FWD_WB:     ex_rs2_val = i_wb_data;
            default:    ex_rs2_val = i_id_ex_rs2_data;     // FWD_ID_EX
        endcase
    end

    //------------------------------------------------------------------
    // Operandos (§5.1) y ALU (§5.2)
    //------------------------------------------------------------------
    wire [NB_DATA-1:0] ex_alu_a = i_id_ex_alu_src_a ? {NB_DATA{1'b0}} : ex_rs1_val;
    wire [NB_DATA-1:0] ex_alu_b = i_id_ex_alu_src_b ? i_id_ex_imm     : ex_rs2_val;
    wire [NB_DATA-1:0] ex_alu_out;
    wire               ex_zero;

    alu #(
        .NB_DATA     (NB_DATA),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_alu (
        .i_a        (ex_alu_a),
        .i_b        (ex_alu_b),
        .i_alu_ctrl (i_id_ex_alu_ctrl),
        .o_result   (ex_alu_out),
        .o_zero     (ex_zero)
    );

    //------------------------------------------------------------------
    // Resolución de saltos (§5.3)
    //------------------------------------------------------------------
    branch_unit #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_branch_unit (
        .i_branch      (i_id_ex_branch),
        .i_jal         (i_id_ex_jal),
        .i_jalr        (i_id_ex_jalr),
        .i_funct3      (i_id_ex_funct3),
        .i_pc          (i_id_ex_pc),
        .i_imm         (i_id_ex_imm),
        .i_zero        (ex_zero),
        .i_alu_out     (ex_alu_out),
        .o_redirect    (o_redirect),
        .o_redirect_pc (o_redirect_pc)
    );

    //------------------------------------------------------------------
    // Resultado (§5.4): dirección de retorno en jal y jalr
    //------------------------------------------------------------------
    wire [NB_DATA-1:0] ex_result = (i_id_ex_jal | i_id_ex_jalr)
                                   ? i_id_ex_pc + 4 : ex_alu_out;

    //------------------------------------------------------------------
    // Registro EX/MEM (§8)
    //------------------------------------------------------------------
    ex_mem_reg #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_ex_mem_reg (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_en         (i_en_ex_mem),
        .i_flush      (i_flush),
        .i_valid      (i_id_ex_valid),
        .i_pc         (i_id_ex_pc),
        .i_result     (ex_result),
        .i_store_data (ex_rs2_val),
        .i_rd         (i_id_ex_rd),
        .i_funct3     (i_id_ex_funct3),
        .i_mem_write  (i_id_ex_mem_write),
        .i_reg_write  (i_id_ex_reg_write),
        .i_mem_to_reg (i_id_ex_mem_to_reg),
        .i_halt       (i_id_ex_halt),
        .o_valid      (o_ex_mem_valid),
        .o_pc         (o_ex_mem_pc),
        .o_result     (o_ex_mem_result),
        .o_store_data (o_ex_mem_store_data),
        .o_rd         (o_ex_mem_rd),
        .o_funct3     (o_ex_mem_funct3),
        .o_mem_write  (o_ex_mem_mem_write),
        .o_reg_write  (o_ex_mem_reg_write),
        .o_mem_to_reg (o_ex_mem_mem_to_reg),
        .o_halt       (o_ex_mem_halt),
        .o_latch      (o_ex_mem_latch)
    );

endmodule

`default_nettype wire
