`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// riscv_core
//
// Procesador RV32I segmentado (docs/spec/pipeline.md). Se integra etapa
// por etapa (docs/planificacion.md); esta versión tiene IF (I-22), ID
// (I-27), EX (I-31), MEM (I-34), WB (I-35) y la parada por HALT (I-37).
//
// Función:
//   Instancia las etapas y genera las señales de control del pipeline
//   (pipeline.md §9.2, §10.4). Las que todavía no tienen quien las
//   produzca valen 0 y se indica qué issue las conecta:
//     stall       = 0   hasta I-41/I-42 (detección de carga-uso)
//     redirect    = 0   hasta I-36      (el salto vuelve a IF)
//     fwd_a/fwd_b = 00  hasta I-39      (unidad de forwarding)
//   Con eso, en M7: en_pc = en_if_id = en_id_ex = en_ex_mem = en_mem_wb
//   = enable, flush_id_ex = flush_ex_mem = flush_mem_wb = 0 y EX opera
//   con lo leído en ID. WB escribe el banco (wb_*, con el bypass WB -> ID
//   del banco, decisión 007). La salida de branch_unit (ex_redirect,
//   ex_redirect_pc) existe pero no vuelve a IF hasta I-36.
//
//   Parada por HALT (I-37, pipeline.md §3.4, decisión 001): stop_fetch
//   es el OR de los bits halt de las cuatro etapas y de halted. Congela
//   el PC y hace flush de IF/ID, así detrás del HALT solo entran
//   burbujas; en el flanco en que halted pasa a 1 el pipeline queda
//   vacío, y halted mantiene la parada. Un HALT en el camino equivocado
//   de un salto tomado no detiene el core: redirect gana en el PC y el
//   flush lo convierte en burbuja (I-36, I-42).
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
//   i_dmem_b_*, o_dmem_b_dout : puerto B de dmem: limpieza y volcado
//                               (memoria.md §3.3); el banco de pruebas
//                               carga por acá el estado inicial
//   i_dbg_reg_addr            : registro que lee la Debug Unit
//   o_dbg_reg_data            : su valor guardado, sin bypass (decisión 018)
//   o_halted                  : HALT llegó a WB
//   o_imem_fault, o_dmem_oob,
//   o_dmem_misaligned         : avisos de acceso (memoria.md §6.2)
//   o_pc                      : pc_reg, para el bloque de estado
//   o_if_id_latch             : IF/ID agrupado, {valid, pc, instr}
//   o_id_ex_latch             : ID/EX agrupado, en el orden de §8
//   o_ex_mem_latch            : EX/MEM agrupado, en el orden de §8
//   o_mem_wb_latch            : MEM/WB agrupado, en el orden de §8
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
//   i_dmem_b_en    : puerto B de dmem: habilita
//   i_dmem_b_we    : puerto B de dmem: escritura por byte    [3:0]
//   i_dmem_b_addr  : puerto B de dmem: índice de palabra     [9:0]
//   i_dmem_b_din   : puerto B de dmem: palabra a escribir    [NB_DATA-1:0]
//   o_dmem_b_dout  : puerto B de dmem: palabra leída         [NB_DATA-1:0]
//   i_dbg_reg_addr : registro que lee la Debug Unit          [NB_ADDR-1:0]
//   o_dbg_reg_data : valor guardado del registro             [NB_DATA-1:0]
//   o_halted       : HALT llegó a WB (registro halted, §7.3)
//   o_imem_fault   : aviso imem_fault, de WB
//   o_dmem_oob     : aviso dmem_oob, de MEM
//   o_dmem_misaligned : aviso dmem_misaligned, de MEM
//   o_pc           : pc_reg                                  [NB_PC-1:0]
//   o_if_id_latch  : IF/ID para READ_LATCHES                 [NB_PC+NB_INSTR:0]
//   o_id_ex_latch  : ID/EX para READ_LATCHES (161 bits)
//                    [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0]
//   o_ex_mem_latch : EX/MEM para READ_LATCHES (109 bits)
//                    [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+4:0]
//   o_mem_wb_latch : MEM/WB para READ_LATCHES (110 bits)
//                    [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+5:0]
//
// Latencia: la instrucción de la dirección p llega a IF/ID un ciclo con
//           enable = 1 después de que pc_reg = p, y a ID/EX, EX/MEM y
//           MEM/WB un ciclo con enable = 1 después de cada una.
// Reset   : PC = 0x0000_0000, banco de registros en 0, todos los
//           registros de segmentación en burbuja (valid = 0), avisos y
//           halted en 0. Las BRAM no se resetean.
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
    input  wire                    i_dmem_b_en,
    input  wire [3:0]              i_dmem_b_we,
    input  wire [9:0]              i_dmem_b_addr,
    input  wire [NB_DATA-1:0]      i_dmem_b_din,
    output wire [NB_DATA-1:0]      o_dmem_b_dout,
    input  wire [NB_ADDR-1:0]      i_dbg_reg_addr,
    output wire [NB_DATA-1:0]      o_dbg_reg_data,
    output wire                    o_halted,
    output wire                    o_imem_fault,
    output wire                    o_dmem_oob,
    output wire                    o_dmem_misaligned,
    output wire [NB_PC-1:0]        o_pc,
    output wire [NB_PC+NB_INSTR:0] o_if_id_latch,
    // 1 + 32 + 3*32 + 3*5 + 3 + 4 + 10 = 161 bits (pipeline.md §8)
    output wire [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0] o_id_ex_latch,
    // 1 + 32 + 2*32 + 5 + 3 + 4 = 109 bits (pipeline.md §8)
    output wire [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+4:0] o_ex_mem_latch,
    // 1 + 32 + 2*32 + 5 + 3 + 2 + 3 = 110 bits (pipeline.md §8)
    output wire [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+5:0] o_mem_wb_latch
);

    localparam integer NB_IMM_SEL = 3;  // imm_sel no sale de ID (§4.3)
    localparam integer NB_FWD     = 2;  // fwd_a / fwd_b (§5.1)

    //------------------------------------------------------------------
    // Señales de control del pipeline (pipeline.md §9.2 y §10.4)
    //------------------------------------------------------------------
    wire             stall       = 1'b0;            // I-41/I-42
    wire             redirect    = 1'b0;            // I-36
    wire [NB_PC-1:0] redirect_pc = {NB_PC{1'b0}};   // I-36
    wire             stop_fetch;                    // parada por HALT (§3.4)
    wire             halted;                        // wb_stage (§7.3)

    wire en_pc        = i_enable & ~stall;
    wire en_if_id     = i_enable & ~stall;
    wire en_id_ex     = i_enable;
    wire en_ex_mem    = i_enable;
    wire en_mem_wb    = i_enable;           // también el ena de dmem
    wire flush_if_id  = redirect | stop_fetch;
    wire flush_id_ex  = redirect | stall;
    wire flush_ex_mem = 1'b0;
    wire flush_mem_wb = 1'b0;

    //------------------------------------------------------------------
    // Escritura del banco desde WB (pipeline.md §7.2), de wb_stage
    //------------------------------------------------------------------
    wire               wb_reg_write;
    wire [NB_ADDR-1:0] wb_rd;
    wire [NB_DATA-1:0] wb_data;

    //------------------------------------------------------------------
    // Selectores de forwarding (pipeline.md §10.2): I-39. En 00 (FWD_ID_EX)
    // EX usa lo leído en ID
    //------------------------------------------------------------------
    wire [NB_FWD-1:0] fwd_a = {NB_FWD{1'b0}};
    wire [NB_FWD-1:0] fwd_b = {NB_FWD{1'b0}};

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
    wire                   id_is_halt;  // para stop_fetch (§3.4)
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
    // EX y EX/MEM
    //------------------------------------------------------------------
    wire                 ex_redirect;     // a IF en I-36
    wire [NB_PC-1:0]     ex_redirect_pc;  // a IF en I-36
    wire                 ex_mem_valid;
    wire [NB_PC-1:0]     ex_mem_pc;
    wire [NB_DATA-1:0]   ex_mem_result;
    wire [NB_DATA-1:0]   ex_mem_store_data;
    wire [NB_ADDR-1:0]   ex_mem_rd;
    wire [NB_FUNCT3-1:0] ex_mem_funct3;
    wire                 ex_mem_mem_write;
    wire                 ex_mem_reg_write;
    wire                 ex_mem_mem_to_reg;
    wire                 ex_mem_halt;

    ex_stage #(
        .NB_PC       (NB_PC),
        .NB_DATA     (NB_DATA),
        .NB_ADDR     (NB_ADDR),
        .NB_FUNCT3   (NB_FUNCT3),
        .NB_ALU_CTRL (NB_ALU_CTRL),
        .NB_FWD      (NB_FWD)
    ) u_ex_stage (
        .i_clk               (i_clk),
        .i_rst               (i_rst),
        .i_en_ex_mem         (en_ex_mem),
        .i_flush             (flush_ex_mem),
        .i_fwd_a             (fwd_a),
        .i_fwd_b             (fwd_b),
        .i_wb_data           (wb_data),
        .i_id_ex_valid       (id_ex_valid),
        .i_id_ex_pc          (id_ex_pc),
        .i_id_ex_rs1_data    (id_ex_rs1_data),
        .i_id_ex_rs2_data    (id_ex_rs2_data),
        .i_id_ex_imm         (id_ex_imm),
        .i_id_ex_rd          (id_ex_rd),
        .i_id_ex_funct3      (id_ex_funct3),
        .i_id_ex_alu_ctrl    (id_ex_alu_ctrl),
        .i_id_ex_alu_src_a   (id_ex_alu_src_a),
        .i_id_ex_alu_src_b   (id_ex_alu_src_b),
        .i_id_ex_branch      (id_ex_branch),
        .i_id_ex_jal         (id_ex_jal),
        .i_id_ex_jalr        (id_ex_jalr),
        .i_id_ex_mem_write   (id_ex_mem_write),
        .i_id_ex_reg_write   (id_ex_reg_write),
        .i_id_ex_mem_to_reg  (id_ex_mem_to_reg),
        .i_id_ex_halt        (id_ex_halt),
        .o_redirect          (ex_redirect),
        .o_redirect_pc       (ex_redirect_pc),
        .o_ex_mem_valid      (ex_mem_valid),
        .o_ex_mem_pc         (ex_mem_pc),
        .o_ex_mem_result     (ex_mem_result),
        .o_ex_mem_store_data (ex_mem_store_data),
        .o_ex_mem_rd         (ex_mem_rd),
        .o_ex_mem_funct3     (ex_mem_funct3),
        .o_ex_mem_mem_write  (ex_mem_mem_write),
        .o_ex_mem_reg_write  (ex_mem_reg_write),
        .o_ex_mem_mem_to_reg (ex_mem_mem_to_reg),
        .o_ex_mem_halt       (ex_mem_halt),
        .o_ex_mem_latch      (o_ex_mem_latch)
    );

    //------------------------------------------------------------------
    // MEM y MEM/WB
    //------------------------------------------------------------------
    wire                 dmem_oob;
    wire                 dmem_misaligned;
    wire                 mem_wb_valid;
    wire [NB_PC-1:0]     mem_wb_pc;
    wire [NB_DATA-1:0]   mem_wb_result;
    wire [NB_DATA-1:0]   mem_wb_read_data;
    wire [NB_ADDR-1:0]   mem_wb_rd;
    wire [NB_FUNCT3-1:0] mem_wb_funct3;
    wire [1:0]           mem_wb_offset;
    wire                 mem_wb_reg_write;
    wire                 mem_wb_mem_to_reg;
    wire                 mem_wb_halt;

    mem_stage #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_mem_stage (
        .i_clk               (i_clk),
        .i_rst               (i_rst),
        .i_en_mem_wb         (en_mem_wb),
        .i_flush             (flush_mem_wb),
        .i_ex_mem_valid      (ex_mem_valid),
        .i_ex_mem_pc         (ex_mem_pc),
        .i_ex_mem_result     (ex_mem_result),
        .i_ex_mem_store_data (ex_mem_store_data),
        .i_ex_mem_rd         (ex_mem_rd),
        .i_ex_mem_funct3     (ex_mem_funct3),
        .i_ex_mem_mem_write  (ex_mem_mem_write),
        .i_ex_mem_reg_write  (ex_mem_reg_write),
        .i_ex_mem_mem_to_reg (ex_mem_mem_to_reg),
        .i_ex_mem_halt       (ex_mem_halt),
        .o_mem_wb_valid      (mem_wb_valid),
        .o_mem_wb_pc         (mem_wb_pc),
        .o_mem_wb_result     (mem_wb_result),
        .o_mem_wb_read_data  (mem_wb_read_data),
        .o_mem_wb_rd         (mem_wb_rd),
        .o_mem_wb_funct3     (mem_wb_funct3),
        .o_mem_wb_offset     (mem_wb_offset),
        .o_mem_wb_reg_write  (mem_wb_reg_write),
        .o_mem_wb_mem_to_reg (mem_wb_mem_to_reg),
        .o_mem_wb_halt       (mem_wb_halt),
        .o_mem_wb_latch      (o_mem_wb_latch),
        .o_dmem_oob          (dmem_oob),
        .o_dmem_misaligned   (dmem_misaligned),
        .i_dmem_b_en         (i_dmem_b_en),
        .i_dmem_b_we         (i_dmem_b_we),
        .i_dmem_b_addr       (i_dmem_b_addr),
        .i_dmem_b_din        (i_dmem_b_din),
        .o_dmem_b_dout       (o_dmem_b_dout)
    );

    //------------------------------------------------------------------
    // WB
    //------------------------------------------------------------------
    wire imem_fault;

    wb_stage #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_wb_stage (
        .i_clk               (i_clk),
        .i_rst               (i_rst),
        .i_enable            (i_enable),
        .i_mem_wb_valid      (mem_wb_valid),
        .i_mem_wb_pc         (mem_wb_pc),
        .i_mem_wb_result     (mem_wb_result),
        .i_mem_wb_read_data  (mem_wb_read_data),
        .i_mem_wb_rd         (mem_wb_rd),
        .i_mem_wb_funct3     (mem_wb_funct3),
        .i_mem_wb_offset     (mem_wb_offset),
        .i_mem_wb_reg_write  (mem_wb_reg_write),
        .i_mem_wb_mem_to_reg (mem_wb_mem_to_reg),
        .i_mem_wb_halt       (mem_wb_halt),
        .o_wb_reg_write      (wb_reg_write),
        .o_wb_rd             (wb_rd),
        .o_wb_data           (wb_data),
        .o_halted            (halted),
        .o_imem_fault        (imem_fault)
    );

    //------------------------------------------------------------------
    // Parada por HALT (pipeline.md §3.4). Los bits halt de ID/EX, EX/MEM y
    // MEM/WB valen 0 en una burbuja, e id_is_halt ya viene con valid
    //------------------------------------------------------------------
    assign stop_fetch = id_is_halt | id_ex_halt | ex_mem_halt | mem_wb_halt | halted;

    //------------------------------------------------------------------
    // Salidas de debug
    //------------------------------------------------------------------
    assign o_halted          = halted;
    assign o_imem_fault      = imem_fault;
    assign o_dmem_oob        = dmem_oob;
    assign o_dmem_misaligned = dmem_misaligned;
    assign o_pc              = if_pc;

endmodule

`default_nettype wire
