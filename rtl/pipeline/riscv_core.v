`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// riscv_core
//
// Procesador RV32I segmentado (docs/spec/pipeline.md). Se integra etapa
// por etapa (docs/planificacion.md); esta versión tiene solo IF (I-22).
//
// Función:
//   Instancia las etapas y genera las señales de control del pipeline
//   (pipeline.md §9.2, §10.4). Las que todavía no tienen quien las
//   produzca valen 0 y se indica qué issue las conecta:
//     stall       = 0   hasta I-41/I-42 (detección de carga-uso)
//     redirect    = 0   hasta I-36      (el salto vuelve a IF)
//     stop_fetch  = 0   hasta I-37      (parada por HALT)
//     halted      = 0   hasta I-35      (registro halted en WB)
//   Con eso, en M3: en_pc = en_if_id = enable y flush_if_id = 0.
//
//   Los campos de los registros de segmentación son señales de este
//   módulo con el nombre <latch>_<campo> de pipeline.md §8: el banco de
//   pruebas incremental los lee por jerarquía (verificacion.md §8.5).
//
// Interfaz de debug (decisión 023, protocolo_debug.md §7):
//   i_enable                  : enable de la Debug Unit (la issue lo llama
//                               cpu_en, decisión 018). En 0 nada con
//                               estado cambia; i_rst gana sobre él
//   i_imem_b_*                : puerto B de imem para LOAD (memoria.md §4)
//   o_halted                  : HALT llegó a WB
//   o_pc                      : pc_reg, para el bloque de estado
//   o_if_id_latch             : IF/ID agrupado, {valid, pc, instr}
//   Cada integración agrega su bus de latch (o_id_ex_latch, ...), el
//   puerto B de dmem (I-34), los avisos (I-35) y el puerto de lectura
//   del banco de registros (I-27).
//
// Parámetros:
//   NB_PC    : ancho del PC y de las direcciones
//   NB_INSTR : ancho de la instrucción
//
// Puertos:
//   i_clk         : reloj del sistema (único dominio, decisión 006)
//   i_rst         : core_rst, síncrono, activo en alto
//   i_enable      : enable global del core (decisión 018)
//   i_imem_b_en   : puerto B de imem: habilita
//   i_imem_b_we   : puerto B de imem: escritura
//   i_imem_b_addr : puerto B de imem: índice de palabra     [9:0]
//   i_imem_b_din  : puerto B de imem: palabra a escribir    [NB_INSTR-1:0]
//   o_halted      : HALT en WB; 0 hasta I-35
//   o_pc          : pc_reg                                  [NB_PC-1:0]
//   o_if_id_latch : IF/ID para READ_LATCHES                 [NB_PC+NB_INSTR:0]
//
// Latencia: la instrucción de la dirección p llega a IF/ID un ciclo con
//           enable = 1 después de que pc_reg = p.
// Reset   : PC = 0x0000_0000, todos los registros de segmentación en
//           burbuja (valid = 0), halted = 0.
//======================================================================

module riscv_core
#(
    parameter integer NB_PC    = 32,
    parameter integer NB_INSTR = 32
)
(
    input  wire                    i_clk,
    input  wire                    i_rst,
    input  wire                    i_enable,
    input  wire                    i_imem_b_en,
    input  wire                    i_imem_b_we,
    input  wire [9:0]              i_imem_b_addr,
    input  wire [NB_INSTR-1:0]     i_imem_b_din,
    output wire                    o_halted,
    output wire [NB_PC-1:0]        o_pc,
    output wire [NB_PC+NB_INSTR:0] o_if_id_latch
);

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
    wire flush_if_id = redirect | stop_fetch;

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
    // Salidas de debug
    //------------------------------------------------------------------
    assign o_halted = halted;
    assign o_pc     = if_pc;

endmodule

`default_nettype wire
