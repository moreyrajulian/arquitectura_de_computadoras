`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// riscv_core
//
// Procesador RV32I segmentado (docs/spec/pipeline.md). Se integra etapa
// por etapa (docs/planificacion.md); esta versión tiene IF (I-22) e ID
// (I-27).
//
// Función:
//   Instancia las etapas y genera las señales de control del pipeline
//   (pipeline.md §9.2, §10.4). Las que todavía no tienen quien las
//   produzca valen 0 y se indica qué issue las conecta:
//     stall       = 0   hasta I-41/I-42 (detección de carga-uso)
//     redirect    = 0   hasta I-36      (el salto vuelve a IF)
//     stop_fetch  = 0   hasta I-37      (parada por HALT)
//     halted      = 0   hasta I-35      (registro halted en WB)
//     wb_*        = 0   hasta I-35      (escritura del banco desde WB)
//   Con eso, en M4: en_pc = en_if_id = en_id_ex = enable,
//   flush_if_id = flush_id_ex = 0, y el banco conserva lo que tenga.
//
//   Los campos de los registros de segmentación son señales de este
//   módulo con el nombre <latch>_<campo> de pipeline.md §8: el banco de
//   pruebas incremental los lee por jerarquía (verificacion.md §8.5).
//   El banco de registros está en u_id_stage.u_regfile.regs.
//
// Interfaz de debug (decisión 023, protocolo_debug.md §7):
//   i_enable                  : enable de la Debug Unit (la issue lo llama
//                               cpu_en, decisión 018). En 0 nada con
//                               estado cambia; i_rst gana sobre él
//   i_imem_b_*                : puerto B de imem para LOAD (memoria.md §4)
//   i_dbg_reg_addr            : registro que lee la Debug Unit
//   o_dbg_reg_data            : su valor guardado, sin bypass (decisión 018)
//   o_halted                  : HALT llegó a WB
//   o_pc                      : pc_reg, para el bloque de estado
//   o_if_id_latch             : IF/ID agrupado, {valid, pc, instr}
//   o_id_ex_latch             : ID/EX agrupado, en el orden de §8
//   Cada integración agrega su bus de latch (o_ex_mem_latch, ...), el
//   puerto B de dmem (I-34) y los avisos (I-35).
//
// Parámetros:
//   NB_PC       : ancho del PC y de las direcciones
//   NB_INSTR    : ancho de la instrucción
//   NB_DATA     : ancho de los datos (registros e inmediato)
//   NB_ADDR     : ancho del número de registro
//   NB_FUNCT3   : ancho de funct3
//   NB_ALU_CTRL : ancho de alu_ctrl (códigos ALU_* de riscv_defs.vh)
//
// Puertos:
//   i_clk          : reloj del sistema (único dominio, decisión 006)
//   i_rst          : core_rst, síncrono, activo en alto
//   i_enable       : enable global del core (decisión 018)
//   i_imem_b_en    : puerto B de imem: habilita
//   i_imem_b_we    : puerto B de imem: escritura
//   i_imem_b_addr  : puerto B de imem: índice de palabra     [9:0]
//   i_imem_b_din   : puerto B de imem: palabra a escribir    [NB_INSTR-1:0]
//   i_dbg_reg_addr : registro que lee la Debug Unit          [NB_ADDR-1:0]
//   o_dbg_reg_data : valor guardado del registro             [NB_DATA-1:0]
//   o_halted       : HALT en WB; 0 hasta I-35
//   o_pc           : pc_reg                                  [NB_PC-1:0]
//   o_if_id_latch  : IF/ID para READ_LATCHES                 [NB_PC+NB_INSTR:0]
//   o_id_ex_latch  : ID/EX para READ_LATCHES (161 bits)
//                    [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0]
//
// Latencia: la instrucción de la dirección p llega a IF/ID un ciclo con
//           enable = 1 después de que pc_reg = p, y a ID/EX un ciclo
//           con enable = 1 después.
// Reset   : PC = 0x0000_0000, banco de registros en 0, todos los
//           registros de segmentación en burbuja (valid = 0), halted = 0.
//======================================================================

module riscv_core
#(
    parameter integer NB_PC       = 32,
    parameter integer NB_INSTR    = 32,
    parameter integer NB_DATA     = 32,
    parameter integer NB_ADDR     = 5,
    parameter integer NB_FUNCT3   = 3,
    parameter integer NB_ALU_CTRL = 4
)
(
    input  wire                    i_clk,
    input  wire                    i_rst,
    input  wire                    i_enable,
    input  wire                    i_imem_b_en,
    input  wire                    i_imem_b_we,
    input  wire [9:0]              i_imem_b_addr,
    input  wire [NB_INSTR-1:0]     i_imem_b_din,
    input  wire [NB_ADDR-1:0]      i_dbg_reg_addr,
    output wire [NB_DATA-1:0]      o_dbg_reg_data,
    output wire                    o_halted,
    output wire [NB_PC-1:0]        o_pc,
    output wire [NB_PC+NB_INSTR:0] o_if_id_latch,
    // 1 + 32 + 3*32 + 3*5 + 3 + 4 + 10 = 161 bits (pipeline.md §8)
    output wire [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0] o_id_ex_latch
);

    localparam integer NB_IMM_SEL = 3;  // imm_sel no sale de ID (§4.3)

    //------------------------------------------------------------------
    // Señales de control del pipeline (pipeline.md §9.2 y §10.4)
    //------------------------------------------------------------------
    wire             stall       = 1'b0;            // I-41/I-42
    wire             redirect    = 1'b0;            // I-36
    wire [NB_PC-1:0] redirect_pc = {NB_PC{1'b0}};   // I-36
    wire             stop_fetch  = 1'b0;            // I-37
    wire             halted      = 1'b0;            // I-35

    wire en_pc       = i_enable & ~stall;
    wire en_if_id    = i_enable & ~stall;
    wire en_id_ex    = i_enable;
    wire flush_if_id = redirect | stop_fetch;
    wire flush_id_ex = redirect | stall;

    //------------------------------------------------------------------
    // Escritura del banco desde WB (pipeline.md §7.2): I-35
    //------------------------------------------------------------------
    wire               wb_reg_write = 1'b0;
    wire [NB_ADDR-1:0] wb_rd        = {NB_ADDR{1'b0}};
    wire [NB_DATA-1:0] wb_data      = {NB_DATA{1'b0}};

    //------------------------------------------------------------------
    // IF e IF/ID
    //------------------------------------------------------------------
    wire [NB_PC-1:0]    if_pc;          // pc_reg de pc_logic
    wire                if_id_valid;
    wire [NB_PC-1:0]    if_id_pc;
    wire [NB_INSTR-1:0] if_id_instr;

    if_stage #(
        .NB_PC    (NB_PC),
        .NB_INSTR (NB_INSTR)
    ) u_if_stage (
        .i_clk         (i_clk),
        .i_rst         (i_rst),
        .i_en_pc       (en_pc),
        .i_en_if_id    (en_if_id),
        .i_flush       (flush_if_id),
        .i_redirect    (redirect),
        .i_redirect_pc (redirect_pc),
        .i_stop_fetch  (stop_fetch),
        .i_imem_b_en   (i_imem_b_en),
        .i_imem_b_we   (i_imem_b_we),
        .i_imem_b_addr (i_imem_b_addr),
        .i_imem_b_din  (i_imem_b_din),
        .o_pc          (if_pc),
        .o_if_id_valid (if_id_valid),
        .o_if_id_pc    (if_id_pc),
        .o_if_id_instr (if_id_instr),
        .o_if_id_latch (o_if_id_latch)
    );

    //------------------------------------------------------------------
    // ID e ID/EX
    //------------------------------------------------------------------
    wire                   id_is_halt;  // para stop_fetch (I-37)
    wire                   id_ex_valid;
    wire [NB_PC-1:0]       id_ex_pc;
    wire [NB_DATA-1:0]     id_ex_rs1_data;
    wire [NB_DATA-1:0]     id_ex_rs2_data;
    wire [NB_DATA-1:0]     id_ex_imm;
    wire [NB_ADDR-1:0]     id_ex_rs1;
    wire [NB_ADDR-1:0]     id_ex_rs2;
    wire [NB_ADDR-1:0]     id_ex_rd;
    wire [NB_FUNCT3-1:0]   id_ex_funct3;
    wire [NB_ALU_CTRL-1:0] id_ex_alu_ctrl;
    wire                   id_ex_alu_src_a;
    wire                   id_ex_alu_src_b;
    wire                   id_ex_branch;
    wire                   id_ex_jal;
    wire                   id_ex_jalr;
    wire                   id_ex_mem_read;
    wire                   id_ex_mem_write;
    wire                   id_ex_reg_write;
    wire                   id_ex_mem_to_reg;
    wire                   id_ex_halt;

    id_stage #(
        .NB_PC       (NB_PC),
        .NB_INSTR    (NB_INSTR),
        .NB_DATA     (NB_DATA),
        .NB_ADDR     (NB_ADDR),
        .NB_FUNCT3   (NB_FUNCT3),
        .NB_IMM_SEL  (NB_IMM_SEL),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_id_stage (
        .i_clk              (i_clk),
        .i_rst              (i_rst),
        .i_enable           (i_enable),
        .i_en_id_ex         (en_id_ex),
        .i_flush            (flush_id_ex),
        .i_if_id_valid      (if_id_valid),
        .i_if_id_pc         (if_id_pc),
        .i_if_id_instr      (if_id_instr),
        .i_wb_reg_write     (wb_reg_write),
        .i_wb_rd            (wb_rd),
        .i_wb_data          (wb_data),
        .i_dbg_reg_addr     (i_dbg_reg_addr),
        .o_dbg_reg_data     (o_dbg_reg_data),
        .o_id_is_halt       (id_is_halt),
        .o_id_ex_valid      (id_ex_valid),
        .o_id_ex_pc         (id_ex_pc),
        .o_id_ex_rs1_data   (id_ex_rs1_data),
        .o_id_ex_rs2_data   (id_ex_rs2_data),
        .o_id_ex_imm        (id_ex_imm),
        .o_id_ex_rs1        (id_ex_rs1),
        .o_id_ex_rs2        (id_ex_rs2),
        .o_id_ex_rd         (id_ex_rd),
        .o_id_ex_funct3     (id_ex_funct3),
        .o_id_ex_alu_ctrl   (id_ex_alu_ctrl),
        .o_id_ex_alu_src_a  (id_ex_alu_src_a),
        .o_id_ex_alu_src_b  (id_ex_alu_src_b),
        .o_id_ex_branch     (id_ex_branch),
        .o_id_ex_jal        (id_ex_jal),
        .o_id_ex_jalr       (id_ex_jalr),
        .o_id_ex_mem_read   (id_ex_mem_read),
        .o_id_ex_mem_write  (id_ex_mem_write),
        .o_id_ex_reg_write  (id_ex_reg_write),
        .o_id_ex_mem_to_reg (id_ex_mem_to_reg),
        .o_id_ex_halt       (id_ex_halt),
        .o_id_ex_latch      (o_id_ex_latch)
    );

    //------------------------------------------------------------------
    // Salidas de debug
    //------------------------------------------------------------------
    assign o_halted = halted;
    assign o_pc     = if_pc;

endmodule

`default_nettype wire
