`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// if_stage
//
// Etapa IF completa: PC, memoria de programa y registro IF/ID
// (docs/spec/pipeline.md §3).
//
// Función:
//   Conecta pc_logic, imem e if_id_reg como fija pipeline.md §3:
//     - pc_logic mantiene pc_reg y elige el próximo PC
//       (redirect > stop_fetch > +4, §3.1).
//     - imem lee pc_reg por el puerto A; su registro de salida es
//       if_id_instr (decisión 009), así que su ena es en_if_id (§3.3).
//     - if_id_reg guarda valid y pc con la prioridad rst > en > flush
//       (§2). El flush no borra la BRAM: solo pone if_id_valid = 0
//       (decisión 022).
//   La etapa no calcula enables ni flush: los recibe de quien los genere
//   (riscv_core hasta I-42, después la unidad de riesgos, §10.4):
//     en_pc = en_if_id = enable & ~stall
//     flush_if_id      = redirect | stop_fetch
//   El puerto B de imem (LOAD, memoria.md §4) pasa sin tocar.
//
// Parámetros:
//   NB_PC    : ancho del PC
//   NB_INSTR : ancho de la instrucción
//
// Puertos:
//   i_clk         : reloj del sistema
//   i_rst         : reset síncrono, activo en alto (core_rst); PC = 0 e
//                   IF/ID en burbuja, gana sobre los enables
//   i_en_pc       : en 0 el PC no cambia
//   i_en_if_id    : en 0 IF/ID y la salida de imem no cambian
//   i_flush       : flush_if_id; IF/ID carga burbuja (valid = 0)
//   i_redirect    : salto tomado en EX (§5.3)
//   i_redirect_pc : destino del salto                       [NB_PC-1:0]
//   i_stop_fetch  : HALT en el pipeline; retiene el PC (§3.4)
//   i_imem_b_en   : puerto B de imem: habilita
//   i_imem_b_we   : puerto B de imem: escritura
//   i_imem_b_addr : puerto B de imem: índice de palabra     [9:0]
//   i_imem_b_din  : puerto B de imem: palabra a escribir    [NB_INSTR-1:0]
//   o_pc          : pc_reg, PC que se busca en este ciclo   [NB_PC-1:0]
//   o_if_id_valid : if_id_valid, 1 = instrucción, 0 = burbuja
//   o_if_id_pc    : if_id_pc                                [NB_PC-1:0]
//   o_if_id_instr : if_id_instr (salida registrada de imem) [NB_INSTR-1:0]
//   o_if_id_latch : IF/ID agrupado para la Debug Unit, {valid, pc, instr}
//                   en el orden de §8                       [NB_PC+NB_INSTR:0]
//
// Latencia: 1 ciclo (o_pc -> IF/ID). La instrucción de la dirección p
//           aparece en if_id_instr junto con if_id_pc = p (§3.2).
// Reset   : o_pc = 0x0000_0000, o_if_id_valid = 0. if_id_pc e
//           if_id_instr no se resetean (basura con valid = 0, §3.3).
//======================================================================

module if_stage
#(
    parameter integer NB_PC    = 32,
    parameter integer NB_INSTR = 32
)
(
    input  wire                    i_clk,
    input  wire                    i_rst,
    input  wire                    i_en_pc,
    input  wire                    i_en_if_id,
    input  wire                    i_flush,
    input  wire                    i_redirect,
    input  wire [NB_PC-1:0]        i_redirect_pc,
    input  wire                    i_stop_fetch,
    input  wire                    i_imem_b_en,
    input  wire                    i_imem_b_we,
    input  wire [9:0]              i_imem_b_addr,
    input  wire [NB_INSTR-1:0]     i_imem_b_din,
    output wire [NB_PC-1:0]        o_pc,
    output wire                    o_if_id_valid,
    output wire [NB_PC-1:0]        o_if_id_pc,
    output wire [NB_INSTR-1:0]     o_if_id_instr,
    output wire [NB_PC+NB_INSTR:0] o_if_id_latch
);

    wire [NB_PC-1:0]    if_pc;      // pc_reg
    wire [NB_INSTR-1:0] if_instr;   // douta de imem = if_id_instr

    pc_logic #(
        .NB_PC (NB_PC)
    ) u_pc_logic (
        .i_clk         (i_clk),
        .i_rst         (i_rst),
        .i_en_pc       (i_en_pc),
        .i_redirect    (i_redirect),
        .i_redirect_pc (i_redirect_pc),
        .i_stop_fetch  (i_stop_fetch),
        .o_pc          (if_pc)
    );

    // Puerto A: ena = en_if_id, así la instrucción queda quieta con IF/ID
    imem u_imem (
        .i_clk    (i_clk),
        .i_a_en   (i_en_if_id),
        .i_a_addr (if_pc),
        .o_a_dout (if_instr),
        .i_b_en   (i_imem_b_en),
        .i_b_we   (i_imem_b_we),
        .i_b_addr (i_imem_b_addr),
        .i_b_din  (i_imem_b_din)
    );

    if_id_reg #(
        .NB_PC    (NB_PC),
        .NB_INSTR (NB_INSTR)
    ) u_if_id_reg (
        .i_clk   (i_clk),
        .i_rst   (i_rst),
        .i_en    (i_en_if_id),
        .i_flush (i_flush),
        .i_pc    (if_pc),
        .i_instr (if_instr),
        .o_valid (o_if_id_valid),
        .o_pc    (o_if_id_pc),
        .o_instr (o_if_id_instr),
        .o_latch (o_if_id_latch)
    );

    assign o_pc = if_pc;

endmodule

`default_nettype wire
