`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// id_stage
//
// Etapa ID completa: banco de registros, unidad de control, generador de
// inmediatos y registro ID/EX (docs/spec/pipeline.md §4).
//
// Función:
//   Conecta regfile, control_unit, imm_gen e id_ex_reg como fija
//   pipeline.md §4, con el mismo criterio que if_stage (decisión 023):
//     - Los campos de if_id_instr se separan con cables, sin decodificar
//       (§4.1): rs1, rs2, rd y funct3 van a ID/EX aunque la instrucción
//       no los use; el control anula su efecto.
//     - regfile lee rs1 y rs2 con bypass WB -> ID (decisión 007). Su
//       escritura la maneja WB y solo ocurre con enable = 1 (decisión 018).
//     - control_unit decodifica con if_id_valid: una burbuja sale con
//       todo el control en 0 (§4.4). Su imm_sel elige el formato de
//       imm_gen (§4.3).
//     - id_ex_reg guarda los 161 bits de §8 con rst > en > flush (§2).
//   La etapa no calcula enables ni flush: los recibe de quien los genere
//   (riscv_core hasta I-42, después la unidad de riesgos, §10.4):
//     en_id_ex    = enable
//     flush_id_ex = redirect | stall
//   El banco recibe además enable, porque su escritura respeta el enable
//   global y no el del latch (§10.4). El puerto de lectura de la Debug
//   Unit pasa sin tocar (protocolo_debug.md §7).
//
// Parámetros:
//   NB_PC       : ancho del PC
//   NB_INSTR    : ancho de la instrucción
//   NB_DATA     : ancho de los datos (registros e inmediato)
//   NB_ADDR     : ancho del número de registro
//   NB_FUNCT3   : ancho de funct3
//   NB_IMM_SEL  : ancho de imm_sel (códigos IMM_* de riscv_defs.vh)
//   NB_ALU_CTRL : ancho de alu_ctrl (códigos ALU_* de riscv_defs.vh)
//
// Puertos:
//   i_clk            : reloj del sistema
//   i_rst            : reset síncrono, activo en alto (core_rst); banco en
//                      0 e ID/EX en burbuja, gana sobre los enables
//   i_enable         : enable global del core; habilita la escritura del
//                      banco (decisión 018)
//   i_en_id_ex       : en 0 ID/EX no cambia
//   i_flush          : flush_id_ex; ID/EX carga burbuja
//   i_if_id_valid    : if_id_valid, 1 = instrucción, 0 = burbuja
//   i_if_id_pc       : if_id_pc                              [NB_PC-1:0]
//   i_if_id_instr    : if_id_instr                           [NB_INSTR-1:0]
//   i_wb_reg_write   : WB escribe rd
//   i_wb_rd          : registro destino de WB                [NB_ADDR-1:0]
//   i_wb_data        : valor que escribe WB                  [NB_DATA-1:0]
//   i_dbg_reg_addr   : registro que lee la Debug Unit        [NB_ADDR-1:0]
//   o_dbg_reg_data   : valor guardado, sin bypass            [NB_DATA-1:0]
//   o_id_is_halt     : HALT válido en ID (id_is_halt de §3.4, para
//                      stop_fetch)
//   o_id_ex_valid ... o_id_ex_halt : id_ex_<campo> de §8, un puerto por
//                      campo
//   o_id_ex_latch    : ID/EX agrupado para la Debug Unit, en el orden de
//                      §8, valid en el bit más alto (decisión 023)
//                      [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0]
//
// Latencia: 1 ciclo (IF/ID -> ID/EX). La escritura de WB se ve en el
//           mismo ciclo en rs1/rs2 (bypass) y desde el ciclo siguiente en
//           o_dbg_reg_data.
// Reset   : banco en 0; o_id_ex_valid = 0 y control de ID/EX en 0; los
//           campos de datos de ID/EX no se resetean.
//======================================================================

module id_stage
#(
    parameter integer NB_PC       = 32,
    parameter integer NB_INSTR    = 32,
    parameter integer NB_DATA     = 32,
    parameter integer NB_ADDR     = 5,
    parameter integer NB_FUNCT3   = 3,
    parameter integer NB_IMM_SEL  = 3,
    parameter integer NB_ALU_CTRL = 4
)
(
    input  wire                   i_clk,
    input  wire                   i_rst,
    input  wire                   i_enable,
    input  wire                   i_en_id_ex,
    input  wire                   i_flush,
    // IF/ID
    input  wire                   i_if_id_valid,
    input  wire [NB_PC-1:0]       i_if_id_pc,
    input  wire [NB_INSTR-1:0]    i_if_id_instr,
    // Escritura del banco (WB)
    input  wire                   i_wb_reg_write,
    input  wire [NB_ADDR-1:0]     i_wb_rd,
    input  wire [NB_DATA-1:0]     i_wb_data,
    // Debug Unit
    input  wire [NB_ADDR-1:0]     i_dbg_reg_addr,
    output wire [NB_DATA-1:0]     o_dbg_reg_data,
    // Parada por HALT
    output wire                   o_id_is_halt,
    // ID/EX: id_ex_<campo>
    output wire                   o_id_ex_valid,
    output wire [NB_PC-1:0]       o_id_ex_pc,
    output wire [NB_DATA-1:0]     o_id_ex_rs1_data,
    output wire [NB_DATA-1:0]     o_id_ex_rs2_data,
    output wire [NB_DATA-1:0]     o_id_ex_imm,
    output wire [NB_ADDR-1:0]     o_id_ex_rs1,
    output wire [NB_ADDR-1:0]     o_id_ex_rs2,
    output wire [NB_ADDR-1:0]     o_id_ex_rd,
    output wire [NB_FUNCT3-1:0]   o_id_ex_funct3,
    output wire [NB_ALU_CTRL-1:0] o_id_ex_alu_ctrl,
    output wire                   o_id_ex_alu_src_a,
    output wire                   o_id_ex_alu_src_b,
    output wire                   o_id_ex_branch,
    output wire                   o_id_ex_jal,
    output wire                   o_id_ex_jalr,
    output wire                   o_id_ex_mem_read,
    output wire                   o_id_ex_mem_write,
    output wire                   o_id_ex_reg_write,
    output wire                   o_id_ex_mem_to_reg,
    output wire                   o_id_ex_halt,
    output wire [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0] o_id_ex_latch
);

    //------------------------------------------------------------------
    // Campos de la instrucción (§4.1): siempre en los mismos bits
    //------------------------------------------------------------------
    wire [NB_ADDR-1:0]   id_rs1    = i_if_id_instr[19:15];
    wire [NB_ADDR-1:0]   id_rs2    = i_if_id_instr[24:20];
    wire [NB_ADDR-1:0]   id_rd     = i_if_id_instr[11:7];
    wire [NB_FUNCT3-1:0] id_funct3 = i_if_id_instr[14:12];

    //------------------------------------------------------------------
    // Banco de registros (§4.2)
    //------------------------------------------------------------------
    wire [NB_DATA-1:0] id_rs1_data;
    wire [NB_DATA-1:0] id_rs2_data;

    regfile #(
        .NB_DATA (NB_DATA),
        .NB_ADDR (NB_ADDR)
    ) u_regfile (
        .i_clk          (i_clk),
        .i_rst          (i_rst),
        .i_en           (i_enable),
        .i_rs1_addr     (id_rs1),
        .i_rs2_addr     (id_rs2),
        .o_rs1_data     (id_rs1_data),
        .o_rs2_data     (id_rs2_data),
        .i_we           (i_wb_reg_write),
        .i_rd_addr      (i_wb_rd),
        .i_rd_data      (i_wb_data),
        .i_dbg_reg_addr (i_dbg_reg_addr),
        .o_dbg_reg_data (o_dbg_reg_data)
    );

    //------------------------------------------------------------------
    // Unidad de control (§4.4, §4.5) y generador de inmediatos (§4.3)
    //------------------------------------------------------------------
    wire [NB_IMM_SEL-1:0]  id_imm_sel;
    wire [NB_ALU_CTRL-1:0] id_alu_ctrl;
    wire                   id_alu_src_a;
    wire                   id_alu_src_b;
    wire                   id_branch;
    wire                   id_jal;
    wire                   id_jalr;
    wire                   id_mem_read;
    wire                   id_mem_write;
    wire                   id_reg_write;
    wire                   id_mem_to_reg;
    wire                   id_halt;
    wire [NB_DATA-1:0]     id_imm;

    control_unit #(
        .NB_INSTR    (NB_INSTR),
        .NB_IMM_SEL  (NB_IMM_SEL),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_control_unit (
        .i_valid      (i_if_id_valid),
        .i_instr      (i_if_id_instr),
        .o_imm_sel    (id_imm_sel),
        .o_alu_ctrl   (id_alu_ctrl),
        .o_alu_src_a  (id_alu_src_a),
        .o_alu_src_b  (id_alu_src_b),
        .o_branch     (id_branch),
        .o_jal        (id_jal),
        .o_jalr       (id_jalr),
        .o_mem_read   (id_mem_read),
        .o_mem_write  (id_mem_write),
        .o_reg_write  (id_reg_write),
        .o_mem_to_reg (id_mem_to_reg),
        .o_halt       (id_halt)
    );

    imm_gen #(
        .NB_INSTR   (NB_INSTR),
        .NB_IMM     (NB_DATA),
        .NB_IMM_SEL (NB_IMM_SEL)
    ) u_imm_gen (
        .i_instr   (i_if_id_instr),
        .i_imm_sel (id_imm_sel),
        .o_imm     (id_imm)
    );

    //------------------------------------------------------------------
    // Registro ID/EX (§8)
    //------------------------------------------------------------------
    id_ex_reg #(
        .NB_PC       (NB_PC),
        .NB_DATA     (NB_DATA),
        .NB_ADDR     (NB_ADDR),
        .NB_FUNCT3   (NB_FUNCT3),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_id_ex_reg (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_en         (i_en_id_ex),
        .i_flush      (i_flush),
        .i_valid      (i_if_id_valid),
        .i_pc         (i_if_id_pc),
        .i_rs1_data   (id_rs1_data),
        .i_rs2_data   (id_rs2_data),
        .i_imm        (id_imm),
        .i_rs1        (id_rs1),
        .i_rs2        (id_rs2),
        .i_rd         (id_rd),
        .i_funct3     (id_funct3),
        .i_alu_ctrl   (id_alu_ctrl),
        .i_alu_src_a  (id_alu_src_a),
        .i_alu_src_b  (id_alu_src_b),
        .i_branch     (id_branch),
        .i_jal        (id_jal),
        .i_jalr       (id_jalr),
        .i_mem_read   (id_mem_read),
        .i_mem_write  (id_mem_write),
        .i_reg_write  (id_reg_write),
        .i_mem_to_reg (id_mem_to_reg),
        .i_halt       (id_halt),
        .o_valid      (o_id_ex_valid),
        .o_pc         (o_id_ex_pc),
        .o_rs1_data   (o_id_ex_rs1_data),
        .o_rs2_data   (o_id_ex_rs2_data),
        .o_imm        (o_id_ex_imm),
        .o_rs1        (o_id_ex_rs1),
        .o_rs2        (o_id_ex_rs2),
        .o_rd         (o_id_ex_rd),
        .o_funct3     (o_id_ex_funct3),
        .o_alu_ctrl   (o_id_ex_alu_ctrl),
        .o_alu_src_a  (o_id_ex_alu_src_a),
        .o_alu_src_b  (o_id_ex_alu_src_b),
        .o_branch     (o_id_ex_branch),
        .o_jal        (o_id_ex_jal),
        .o_jalr       (o_id_ex_jalr),
        .o_mem_read   (o_id_ex_mem_read),
        .o_mem_write  (o_id_ex_mem_write),
        .o_reg_write  (o_id_ex_reg_write),
        .o_mem_to_reg (o_id_ex_mem_to_reg),
        .o_halt       (o_id_ex_halt),
        .o_latch      (o_id_ex_latch)
    );

    // control_unit ya anula el halt con valid = 0 (§4.4)
    assign o_id_is_halt = id_halt;

endmodule

`default_nettype wire
