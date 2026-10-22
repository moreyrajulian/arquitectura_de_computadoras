`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// ex_mem_reg
//
// Registro de segmentación EX/MEM (docs/spec/pipeline.md §2, §5.5, §8).
//
// Función:
//   Guarda los 10 campos de EX/MEM (109 bits) con las entradas comunes a
//   los cuatro registros de segmentación y la prioridad rst > en > flush
//   (§2):
//     rst          -> burbuja: valid = 0 y control en 0
//     en = 0       -> conserva todo, aunque flush = 1 (core detenido:
//                     la instrucción no se pierde, decisión 018)
//     en = 1       -> carga la instrucción de EX; con flush = 1 carga
//                     burbuja en su lugar
//   Una burbuja tiene valid = 0 y las 4 señales de control en 0
//   (mem_write ... halt), igual que la que genera el modelo de
//   referencia y que la que sale de id_ex_reg. Así no escribe memoria
//   ni registros, no se reenvía (reg_write), no para el core (halt) y
//   no cuenta como acceso para los avisos de memoria (mem_write |
//   mem_to_reg, memoria.md §6.2).
//   Los campos de datos (pc ... funct3) no se resetean y se cargan con
//   en aunque haya flush: los datos de una burbuja no importan (§2,
//   decisión 010).
//   §10.4 fija flush_ex_mem = 0; la entrada existe porque §2 y §8 dan
//   rst, en y flush a los cuatro registros. Atada a 0, la síntesis la
//   elimina.
//   El registro no decodifica nada: copia lo que llega de EX. Que una
//   burbuja de ID/EX traiga el control en 0 lo resuelve id_ex_reg.
//
// Parámetros:
//   NB_PC     : ancho del PC
//   NB_DATA   : ancho de los datos (result, store_data)
//   NB_ADDR   : ancho del número de registro (rd)
//   NB_FUNCT3 : ancho de funct3
//
// Puertos:
//   i_clk        : reloj del sistema
//   i_rst        : reset síncrono, activo en alto; gana sobre i_en
//   i_en         : en_ex_mem = enable (§10.4); en 0 conserva
//   i_flush      : flush_ex_mem (0 en §10.4); carga burbuja
//   i_valid      : id_ex_valid
//   i_pc         : id_ex_pc                                 [NB_PC-1:0]
//   i_result     : mux de resultado de EX (§5.4); en loads y stores,
//                  la dirección                             [NB_DATA-1:0]
//   i_store_data : rs2_val, ya con forwarding (§5.1)        [NB_DATA-1:0]
//   i_rd         : id_ex_rd                                 [NB_ADDR-1:0]
//   i_funct3     : id_ex_funct3                             [NB_FUNCT3-1:0]
//   i_mem_write ... i_halt : las 4 señales de control de ID/EX que
//                  siguen viajando (§9.1)
//   o_valid ... o_halt     : ex_mem_<campo> de §8, un puerto por campo
//   o_latch      : EX/MEM agrupado para la Debug Unit, en el orden de §8,
//                  valid en el bit más alto (decisión 023)
//                  [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+4:0]
//
// Latencia: 1 ciclo (entradas -> salidas).
// Reset   : o_valid = 0 y control en 0; los campos de datos no se
//           resetean.
//======================================================================

module ex_mem_reg
#(
    parameter integer NB_PC     = 32,
    parameter integer NB_DATA   = 32,
    parameter integer NB_ADDR   = 5,
    parameter integer NB_FUNCT3 = 3
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
    input  wire [NB_DATA-1:0]   i_store_data,
    input  wire [NB_ADDR-1:0]   i_rd,
    input  wire [NB_FUNCT3-1:0] i_funct3,
    // Control
    input  wire                 i_mem_write,
    input  wire                 i_reg_write,
    input  wire                 i_mem_to_reg,
    input  wire                 i_halt,
    // Salidas: ex_mem_<campo>
    output wire                 o_valid,
    output wire [NB_PC-1:0]     o_pc,
    output wire [NB_DATA-1:0]   o_result,
    output wire [NB_DATA-1:0]   o_store_data,
    output wire [NB_ADDR-1:0]   o_rd,
    output wire [NB_FUNCT3-1:0] o_funct3,
    output wire                 o_mem_write,
    output wire                 o_reg_write,
    output wire                 o_mem_to_reg,
    output wire                 o_halt,
    // 1 + 32 + 2*32 + 5 + 3 + 4 = 109 bits (§8)
    output wire [NB_PC+2*NB_DATA+NB_ADDR+NB_FUNCT3+4:0] o_latch
);

    // Campos agrupados en el orden de §8: datos (pc ... funct3) y
    // control (mem_write ... halt)
    localparam integer NB_DATA_FIELDS = NB_PC + 2*NB_DATA + NB_ADDR + NB_FUNCT3;
    localparam integer NB_CTRL        = 4;

    wire [NB_DATA_FIELDS-1:0] data_in = {i_pc, i_result, i_store_data,
                                         i_rd, i_funct3};
    wire [NB_CTRL-1:0]        ctrl_in = {i_mem_write, i_reg_write,
                                         i_mem_to_reg, i_halt};

    reg                       ex_mem_valid_reg;
    reg [NB_CTRL-1:0]         ex_mem_ctrl_reg;
    reg [NB_DATA_FIELDS-1:0]  ex_mem_data_reg;

    // valid y control: con reset; prioridad rst > en > flush (§2)
    always @(posedge i_clk) begin
        if (i_rst) begin
            ex_mem_valid_reg <= 1'b0;
            ex_mem_ctrl_reg  <= {NB_CTRL{1'b0}};
        end
        else if (i_en) begin
            if (i_flush) begin
                ex_mem_valid_reg <= 1'b0;
                ex_mem_ctrl_reg  <= {NB_CTRL{1'b0}};
            end
            else begin
                ex_mem_valid_reg <= i_valid;
                ex_mem_ctrl_reg  <= ctrl_in;
            end
        end
    end

    // Datos: sin reset (decisión 010); el flush no los toca
    always @(posedge i_clk) begin
        if (i_en)
            ex_mem_data_reg <= data_in;
    end

    assign o_valid = ex_mem_valid_reg;
    assign {o_pc, o_result, o_store_data, o_rd, o_funct3} = ex_mem_data_reg;
    assign {o_mem_write, o_reg_write, o_mem_to_reg, o_halt} = ex_mem_ctrl_reg;
    assign o_latch = {ex_mem_valid_reg, ex_mem_data_reg, ex_mem_ctrl_reg};

endmodule

`default_nettype wire
