`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// mem_wb_reg
//
// Registro de segmentación MEM/WB (docs/spec/pipeline.md §2, §6.5, §8).
//
// Función:
//   Guarda los 10 campos de MEM/WB (110 bits) con las entradas comunes
//   a los cuatro registros de segmentación y la prioridad
//   rst > en > flush (§2):
//     rst          -> burbuja: valid = 0 y control en 0
//     en = 0       -> conserva todo, aunque flush = 1 (core detenido:
//                     la instrucción no se pierde, decisión 018)
//     en = 1       -> carga la instrucción de MEM; con flush = 1 carga
//                     burbuja en su lugar
//   De los 110 bits, 78 son flip-flops de este módulo y 32 no:
//   mem_wb_read_data es el registro de salida de la memoria de datos
//   (decisión 009, §6.3). Llega por i_read_data y sale tal cual, como
//   if_id_instr en if_id_reg; el ena de esa BRAM es el mismo en_mem_wb
//   que recibe este módulo (§10.4), así que con el core detenido
//   tampoco cambia. La BRAM no se resetea: el reset y el flush no
//   tocan read_data, que queda como dato de una burbuja.
//   Una burbuja tiene valid = 0 y las 3 señales de control en 0
//   (reg_write, mem_to_reg, halt), igual que la que genera el modelo de
//   referencia y que la que sale de ex_mem_reg. Así no escribe el banco
//   de registros, no se reenvía (reg_write) y no activa halted ni
//   frena el fetch (halt).
//   Los campos de datos (pc, result, rd, funct3, offset) no se resetean
//   y se cargan con en aunque haya flush: los datos de una burbuja no
//   importan (§2, decisión 010).
//   §10.4 fija flush_mem_wb = 0; la entrada existe porque §2 y §8 dan
//   rst, en y flush a los cuatro registros. Atada a 0, la síntesis la
//   elimina.
//   El registro no calcula nada: offset = ex_mem_result[1:0] lo arma la
//   etapa MEM (§6.1, §6.5) y llega por i_offset.
//
// Parámetros:
//   NB_PC     : ancho del PC
//   NB_DATA   : ancho de los datos (result, read_data)
//   NB_ADDR   : ancho del número de registro (rd)
//   NB_FUNCT3 : ancho de funct3
//   NB_OFFSET : ancho del byte dentro de la palabra (offset)
//
// Puertos:
//   i_clk        : reloj del sistema
//   i_rst        : reset síncrono, activo en alto; gana sobre i_en
//   i_en         : en_mem_wb = enable (§10.4); en 0 conserva. Es
//                  también el ena del puerto A de dmem
//   i_flush      : flush_mem_wb (0 en §10.4); carga burbuja
//   i_valid      : ex_mem_valid
//   i_pc         : ex_mem_pc                                [NB_PC-1:0]
//   i_result     : ex_mem_result                            [NB_DATA-1:0]
//   i_read_data  : salida registrada del puerto A de dmem   [NB_DATA-1:0]
//   i_rd         : ex_mem_rd                                [NB_ADDR-1:0]
//   i_funct3     : ex_mem_funct3                            [NB_FUNCT3-1:0]
//   i_offset     : ex_mem_result[1:0], de la etapa MEM      [NB_OFFSET-1:0]
//   i_reg_write, i_mem_to_reg, i_halt : las 3 señales de control de
//                  EX/MEM que siguen viajando (§9.1)
//   o_valid ... o_halt     : mem_wb_<campo> de §8, un puerto por campo;
//                  o_read_data es i_read_data sin registrar
//   o_latch      : MEM/WB agrupado para la Debug Unit, en el orden de §8,
//                  valid en el bit más alto (decisión 023)
//                  [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+NB_OFFSET+3:0]
//
// Latencia: 1 ciclo (entradas -> salidas); o_read_data es
//           combinacional desde i_read_data (la latencia la pone la
//           BRAM).
// Reset   : o_valid = 0 y control en 0; los campos de datos no se
//           resetean.
//======================================================================

module mem_wb_reg
#(
    parameter integer NB_PC     = 32,
    parameter integer NB_DATA   = 32,
    parameter integer NB_ADDR   = 5,
    parameter integer NB_FUNCT3 = 3,
    parameter integer NB_OFFSET = 2
)
(
    input  wire                 i_clk,
    input  wire                 i_rst,
    input  wire                 i_en,
    input  wire                 i_flush,
    // Datos
    input  wire                 i_valid,
    input  wire [NB_PC-1:0]     i_pc,
    input  wire [NB_DATA-1:0]   i_result,
    input  wire [NB_DATA-1:0]   i_read_data,
    input  wire [NB_ADDR-1:0]   i_rd,
    input  wire [NB_FUNCT3-1:0] i_funct3,
    input  wire [NB_OFFSET-1:0] i_offset,
    // Control
    input  wire                 i_reg_write,
    input  wire                 i_mem_to_reg,
    input  wire                 i_halt,
    // Salidas: mem_wb_<campo>
    output wire                 o_valid,
    output wire [NB_PC-1:0]     o_pc,
    output wire [NB_DATA-1:0]   o_result,
    output wire [NB_DATA-1:0]   o_read_data,
    output wire [NB_ADDR-1:0]   o_rd,
    output wire [NB_FUNCT3-1:0] o_funct3,
    output wire [NB_OFFSET-1:0] o_offset,
    output wire                 o_reg_write,
    output wire                 o_mem_to_reg,
    output wire                 o_halt,
    // 1 + 32 + 2*32 + 5 + 3 + 2 + 3 = 110 bits (§8)
    output wire [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+NB_OFFSET+3:0] o_latch
);

    // Campos en flip-flops: datos (pc, result, rd, funct3, offset) y
    // control (reg_write, mem_to_reg, halt). read_data no está: es la
    // salida de la BRAM
    localparam integer NB_DATA_FIELDS = NB_PC + NB_DATA + NB_ADDR + NB_FUNCT3 + NB_OFFSET;
    localparam integer NB_CTRL        = 3;

    wire [NB_DATA_FIELDS-1:0] data_in = {i_pc, i_result, i_rd, i_funct3,
                                         i_offset};
    wire [NB_CTRL-1:0]        ctrl_in = {i_reg_write, i_mem_to_reg, i_halt};

    reg                       mem_wb_valid_reg;
    reg [NB_CTRL-1:0]         mem_wb_ctrl_reg;
    reg [NB_DATA_FIELDS-1:0]  mem_wb_data_reg;

    // valid y control: con reset; prioridad rst > en > flush (§2)
    always @(posedge i_clk) begin
        if (i_rst) begin
            mem_wb_valid_reg <= 1'b0;
            mem_wb_ctrl_reg  <= {NB_CTRL{1'b0}};
        end
        else if (i_en) begin
            if (i_flush) begin
                mem_wb_valid_reg <= 1'b0;
                mem_wb_ctrl_reg  <= {NB_CTRL{1'b0}};
            end
            else begin
                mem_wb_valid_reg <= i_valid;
                mem_wb_ctrl_reg  <= ctrl_in;
            end
        end
    end

    // Datos: sin reset (decisión 010); el flush no los toca
    always @(posedge i_clk) begin
        if (i_en)
            mem_wb_data_reg <= data_in;
    end

    assign o_valid     = mem_wb_valid_reg;
    assign {o_pc, o_result, o_rd, o_funct3, o_offset} = mem_wb_data_reg;
    assign o_read_data = i_read_data;
    assign {o_reg_write, o_mem_to_reg, o_halt} = mem_wb_ctrl_reg;

    // Orden de §8: read_data va entre result y rd
    assign o_latch = {o_valid, o_pc, o_result, o_read_data, o_rd,
                      o_funct3, o_offset, o_reg_write, o_mem_to_reg,
                      o_halt};

endmodule

`default_nettype wire
