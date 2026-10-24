`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// mem_stage
//
// Etapa MEM completa: memoria de datos y registro MEM/WB
// (docs/spec/pipeline.md §6).
//
// Función:
//   Conecta dmem y mem_wb_reg como fija pipeline.md §6, con el mismo
//   criterio que if_stage, id_stage y ex_stage (decisión 023):
//     - dmem (§6.6, decisión 027) recibe la dirección, el funct3, el
//       dato y el control de EX/MEM: escribe los stores con su máscara
//       de bytes, lee la palabra en todos los ciclos (READ_FIRST) y
//       calcula los avisos dmem_oob y dmem_misaligned.
//     - Su registro de salida es mem_wb_read_data (decisión 009, §6.3):
//       entra a mem_wb_reg por i_read_data y sale sin registrar.
//     - offset = ex_mem_result[1:0] (§6.1); mem_wb_reg solo lo copia.
//     - mem_wb_reg guarda los otros 78 bits de §8 con rst > en > flush
//       (§2).
//   La etapa no calcula enables ni flush: los recibe de quien los genere
//   (riscv_core, §10.4):
//     en_mem_wb    = enable
//     flush_mem_wb = 0
//   en_mem_wb es a la vez el en de MEM/WB y el ena del puerto A de dmem:
//   con el core detenido no cambia ningún bit de MEM/WB, ni read_data,
//   y no se escribe la memoria (decisión 018). El reset limpia MEM/WB y
//   los avisos; la BRAM no se resetea.
//   El puerto B de dmem pasa sin tocar (memoria.md §3.3): lo usan la
//   Debug Unit y el banco de pruebas.
//
// Parámetros:
//   NB_PC     : ancho del PC
//   NB_DATA   : ancho de los datos (result, store_data, read_data)
//   NB_ADDR   : ancho del número de registro
//   NB_FUNCT3 : ancho de funct3
//
// Puertos:
//   i_clk          : reloj del sistema
//   i_rst          : reset síncrono, activo en alto (core_rst); MEM/WB en
//                    burbuja y avisos en 0, gana sobre i_en_mem_wb
//   i_en_mem_wb    : en 0 MEM/WB no cambia y dmem no lee ni escribe
//   i_flush        : flush_mem_wb; MEM/WB carga burbuja
//   i_ex_mem_valid ... i_ex_mem_halt : ex_mem_<campo> de §8
//   o_mem_wb_valid ... o_mem_wb_halt : mem_wb_<campo> de §8, un puerto
//                    por campo
//   o_mem_wb_latch : MEM/WB agrupado para la Debug Unit, en el orden de
//                    §8, valid en el bit más alto (decisión 023)
//                    [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+5:0]
//   o_dmem_oob     : aviso dmem_oob (memoria.md §6.2)
//   o_dmem_misaligned : aviso dmem_misaligned (memoria.md §6.2)
//   i_dmem_b_en    : puerto B de dmem: habilita
//   i_dmem_b_we    : puerto B de dmem: escritura por byte      [3:0]
//   i_dmem_b_addr  : puerto B de dmem: índice de palabra       [9:0]
//   i_dmem_b_din   : puerto B de dmem: palabra a escribir      [NB_DATA-1:0]
//   o_dmem_b_dout  : puerto B de dmem: palabra leída           [NB_DATA-1:0]
//
// Latencia: 1 ciclo (EX/MEM -> MEM/WB). La palabra leída llega a
//           mem_wb_read_data en el mismo flanco que los demás campos.
// Reset   : o_mem_wb_valid = 0 y control de MEM/WB en 0; avisos en 0;
//           los campos de datos de MEM/WB y la BRAM no se resetean.
//======================================================================

module mem_stage
#(
    parameter integer NB_PC     = 32,
    parameter integer NB_DATA   = 32,
    parameter integer NB_ADDR   = 5,
    parameter integer NB_FUNCT3 = 3
)
(
    input  wire                 i_clk,
    input  wire                 i_rst,
    input  wire                 i_en_mem_wb,
    input  wire                 i_flush,
    // EX/MEM
    input  wire                 i_ex_mem_valid,
    input  wire [NB_PC-1:0]     i_ex_mem_pc,
    input  wire [NB_DATA-1:0]   i_ex_mem_result,
    input  wire [NB_DATA-1:0]   i_ex_mem_store_data,
    input  wire [NB_ADDR-1:0]   i_ex_mem_rd,
    input  wire [NB_FUNCT3-1:0] i_ex_mem_funct3,
    input  wire                 i_ex_mem_mem_write,
    input  wire                 i_ex_mem_reg_write,
    input  wire                 i_ex_mem_mem_to_reg,
    input  wire                 i_ex_mem_halt,
    // MEM/WB: mem_wb_<campo>
    output wire                 o_mem_wb_valid,
    output wire [NB_PC-1:0]     o_mem_wb_pc,
    output wire [NB_DATA-1:0]   o_mem_wb_result,
    output wire [NB_DATA-1:0]   o_mem_wb_read_data,
    output wire [NB_ADDR-1:0]   o_mem_wb_rd,
    output wire [NB_FUNCT3-1:0] o_mem_wb_funct3,
    output wire [1:0]           o_mem_wb_offset,
    output wire                 o_mem_wb_reg_write,
    output wire                 o_mem_wb_mem_to_reg,
    output wire                 o_mem_wb_halt,
    // 1 + 32 + 2*32 + 5 + 3 + 2 + 3 = 110 bits (§8)
    output wire [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+5:0] o_mem_wb_latch,
    // Avisos de acceso
    output wire                 o_dmem_oob,
    output wire                 o_dmem_misaligned,
    // Puerto B de dmem (Debug Unit)
    input  wire                 i_dmem_b_en,
    input  wire [3:0]           i_dmem_b_we,
    input  wire [9:0]           i_dmem_b_addr,
    input  wire [NB_DATA-1:0]   i_dmem_b_din,
    output wire [NB_DATA-1:0]   o_dmem_b_dout
);

    localparam integer NB_OFFSET = 2;   // byte dentro de la palabra (§6.1)

    //------------------------------------------------------------------
    // Memoria de datos (§6.2, §6.3, decisión 027)
    //------------------------------------------------------------------
    wire [NB_DATA-1:0]   mem_read_data;      // salida registrada de la BRAM
    wire [NB_OFFSET-1:0] mem_offset = i_ex_mem_result[NB_OFFSET-1:0];

    dmem u_dmem (
        .i_clk          (i_clk),
        .i_rst          (i_rst),
        .i_a_en         (i_en_mem_wb),
        .i_a_addr       (i_ex_mem_result),
        .i_a_funct3     (i_ex_mem_funct3),
        .i_a_store      (i_ex_mem_mem_write),
        .i_a_load       (i_ex_mem_mem_to_reg),
        .i_a_store_data (i_ex_mem_store_data),
        .o_a_dout       (mem_read_data),
        .o_oob          (o_dmem_oob),
        .o_misaligned   (o_dmem_misaligned),
        .i_b_en         (i_dmem_b_en),
        .i_b_we         (i_dmem_b_we),
        .i_b_addr       (i_dmem_b_addr),
        .i_b_din        (i_dmem_b_din),
        .o_b_dout       (o_dmem_b_dout)
    );

    //------------------------------------------------------------------
    // Registro MEM/WB (§8)
    //------------------------------------------------------------------
    mem_wb_reg #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3),
        .NB_OFFSET (NB_OFFSET)
    ) u_mem_wb_reg (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_en         (i_en_mem_wb),
        .i_flush      (i_flush),
        .i_valid      (i_ex_mem_valid),
        .i_pc         (i_ex_mem_pc),
        .i_result     (i_ex_mem_result),
        .i_read_data  (mem_read_data),
        .i_rd         (i_ex_mem_rd),
        .i_funct3     (i_ex_mem_funct3),
        .i_offset     (mem_offset),
        .i_reg_write  (i_ex_mem_reg_write),
        .i_mem_to_reg (i_ex_mem_mem_to_reg),
        .i_halt       (i_ex_mem_halt),
        .o_valid      (o_mem_wb_valid),
        .o_pc         (o_mem_wb_pc),
        .o_result     (o_mem_wb_result),
        .o_read_data  (o_mem_wb_read_data),
        .o_rd         (o_mem_wb_rd),
        .o_funct3     (o_mem_wb_funct3),
        .o_offset     (o_mem_wb_offset),
        .o_reg_write  (o_mem_wb_reg_write),
        .o_mem_to_reg (o_mem_wb_mem_to_reg),
        .o_halt       (o_mem_wb_halt),
        .o_latch      (o_mem_wb_latch)
    );

endmodule

`default_nettype wire
